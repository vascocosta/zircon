//! IRC Client implementation with TLS support.
//! This module provides an IRC client that can connect, authenticate, and send messages.
const std = @import("std");
const tls = @import("tls");

const utils = @import("utils.zig");
pub const Message = @import("message.zig").Message;
pub const ProtoMessage = @import("message.zig").ProtoMessage;

const default_port = 6667;
const delimiter = "\r\n";
const max_msg_len = 512;

/// Represents an IRC client.
pub const Client = struct {
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    connection: tls.Connection(std.net.Stream),
    buf: std.ArrayList(u8),
    replies: std.ArrayList(Message),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    cfg: Config,

    /// Configuration for the IRC client.
    pub const Config = struct {
        user: []const u8,
        nick: []const u8,
        real_name: []const u8,
        server: []const u8,
        port: ?u16,
        tls: bool = false,
        channels: [][]const u8,
    };

    /// Configuration for the main loop of the IRC client.
    const LoopConfig = struct {
        fn defaultSpawnThread(_: Message) bool {
            return false;
        }

        msg_callback: ?fn (Message) ?Message = null,
        spawn_thread: fn (Message) bool = defaultSpawnThread,
    };

    /// Error set for the Client struct.
    pub const ClientError = error{
        ConnectionFailed,
        MemoryAllocationFailed,
        NetworkReadFailed,
        NetworkWriteFailed,
        ThreadSpawnFailed,
        TlsHandshakeFailed,
    };

    /// Initializes a new IRC client.
    ///
    /// - `alloc`: Memory allocator.
    /// - `cfg`: Client configuration.
    ///
    /// Returns: A new `Client` instance or an error.
    pub fn init(alloc: std.mem.Allocator, cfg: Config) ClientError!Client {
        return .{
            .alloc = alloc,
            .stream = undefined,
            .connection = undefined,
            .buf = std.ArrayList(u8).initCapacity(alloc, max_msg_len) catch |err| {
                utils.debug("Memory allocation failed: {}", .{err});
                return ClientError.MemoryAllocationFailed;
            },
            .replies = std.ArrayList(Message).init(alloc),
            .mutex = std.Thread.Mutex{},
            .cond = std.Thread.Condition{},
            .cfg = cfg,
        };
    }

    /// Deinitializes the client, freeing resources.
    pub fn deinit(self: *Client) void {
        self.disconnect();
        self.buf.deinit();
        self.replies.deinit();
    }

    /// Establishes a connection to the IRC server.
    pub fn connect(self: *Client) ClientError!void {
        // Normal unencrypted TCP connection.
        self.stream = std.net.tcpConnectToHost(
            self.alloc,
            self.cfg.server,
            self.cfg.port orelse default_port,
        ) catch |err| {
            utils.debug("Connection failed: {}\n", .{err});
            return ClientError.ConnectionFailed;
        };

        // TLS handshake process wrapping a TCP stream.
        if (self.cfg.tls) {
            const root_ca = tls.config.CertBundle.fromSystem(self.alloc) catch |err| {
                utils.debug("Could not get root CA: {}", .{err});
                return ClientError.TlsHandshakeFailed;
            };
            self.connection = tls.client(self.stream, .{
                .host = self.cfg.server,
                .root_ca = root_ca,
            }) catch |err| {
                utils.debug("TLS handshake failed: {}", .{err});
                return ClientError.TlsHandshakeFailed;
            };
        }
        utils.debug("Connected\n", .{});
    }

    /// Disconnects from the IRC server.
    pub fn disconnect(self: *Client) void {
        var buffer: [10]u8 = undefined;
        const n = self.stream.readAll(buffer[0..]) catch return;
        if (n == 0) {
            return;
        }
        if (self.cfg.tls) {
            self.connection.close() catch |err| {
                utils.debug("Could not close connection: {}\n", .{err});
                return;
            };
        }
        self.stream.close();
        utils.debug("Disconnected\n", .{});
    }

    /// Sends a PONG response to the server.
    ///
    /// - `id`: PING message id.
    fn pong(self: *Client, id: []const u8) ClientError!void {
        try self.sendCommand("PONG :{s}{s}", .{ id, delimiter });
    }

    /// Registers the client with the IRC server.
    pub fn register(self: *Client) ClientError!void {
        try self.sendCommand("NICK {s}{s}USER {s} * * :{s}{s}", .{
            self.cfg.nick,
            delimiter,
            self.cfg.user,
            self.cfg.real_name,
            delimiter,
        });
    }

    /// Changes the nickname of the client.
    ///
    /// - `nickname`: New nickname.
    /// - `hopcount`: Optional hop count value.
    pub fn nick(self: *Client, nickname: []const u8, hopcount: ?u8) ClientError!void {
        if (hopcount) |hopcount_val| {
            try self.sendCommand("NICK {s} {d}{s}", .{ nickname, hopcount_val, delimiter });
        } else {
            try self.sendCommand("NICK {s}{s}", .{ nickname, delimiter });
        }
    }

    /// Joins an IRC channel.
    ///
    /// - `channels`: channel(s) to join.
    pub fn join(self: *Client, channels: []const u8) ClientError!void {
        try self.sendCommand("JOIN {s}{s}", .{ channels, delimiter });
    }

    /// Sends a notice message to a user or channel.
    ///
    /// - `targets`: Target user(s) or channel(s).
    /// - `text`: Message content.
    pub fn notice(self: *Client, targets: []const u8, text: []const u8) ClientError!void {
        try self.sendCommand("NOTICE {s} :{s}{s}", .{ targets, text, delimiter });
    }

    /// Leaves an IRC channel.
    ///
    /// - `channels`: Channel(s) to leave.
    /// - `reason`: Optional reason for leaving.
    pub fn part(self: *Client, channels: []const u8, reason: ?[]const u8) ClientError!void {
        try self.sendCommand("PART {s} :{s}{s}", .{ channels, reason orelse "", delimiter });
    }

    /// Sends a private message to a user or channel.
    ///
    /// - `targets`: Target user(s) or channel(s).
    /// - `text`: Message content.
    pub fn privmsg(self: *Client, targets: []const u8, text: []const u8) ClientError!void {
        try self.sendCommand("PRIVMSG {s} :{s}{s}", .{ targets, text, delimiter });
    }

    /// Quits the IRC server.
    ///
    /// - `reason`: Optional reason for quiting.
    pub fn quit(self: *Client, reason: ?[]const u8) ClientError!void {
        try self.sendCommand("QUIT :{s}{s}", .{ reason orelse "", delimiter });
    }

    /// Gets or sets the topic of a channel.
    ///
    /// - `text`: Optional topic to set.
    pub fn topic(self: *Client, channel: []const u8, text: ?[]const u8) ClientError!void {
        if (text != null and !std.mem.eql(u8, text.?, "")) {
            try self.sendCommand("TOPIC {s} :{s}{s}", .{ channel, text.?, delimiter });
        } else {
            try self.sendCommand("TOPIC {s}{s}", .{ channel, delimiter });
        }
    }

    fn sendCommand(self: *Client, comptime cmd_fmt: []const u8, args: anytype) ClientError!void {
        const raw_msg = std.fmt.allocPrint(self.alloc, cmd_fmt, args) catch |err| {
            utils.debug("Memory allocation failed: {}", .{err});
            return ClientError.MemoryAllocationFailed;
        };
        defer self.alloc.free(raw_msg);

        _ = switch (self.cfg.tls) {
            true => self.connection.write(raw_msg) catch |err| {
                utils.debug("Network write failed: {}", .{err});
                return ClientError.NetworkWriteFailed;
            },
            false => self.stream.write(raw_msg) catch |err| {
                utils.debug("Network write failed: {}", .{err});
                return ClientError.NetworkWriteFailed;
            },
        };
    }

    fn msgCallbackWorker(self: *Client, msg: Message, msg_callback: fn (Message) ?Message) ClientError!void {
        const reply = msg_callback(msg) orelse return;
        self.mutex.lock();
        self.replies.append(reply) catch |err| {
            utils.debug("Memory allocation failed: {}", .{err});
            return ClientError.MemoryAllocationFailed;
        };
        self.mutex.unlock();
        self.cond.signal();
    }

    fn handleMessage(self: *Client, raw_msg: []u8, loop_config: LoopConfig) ClientError!void {
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
                const thread = std.Thread.spawn(.{}, msgCallbackWorker, .{ self, msg, msg_callback }) catch |err| {
                    utils.debug("Thread spawn failed: {}", .{err});
                    return ClientError.ThreadSpawnFailed;
                };
                utils.debug("Started message callback worker thread\n", .{});
                thread.detach();
            } else {
                self.msgCallbackWorker(msg, msg_callback) catch |err| {
                    utils.debug("Thread spawn failed: {}", .{err});
                    return ClientError.ThreadSpawnFailed;
                };
            }
        }
    }

    /// The main event loop for reading messages.
    ///
    /// - `loop_config`: Main event loop configuration.
    pub fn loop(self: *Client, loop_config: LoopConfig) ClientError!void {
        const thread = std.Thread.spawn(.{}, writeLoop, .{self}) catch |err| {
            utils.debug("Thread spawn failed: {}", .{err});
            return ClientError.ThreadSpawnFailed;
        };
        thread.detach();
        try self.readLoop(loop_config);
    }

    /// Reads messages from the server and processes them.
    ///
    /// - `loop_config`: Main event loop configuration.
    fn readLoop(self: *Client, loop_config: LoopConfig) ClientError!void {
        while (true) {
            switch (self.cfg.tls) {
                true => {
                    const reader = self.connection.reader();
                    reader.streamUntilDelimiter(self.buf.writer(), '\n', max_msg_len) catch return;
                },
                false => {
                    const reader = self.stream.reader();
                    reader.streamUntilDelimiter(self.buf.writer(), '\n', max_msg_len) catch return;
                },
            }

            // If there's nothing read from the stream, the connection was closed.
            if (self.buf.items.len == 0) {
                utils.debug("Connection Closed\n", .{});
                return;
            }

            // Handle the message previously read and stored in the buffer.
            try self.handleMessage(self.buf.items[0..self.buf.items.len], loop_config);

            // Clear the client's buffer at the end of the loop.
            // This is crucial to avoid corrupted messages.
            self.buf.clearRetainingCapacity();
        }
    }

    /// Writes messages from the server and processes them.
    fn writeLoop(self: *Client) ClientError!void {
        while (true) {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.replies.items.len > 0) {
                const reply = self.replies.pop() orelse return;

                switch (reply) {
                    .NICK => |args| {
                        try self.nick(args.nickname, args.hopcount);
                    },
                    .NOTICE => |args| {
                        try self.notice(args.targets, args.text);
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
                    .QUIT => |args| {
                        try self.quit(args.reason);
                    },
                    .TOPIC => |args| {
                        try self.topic(args.channel, args.text);
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
