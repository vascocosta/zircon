const std = @import("std");
const expect = std.testing.expect;

const default_port = 6667;
const delimiter = "\r\n";
const max_msg_len = 512;

pub const Message = union(enum) {
    JOIN: struct {
        channels: []const u8,
        keys: []const u8,
    },
    NICK: struct {
        nick: []const u8,
        hopcount: ?u8,
    },
    PRIVMSG: struct {
        targets: []const u8,
        text: []const u8,
    },
    PART: struct {
        channels: []const u8,
        text: []const u8,
    },
    NOMSG: void,
};

pub const ProtoMessage = struct {
    const MessageError = error{
        ParseError,
        UnknownError,
    };

    const Command = enum {
        RPL_WELCOME,
        RPL_YOURHOST,
        RPL_CREATED,
        RPL_MYINFO,
        RPL_ISUPPORT,

        RPL_ENDOFWHO,
        RPL_TOPIC,
        RPL_WHOREPLY,
        RPL_NAMREPLY,
        RPL_WHOSPCRPL,
        RPL_ENDOFNAMES,

        AWAY,
        INVITE,
        ISON,
        JOIN,
        MODE,
        MOTD,
        NICK,
        NOTICE,
        PART,
        PING,
        PONG,
        PRIVMSG,
        QUIT,
        TOPIC,
        WHO,
        WHOIS,
        WHOWAS,

        const map = std.StaticStringMap(Command).initComptime(.{
            .{ "001", .RPL_WELCOME },
            .{ "002", .RPL_YOURHOST },
            .{ "003", .RPL_CREATED },
            .{ "004", .RPL_MYINFO },
            .{ "005", .RPL_ISUPPORT },

            .{ "315", .RPL_ENDOFWHO },
            .{ "332", .RPL_TOPIC },
            .{ "352", .RPL_WHOREPLY },
            .{ "353", .RPL_NAMREPLY },
            .{ "354", .RPL_WHOSPCRPL },
            .{ "366", .RPL_ENDOFNAMES },

            .{ "AWAY", .AWAY },
            .{ "INVITE", .INVITE },
            .{ "ISON", .ISON },
            .{ "JOIN", .JOIN },
            .{ "MODE", .MODE },
            .{ "MOTD", .MOTD },
            .{ "NICK", .NICK },
            .{ "NOTICE", .NOTICE },
            .{ "PART", .PART },
            .{ "PING", .PING },
            .{ "PONG", .PONG },
            .{ "PRIVMSG", .PRIVMSG },
            .{ "QUIT", .QUIT },
            .{ "TOPIC", .TOPIC },
            .{ "WHO", .WHO },
            .{ "WHOIS", .WHOIS },
            .{ "WHOWAS", .WHOWAS },
        });
    };

    pub const ParamIterator = struct {
        params: ?[]const u8,
        index: usize = 0,

        pub fn next(self: *ParamIterator) ?[]const u8 {
            if (self.params == null) return null;

            const start = self.index;
            while (self.index < self.params.?.len) {
                if (self.params.?[start] == ':') {
                    self.index = self.params.?.len;
                    return self.params.?[start + 1 ..];
                } else {
                    if (self.params.?[self.index] == ' ' or self.index == self.params.?.len) {
                        self.index += 1;
                        return self.params.?[start .. self.index - 1];
                    }
                    self.index += 1;
                }
            }

            return null;
        }

        pub fn init(params: ?[]const u8) ParamIterator {
            return .{
                .params = params,
                .index = 0,
            };
        }
    };

    prefix: ?[]const u8,
    command: Command,
    params: ParamIterator,

    pub fn parse(raw_message: []const u8) !ProtoMessage {
        // If the message is shorter than a numeric code, bail out soon.
        if (raw_message.len < 3) {
            return MessageError.ParseError;
        }

        // Parse message prefix.
        var prefix: ?[]const u8 = null;
        var rest: []const u8 = std.mem.trim(u8, raw_message, &std.ascii.whitespace);
        if (rest[0] == ':') {
            var iter = std.mem.tokenizeAny(u8, rest[1..], &std.ascii.whitespace);
            prefix = iter.next();
            rest = iter.rest();
        }

        // Parse message command.
        var iter = std.mem.tokenizeAny(u8, rest, &std.ascii.whitespace);
        const command = Command.map.get(iter.next() orelse return MessageError.ParseError) orelse return MessageError.ParseError;
        rest = iter.rest();

        // Create param iterator.
        const params = if (std.mem.eql(u8, rest, "")) ParamIterator.init(null) else ParamIterator.init(rest);

        return .{
            .prefix = prefix,
            .command = command,
            .params = params,
        };
    }

    pub fn toMessage(self: *ProtoMessage) ?Message {
        switch (self.command) {
            .JOIN => return Message{
                .JOIN = .{
                    .channels = self.params.next() orelse "",
                    .keys = self.params.next() orelse "",
                },
            },
            .NICK => return Message{
                .NICK = .{
                    .nick = self.params.next() orelse "",
                    .hopcount = std.fmt.parseUnsigned(u8, self.params.next() orelse "", 10) catch null,
                },
            },
            .PRIVMSG => return Message{
                .PRIVMSG = .{
                    .targets = self.params.next() orelse "",
                    .text = self.params.next() orelse "",
                },
            },
            .PART => return Message{
                .PART = .{
                    .channels = self.params.next() orelse "",
                    .text = self.params.next() orelse "",
                },
            },
            else => return null,
        }
    }
};

