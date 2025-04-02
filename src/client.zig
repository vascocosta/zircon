const std = @import("std");
const tls = @import("tls");

const utils = @import("utils.zig");
pub const Message = @import("message.zig").Message;
pub const ProtoMessage = @import("message.zig").ProtoMessage;

const default_port = 6667;
const delimiter = "\r\n";
const max_msg_len = 512;

/// The client connection to the IRC server.
pub const Client = struct {
    pub const Config = struct {
        user: []const u8,
        nick: []const u8,
        real_name: []const u8,
        server: []const u8,
        port: ?u16,
        tls: bool = false,
        channels: [][]const u8,
    };

    const LoopConfig = struct {
        fn defaultSpawnThread(_: Message) bool {
            return false;
        }

        msg_callback: ?fn (Message) ?Message = null,
        spawn_thread: fn (Message) bool = defaultSpawnThread,
    };

    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    connection: tls.Connection(std.net.Stream),
    buf: std.ArrayList(u8),
    replies: std.ArrayList(Message),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    cfg: Config,

    /// Initialize the Client with an allocator and a configuration.
    pub fn init(alloc: std.mem.Allocator, cfg: Config) !Client {
        return .{
            .alloc = alloc,
            .stream = undefined,
            .connection = undefined,
            .buf = try std.ArrayList(u8).initCapacity(alloc, max_msg_len),
            .replies = std.ArrayList(Message).init(alloc),
            .mutex = std.Thread.Mutex{},
            .cond = std.Thread.Condition{},
            .cfg = cfg,
        };
    }

    /// Deinitialize the Client.
    pub fn deinit(self: *Client) void {
        self.disconnect();
        self.buf.deinit();
        self.replies.deinit();
    }

    /// Connect to the IRC server.
    pub fn connect(self: *Client) !void {
        self.stream = try std.net.tcpConnectToHost(
            self.alloc,
            self.cfg.server,
            self.cfg.port orelse default_port,
        );
        if (self.cfg.tls) {
            const root_ca = try tls.config.CertBundle.fromSystem(self.alloc);
            self.connection = try tls.client(self.stream, .{
                .host = self.cfg.server,
                .root_ca = root_ca,
            });
        }
        utils.debug("Connected\n", .{});
    }

    /// Disconnect from the IRC server.
    pub fn disconnect(self: *Client) void {
        if (self.cfg.tls) {
            self.connection.close() catch |err| {
                utils.debug("Could not close connection: {}\n", .{err});
                return;
            };
        }
        self.stream.close();
        utils.debug("Disconnected\n", .{});
    }

    fn pong(self: *Client, id: []const u8) !void {
        try self.sendCommand("PONG :{s}{s}", .{ id, delimiter });
    }

    pub fn register(self: *Client) !void {
        try self.sendCommand("NICK {s}{s}USER {s} * * :{s}{s}", .{
            self.cfg.nick,
            delimiter,
            self.cfg.user,
            self.cfg.real_name,
            delimiter,
        });
    }

    pub fn nick(self: *Client, nickname: []const u8, hopcount: ?u8) !void {
        if (hopcount) |hopcount_val| {
            try self.sendCommand("NICK {s} {d}{s}", .{ nickname, hopcount_val, delimiter });
        } else {
            try self.sendCommand("NICK {s}{s}", .{ nickname, delimiter });
        }
    }

    pub fn join(self: *Client, channel: []const u8) !void {
        try self.sendCommand("JOIN {s}{s}", .{ channel, delimiter });
    }

    pub fn part(self: *Client, channels: []const u8, reason: ?[]const u8) !void {
        try self.sendCommand("PART {s} :{s}{s}", .{ channels, reason orelse "", delimiter });
    }

    pub fn privmsg(self: *Client, target: []const u8, text: []const u8) !void {
        try self.sendCommand("PRIVMSG {s} :{s}{s}", .{ target, text, delimiter });
    }

    fn sendCommand(self: *Client, comptime cmd_fmt: []const u8, args: anytype) !void {
        const raw_msg = try std.fmt.allocPrint(self.alloc, cmd_fmt, args);
        defer self.alloc.free(raw_msg);

        _ = switch (self.cfg.tls) {
            true => try self.connection.write(raw_msg),
            false => try self.stream.write(raw_msg),
        };
    }

    fn msgCallbackWorker(self: *Client, msg: Message, msg_callback: fn (Message) ?Message) !void {
        const reply = msg_callback(msg) orelse return;
        self.mutex.lock();
        try self.replies.append(reply);
        self.mutex.unlock();
        self.cond.signal();
    }

    fn handleMessage(
        self: *Client,
        raw_msg: []u8,
        loop_config: LoopConfig,
    ) !void {
        if (raw_msg.len < 4) {
            return;
        }

        // Handle the PING messages ourselves.
        if (std.mem.eql(u8, raw_msg[0..4], "PING")) {
            const index = std.mem.indexOf(u8, raw_msg, ":").?;
            const id = raw_msg[index + 1 ..];
            try self.pong(id);
            return;
        }

        // Auto-join the configured channels.
        if (std.mem.indexOf(u8, raw_msg, " 376 ")) |_| {
            for (self.cfg.channels) |channel| {
                try self.join(channel);
            }
        }

        // Otherwise parse the raw_msg into a ProtoMessage and Message.
        // Spawn a thread to handle the message using msg_callback.
        // Detach the thread so that it takes care of cleanup itself.
        var proto_msg = ProtoMessage.parse(raw_msg) catch return;
        utils.debug("Command: {}\n", .{proto_msg.command});
        const msg = proto_msg.toMessage() orelse return;
        if (loop_config.msg_callback) |msg_callback| {
            if (loop_config.spawn_thread(msg)) {
                const thread = try std.Thread.spawn(.{}, msgCallbackWorker, .{ self, msg, msg_callback });
                utils.debug("Started message callback worker thread\n", .{});
                thread.detach();
            } else {
                try self.msgCallbackWorker(msg, msg_callback);
            }
        }
    }

    pub fn loop(self: *Client, loop_config: LoopConfig) !void {
        const thread = try std.Thread.spawn(.{}, writeLoop, .{self});
        thread.detach();
        try self.readLoop(loop_config);
    }

    fn readLoop(self: *Client, loop_config: LoopConfig) !void {
        while (true) {
            switch (self.cfg.tls) {
                true => {
                    const reader = self.connection.reader();
                    try reader.streamUntilDelimiter(self.buf.writer(), '\n', max_msg_len);
                },
                false => {
                    const reader = self.stream.reader();
                    try reader.streamUntilDelimiter(self.buf.writer(), '\n', max_msg_len);
                },
            }

            // If there's nothing read from the stream, the connection was closed.
            if (self.buf.items.len == 0) {
                utils.debug("Connection Closed\n", .{});
                return;
            }

            try self.handleMessage(self.buf.items[0..self.buf.items.len], loop_config);

            // Clear the client's buffer at the end of the loop.
            // This is crucial to avoid corrupted messages.
            self.buf.clearRetainingCapacity();
        }
    }

    fn writeLoop(self: *Client) !void {
        while (true) {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.replies.items.len > 0) {
                const reply = self.replies.pop() orelse return;

                switch (reply) {
                    .NICK => |args| {
                        try self.nick(args.nickname, args.hopcount);
                    },
                    .PRIVMSG => |args| {
                        try self.privmsg(args.targets, args.text);
                    },
                    .JOIN => |args| {
                        try self.join(args.channels);
                    },
                    .PART => |args| {
                        try self.part(args.channels, args.reason);
                    },
                    else => {
                        utils.debug("Unsupported message type\n", .{});
                    },
                }
            } else {
                self.cond.wait(&self.mutex);
            }
        }
    }
};
