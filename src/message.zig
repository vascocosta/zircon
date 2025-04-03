//! This module defines the message structures used by the IRC client.
const std = @import("std");

const expect = std.testing.expect;

/// Represents a fully parsed IRC protocol message.
/// This is a higher level type built from `ProtoMessage` to be easily used.
pub const Message = union(enum) {
    JOIN: struct {
        channels: []const u8,
    },
    NICK: struct {
        nickname: []const u8,
        hopcount: ?u8,
    },
    NOTICE: struct {
        targets: []const u8,
        text: []const u8,
    },
    PRIVMSG: struct {
        targets: []const u8,
        text: []const u8,
    },
    PART: struct {
        channels: []const u8,
        reason: []const u8,
    },
    NOMSG: void,
};

/// Represents a semi-parsed IRC protocol message.
/// This is a lower level type where the message params is still an iterator.
pub const ProtoMessage = struct {
    prefix: ?[]const u8,
    command: Command,
    params: ParamIterator,

    /// Error type for message parsing failures.
    const MessageError = error{
        ParseError,
        UnknownError,
    };

    /// Enumerates all possible IRC commands.
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

        /// Static map of command strings to their enum representation.
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

    /// Iterator for extracting parameters from an IRC message.
    pub const ParamIterator = struct {
        params: ?[]const u8,
        index: usize = 0,

        /// Initializes a new parameter iterator.
        pub fn init(params: ?[]const u8) ParamIterator {
            return .{
                .params = params,
                .index = 0,
            };
        }

        /// Returns the next parameter, if available.
        pub fn next(self: *ParamIterator) ?[]const u8 {
            const params = self.params orelse return null;
            const start = self.index;
            while (self.index <= params.len) {
                if (self.index == params.len) {
                    const item = params[start..self.index];

                    self.index += 1;

                    if (item.len == 0) {
                        break;
                    } else {
                        return item;
                    }
                }

                if (params[start] == ':') {
                    self.index = params.len;
                    return params[start + 1 ..];
                } else {
                    if (params[self.index] == ' ' or self.index == params.len) {
                        self.index += 1;
                        return params[start .. self.index - 1];
                    }
                    self.index += 1;
                }
            }

            return null;
        }
    };

    /// Parses a raw IRC message into a `ProtoMessage`.
    pub fn parse(raw_msg: []const u8) !ProtoMessage {
        // If the message is shorter than a numeric code, bail out soon.
        var rest: []const u8 = std.mem.trim(u8, raw_msg, &std.ascii.whitespace);
        if (rest.len < 3) {
            return MessageError.ParseError;
        }

        // Parse message prefix.
        var prefix: ?[]const u8 = null;
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

    /// Converts a `ProtoMessage` into a `Message` if possible.
    pub fn toMessage(self: *ProtoMessage) ?Message {
        switch (self.command) {
            .JOIN => return Message{
                .JOIN = .{
                    .channels = self.params.next() orelse "",
                },
            },
            .NOTICE => return Message{
                .NOTICE = .{
                    .targets = self.params.next() orelse "",
                    .text = self.params.next() orelse "",
                },
            },
            .NICK => return Message{
                .NICK = .{
                    .nickname = self.params.next() orelse "",
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
                    .reason = self.params.next() orelse "",
                },
            },
            else => return null,
        }
    }
};

test "parse notice message without prefix" {
    const msg = try ProtoMessage.parse("NOTICE #channel :hello world!");
    var params = msg.params;
    try expect(msg.prefix == null);
    try expect(msg.command == .NOTICE);
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse notice message with prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host NOTICE #channel :hello world!");
    var params = msg.params;
    try expect(std.mem.eql(u8, msg.prefix.?, "nick!user@host"));
    try expect(msg.command == .NOTICE);
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

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

test "parse part message without prefix" {
    const msg = try ProtoMessage.parse("PART #channel :goodbye!");
    var params = msg.params;
    try expect(msg.prefix == null);
    try expect(msg.command == .PART);
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "goodbye!"));
    try expect(params.next() == null);
}

test "parse part message with prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host PART #channel :goodbye!");
    var params = msg.params;
    try expect(std.mem.eql(u8, msg.prefix.?, "nick!user@host"));
    try expect(msg.command == .PART);
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "goodbye!"));
    try expect(params.next() == null);
}

test "parse nick message without prefix" {
    const msg = try ProtoMessage.parse("NICK mynick 255");
    var params = msg.params;
    try expect(msg.prefix == null);
    try expect(msg.command == .NICK);
    try expect(std.mem.eql(u8, params.next().?, "mynick"));
    try expect(std.mem.eql(u8, params.next().?, "255"));
    try expect(params.next() == null);
}

test "parse nick message with prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host NICK mynick 255");
    var params = msg.params;
    try expect(std.mem.eql(u8, msg.prefix.?, "nick!user@host"));
    try expect(msg.command == .NICK);
    try expect(std.mem.eql(u8, params.next().?, "mynick"));
    try expect(std.mem.eql(u8, params.next().?, "255"));
    try expect(params.next() == null);
}