pub const Client = struct {
    pub const Config = struct {
        user: []const u8,
        nick: []const u8,
        real_name: []const u8,
        server: []const u8,
        port: ?u16,
        channels: [][]const u8,
    };

    alloc: std.mem.Allocator,
    stream: std.net.Stream = undefined,
    buf: std.ArrayList(u8) = undefined,
    replies: std.ArrayList(Message) = undefined,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    cfg: Config,

    pub fn init(alloc: std.mem.Allocator, cfg: Config) !Client {
        return .{
            .alloc = alloc,
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
        std.debug.print("Connected\n", .{});
    }

    pub fn disconnect(self: *Client) void {
        self.stream.close();
        std.debug.print("Disconnected\n", .{});
    }

    pub fn pong(self: *Client, id: []const u8) !void {
        const msg = try std.fmt.allocPrint(self.alloc, "PONG :{s}{s}", .{ id, delimiter });
        defer self.alloc.free(msg);

        _ = try self.stream.write(msg);
    }

    pub fn register(self: *Client) !void {
        const msg = try std.fmt.allocPrint(self.alloc, "NICK {s}{s}USER {s} * * :{s}{s}", .{
            self.cfg.nick,
            delimiter,
            self.cfg.user,
            self.cfg.real_name,
            delimiter,
        });
        defer self.alloc.free(msg);

        _ = try self.stream.write(msg);
    }

    pub fn join(self: *Client, channel: []const u8) !void {
        const msg = try std.fmt.allocPrint(self.alloc, "JOIN {s}{s}", .{ channel, delimiter });
        defer self.alloc.free(msg);

        _ = try self.stream.write(msg);
    }

    pub fn privmsg(self: *Client, target: []const u8, text: []const u8) !void {
        const msg = try std.fmt.allocPrint(self.alloc, "PRIVMSG {s} :{s} {s}", .{ target, text, delimiter });
        defer self.alloc.free(msg);

        _ = try self.stream.write(msg);
    }

    fn msgCallbackWorker(self: *Client, message: Message, msg_callback: fn (Message) ?Message) !void {
        const reply = msg_callback(message) orelse return;
        self.mutex.lock();
        try self.replies.append(reply);
        self.mutex.unlock();
        self.cond.signal();
    }

    pub fn handleMessage(self: *Client, msg: []u8, msg_callback: fn (Message) ?Message) !void {
        if (msg.len < 4) {
            return;
        }

        if (std.mem.eql(u8, msg[0..4], "PING")) {
            const index = std.mem.indexOf(u8, msg, ":").?;
            const id = msg[index + 1 ..];
            try self.pong(id);
        }

        if (std.mem.indexOf(u8, msg, " 376 ")) |_| {
            for (self.cfg.channels) |channel| {
                try self.join(channel);
            }
        }

        var proto_message = ProtoMessage.parse(msg) catch return;
        std.debug.print("Command: {}\n", .{proto_message.command});
        const message = proto_message.toMessage() orelse return;

        const thread = try std.Thread.spawn(.{}, msgCallbackWorker, .{ self, message, msg_callback });
        thread.detach();
    }

    pub fn readLoop(self: *Client, msg_callback: fn (Message) ?Message) !void {
        while (true) {
            const reader = self.stream.reader();
            try reader.streamUntilDelimiter(self.buf.writer(), '\n', max_msg_len);

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

    pub fn writeLoop(self: *Client) !void {
        while (true) {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.replies.items.len > 0) {
                const reply = self.replies.popOrNull() orelse return;
                try self.privmsg(reply.PRIVMSG.targets, reply.PRIVMSG.text);
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
