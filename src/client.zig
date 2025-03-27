const std = @import("std");
const tls = @import("tls");

const expect = std.testing.expect;

pub const Message = @import("message.zig").Message;
pub const ProtoMessage = @import("message.zig").ProtoMessage;

const default_port = 6667;
const delimiter = "\r\n";
const max_msg_len = 512;

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

    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    connection: tls.Connection(std.net.Stream),
    buf: std.ArrayList(u8),
    replies: std.ArrayList(Message),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    cfg: Config,

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

    pub fn deinit(self: *Client) void {
        self.disconnect();
        self.buf.deinit();
        self.replies.deinit();
    }

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
        std.debug.print("Connected\n", .{});
    }

    pub fn disconnect(self: *Client) void {
        if (self.cfg.tls) {
            self.connection.close() catch |err| {
                std.debug.print("Could not close connection: {}", .{err});
                return;
            };
        }
        self.stream.close();
        std.debug.print("Disconnected\n", .{});
    }

    fn pong(self: *Client, id: []const u8) !void {
        const raw_msg = try std.fmt.allocPrint(self.alloc, "PONG :{s}{s}", .{ id, delimiter });
        defer self.alloc.free(raw_msg);

        _ = switch (self.cfg.tls) {
            true => try self.connection.write(raw_msg),
            false => try self.stream.write(raw_msg),
        };
    }

    pub fn register(self: *Client) !void {
        const raw_msg = try std.fmt.allocPrint(self.alloc, "NICK {s}{s}USER {s} * * :{s}{s}", .{
            self.cfg.nick,
            delimiter,
            self.cfg.user,
            self.cfg.real_name,
            delimiter,
        });
        defer self.alloc.free(raw_msg);

        _ = switch (self.cfg.tls) {
            true => try self.connection.write(raw_msg),
            false => try self.stream.write(raw_msg),
        };
    }

    pub fn join(self: *Client, channel: []const u8) !void {
        const raw_msg = try std.fmt.allocPrint(self.alloc, "JOIN {s}{s}", .{ channel, delimiter });
        defer self.alloc.free(raw_msg);

        _ = switch (self.cfg.tls) {
            true => try self.connection.write(raw_msg),
            false => try self.stream.write(raw_msg),
        };
    }

    pub fn privmsg(self: *Client, target: []const u8, text: []const u8) !void {
        const raw_msg = try std.fmt.allocPrint(self.alloc, "PRIVMSG {s} :{s} {s}", .{ target, text, delimiter });
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

    fn handleMessage(self: *Client, raw_msg: []u8, msg_callback: ?fn (Message) ?Message) !void {
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
        std.debug.print("Command: {}\n", .{proto_msg.command});
        const msg = proto_msg.toMessage() orelse return;
        if (msg_callback) |callback| {
            const thread = try std.Thread.spawn(.{}, msgCallbackWorker, .{ self, msg, callback });
            thread.detach();
        }
    }

    pub fn loop(self: *Client, msg_callback: ?fn (Message) ?Message) !void {
        const thread = try std.Thread.spawn(.{}, writeLoop, .{self});
        thread.detach();
        try self.readLoop(msg_callback);
    }

    fn readLoop(self: *Client, msg_callback: ?fn (Message) ?Message) !void {
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
                std.debug.print("Connection Closed", .{});
                return;
            }

            //std.debug.print("{s}\n", .{self.buf.items});
            try self.handleMessage(self.buf.items[0..self.buf.items.len], msg_callback);

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
                    .PRIVMSG => |args| {
                        try self.privmsg(args.targets, args.text);
                    },
                    .JOIN => |args| {
                        try self.join(args.channels);
                    },
                    else => {
                        std.debug.print("Unsupported message type.\n", .{});
                    },
                }
            } else {
                self.cond.wait(&self.mutex);
            }
        }
    }
};

test "parse ping message without prefix" {
    const msg = try ProtoMessage.parse("PING :123456789");
    var params = msg.params;
    try expect(msg.prefix == null);
    try expect(msg.command == .PING);
    try expect(std.mem.eql(u8, params.next().?, "123456789"));
    try expect(params.next() == null);
}

test "parse ping message with prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host PING :123456789");
    var params = msg.params;
    try expect(std.mem.eql(u8, msg.prefix.?, "nick!user@host"));
    try expect(msg.command == .PING);
    try expect(std.mem.eql(u8, params.next().?, "123456789"));
    try expect(params.next() == null);
}

test "parse privmsg without prefix" {
    const msg = try ProtoMessage.parse("PRIVMSG #channel :hello world!");
    var params = msg.params;
    try expect(msg.prefix == null);
    try expect(msg.command == .PRIVMSG);
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse privmsg with prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host PRIVMSG #channel :hello world!");
    var params = msg.params;
    try expect(std.mem.eql(u8, msg.prefix.?, "nick!user@host"));
    try expect(msg.command == .PRIVMSG);
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}
