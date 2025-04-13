//! This module defines the message structures used by the IRC client.
const std = @import("std");

const expect = std.testing.expect;

/// Represents a fully parsed IRC protocol message.
/// This is a higher level type built from `ProtoMessage` to be easily used.
pub const Message = union(enum) {
    JOIN: struct {
        prefix: ?Prefix = null,
        channels: []const u8,
    },
    NICK: struct {
        prefix: ?Prefix = null,
        nickname: []const u8,
        hopcount: ?u8,
    },
    NOTICE: struct {
        prefix: ?Prefix = null,
        targets: []const u8,
        text: []const u8,
    },
    PART: struct {
        prefix: ?Prefix = null,
        channels: []const u8,
        reason: ?[]const u8,
    },
    PRIVMSG: struct {
        prefix: ?Prefix = null,
        targets: []const u8,
        text: []const u8,
    },
    QUIT: struct {
        prefix: ?Prefix = null,
        reason: ?[]const u8,
    },
    TOPIC: struct {
        prefix: ?Prefix = null,
        channel: []const u8,
        text: ?[]const u8,
    },
    RPL_NOTOPIC: struct {
        prefix: ?Prefix = null,
        channel: []const u8,
        text: []const u8,
    },
    RPL_TOPIC: struct {
        prefix: ?Prefix = null,
        channel: []const u8,
        text: []const u8,
    },
    NOMSG: void,
};

/// Represents a semi-parsed IRC protocol message.
/// This is a lower level type where the message params is still an iterator.
pub const ProtoMessage = struct {
    prefix: ?Prefix,
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
        RPL_NOTOPIC,
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
            .{ "331", .RPL_NOTOPIC },
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
    ///
    /// - `raw_msg`: IRC message in raw format.
    pub fn parse(raw_msg: []const u8) !ProtoMessage {
        // Return early if the message is shorter than a numeric code.
        var rest: []const u8 = std.mem.trim(u8, raw_msg, &std.ascii.whitespace);
        if (rest.len < 3) {
            return MessageError.ParseError;
        }

        // Parse message prefix.
        var raw_prefix: ?[]const u8 = null;
        if (rest[0] == ':') {
            var iter = std.mem.tokenizeAny(u8, rest[1..], &std.ascii.whitespace);
            raw_prefix = iter.next();
            rest = iter.rest();
        }
        const prefix = Prefix.parse(raw_prefix orelse "");

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
                    .prefix = self.prefix,
                    .channels = self.params.next() orelse "",
                },
            },
            .NICK => return Message{
                .NICK = .{
                    .prefix = self.prefix,
                    .nickname = self.params.next() orelse "",
                    .hopcount = std.fmt.parseUnsigned(u8, self.params.next() orelse "", 10) catch null,
                },
            },
            .NOTICE => return Message{
                .NOTICE = .{
                    .prefix = self.prefix,
                    .targets = self.params.next() orelse "",
                    .text = self.params.next() orelse "",
                },
            },
            .PART => return Message{
                .PART = .{
                    .prefix = self.prefix,
                    .channels = self.params.next() orelse "",
                    .reason = self.params.next(),
                },
            },
            .PRIVMSG => return Message{
                .PRIVMSG = .{
                    .prefix = self.prefix,
                    .targets = self.params.next() orelse "",
                    .text = self.params.next() orelse "",
                },
            },
            .QUIT => return Message{
                .QUIT = .{
                    .prefix = self.prefix,
                    .reason = self.params.next(),
                },
            },
            .TOPIC => return Message{
                .TOPIC = .{
                    .prefix = self.prefix,
                    .channel = self.params.next() orelse "",
                    .text = self.params.next(),
                },
            },
            .RPL_NOTOPIC => return Message{
                .RPL_NOTOPIC = .{
                    .prefix = self.prefix,
                    .channel = self.params.next() orelse "",
                    .text = self.params.next(),
                },
            },
            .RPL_TOPIC => return Message{
                .RPL_TOPIC = .{
                    .prefix = self.prefix,
                    .channel = self.params.next() orelse "",
                    .text = self.params.next(),
                },
            },
            else => return null,
        }
    }
};

/// IRC message prefix.
pub const Prefix = struct {
    nick: ?[]const u8 = null,
    user: ?[]const u8 = null,
    host: ?[]const u8 = null,

    /// Parses a raw IRC message prefix into a `Prefix`.
    ///
    /// - `raw_prefix`: IRC message prefix in raw format.
    fn parse(raw_prefix: []const u8) ?Prefix {
        // Return early if the prefix string is empty.
        if (raw_prefix.len == 0) {
            return null;
        }

        // Return early if there are space(s).
        if (std.ascii.indexOfIgnoreCase(raw_prefix, " ")) |_| {
            return null;
        }

        const bang_index = std.ascii.indexOfIgnoreCase(raw_prefix, "!");
        const at_index = std.ascii.indexOfIgnoreCase(raw_prefix, "@");

        // Return early if the bang and the at are swapped.
        if (bang_index) |bang_index_val| {
            if (at_index) |at_index_val| {
                if (bang_index_val >= at_index_val) {
                    return null;
                }
            }
        }

        if (bang_index == null and at_index == null) {
            return .{
                .nick = raw_prefix,
            };
        } else if (bang_index != null and at_index == null) {
            return .{
                .nick = raw_prefix[0..bang_index.?],
                .user = if (bang_index.? + 1 <= raw_prefix.len) raw_prefix[bang_index.? + 1 ..] else null,
            };
        } else if (bang_index == null and at_index != null) {
            return .{
                .nick = raw_prefix[0..at_index.?],
                .host = if (at_index.? + 1 <= raw_prefix.len) raw_prefix[at_index.? + 1 ..] else null,
            };
        } else {
            return .{
                .nick = raw_prefix[0..bang_index.?],
                .user = if (bang_index.? + 1 <= raw_prefix.len) raw_prefix[bang_index.? + 1 .. at_index.?] else null,
                .host = if (at_index.? + 1 <= raw_prefix.len) raw_prefix[at_index.? + 1 ..] else null,
            };
        }
    }
};

test "parse join message without prefix" {
    const msg = try ProtoMessage.parse("JOIN #channel");

    try expect(msg.prefix == null);

    try expect(msg.command == .JOIN);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(params.next() == null);
}

test "parse join message with nick prefix" {
    const msg = try ProtoMessage.parse(":nick JOIN #channel");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .JOIN);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(params.next() == null);
}

test "parse join message with nick!user prefix" {
    const msg = try ProtoMessage.parse(":nick!user JOIN #channel");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .JOIN);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(params.next() == null);
}

test "parse join message with nick@host prefix" {
    const msg = try ProtoMessage.parse(":nick@host JOIN #channel");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .JOIN);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(params.next() == null);
}

test "parse join message with nick!user@host prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host JOIN #channel");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .JOIN);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(params.next() == null);
}

test "parse nick message without prefix" {
    const msg = try ProtoMessage.parse("NICK mynick 255");

    try expect(msg.prefix == null);

    try expect(msg.command == .NICK);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "mynick"));
    try expect(std.mem.eql(u8, params.next().?, "255"));
    try expect(params.next() == null);
}

test "parse nick message with nick prefix" {
    const msg = try ProtoMessage.parse(":nick NICK mynick 255");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .NICK);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "mynick"));
    try expect(std.mem.eql(u8, params.next().?, "255"));
    try expect(params.next() == null);
}

test "parse nick message with nick!user prefix" {
    const msg = try ProtoMessage.parse(":nick!user NICK mynick 255");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .NICK);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "mynick"));
    try expect(std.mem.eql(u8, params.next().?, "255"));
    try expect(params.next() == null);
}

test "parse nick message with nick@host prefix" {
    const msg = try ProtoMessage.parse(":nick@host NICK mynick 255");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .NICK);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "mynick"));
    try expect(std.mem.eql(u8, params.next().?, "255"));
    try expect(params.next() == null);
}

test "parse nick message with nick!user@host prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host NICK mynick 255");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .NICK);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "mynick"));
    try expect(std.mem.eql(u8, params.next().?, "255"));
    try expect(params.next() == null);
}

test "parse notice message without prefix" {
    const msg = try ProtoMessage.parse("NOTICE #channel :hello world!");

    try expect(msg.prefix == null);

    try expect(msg.command == .NOTICE);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse notice message with nick prefix" {
    const msg = try ProtoMessage.parse(":nick NOTICE #channel :hello world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .NOTICE);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse notice message with nick!user prefix" {
    const msg = try ProtoMessage.parse(":nick!user NOTICE #channel :hello world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .NOTICE);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse notice message with nick@host prefix" {
    const msg = try ProtoMessage.parse(":nick@host NOTICE #channel :hello world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .NOTICE);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse notice message with nick!user@host prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host NOTICE #channel :hello world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .NOTICE);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse part message without prefix" {
    const msg = try ProtoMessage.parse("PART #channel :goodbye world!");

    try expect(msg.prefix == null);

    try expect(msg.command == .PART);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "goodbye world!"));
    try expect(params.next() == null);
}

test "parse part message with nick prefix" {
    const msg = try ProtoMessage.parse(":nick PART #channel :goodbye world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PART);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "goodbye world!"));
    try expect(params.next() == null);
}

test "parse part message with nick!user prefix" {
    const msg = try ProtoMessage.parse(":nick!user PART #channel :goodbye world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PART);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "goodbye world!"));
    try expect(params.next() == null);
}

test "parse part message with nick@host prefix" {
    const msg = try ProtoMessage.parse(":nick@host PART #channel :goodbye world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PART);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "goodbye world!"));
    try expect(params.next() == null);
}

test "parse part message with nick!user@host prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host PART #channel :goodbye world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PART);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "goodbye world!"));
    try expect(params.next() == null);
}

test "parse ping message without prefix" {
    const msg = try ProtoMessage.parse("PING :123456789");

    try expect(msg.prefix == null);

    try expect(msg.command == .PING);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "123456789"));
    try expect(params.next() == null);
}

test "parse ping message with nick prefix" {
    const msg = try ProtoMessage.parse(":nick PING :123456789");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PING);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "123456789"));
    try expect(params.next() == null);
}

test "parse ping message with nick!user prefix" {
    const msg = try ProtoMessage.parse(":nick!user PING :123456789");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PING);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "123456789"));
    try expect(params.next() == null);
}

test "parse ping message with nick@host prefix" {
    const msg = try ProtoMessage.parse(":nick@host PING :123456789");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PING);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "123456789"));
    try expect(params.next() == null);
}

test "parse ping message with nick!user@host prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host PING :123456789");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PING);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "123456789"));
    try expect(params.next() == null);
}

test "parse privmsg message without prefix" {
    const msg = try ProtoMessage.parse("PRIVMSG #channel :hello world!");

    try expect(msg.prefix == null);

    try expect(msg.command == .PRIVMSG);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse privmsg message with nick prefix" {
    const msg = try ProtoMessage.parse(":nick PRIVMSG #channel :hello world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PRIVMSG);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse privmsg message with nick!user prefix" {
    const msg = try ProtoMessage.parse(":nick!user PRIVMSG #channel :hello world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PRIVMSG);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse privmsg message with nick@host prefix" {
    const msg = try ProtoMessage.parse(":nick@host PRIVMSG #channel :hello world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PRIVMSG);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse privmsg message with nick!user@host prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host PRIVMSG #channel :hello world!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .PRIVMSG);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "#channel"));
    try expect(std.mem.eql(u8, params.next().?, "hello world!"));
    try expect(params.next() == null);
}

test "parse quit message without prefix" {
    const msg = try ProtoMessage.parse("QUIT :goodbye!");

    try expect(msg.prefix == null);

    try expect(msg.command == .QUIT);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "goodbye!"));
    try expect(params.next() == null);
}

test "parse quit message with nick prefix" {
    const msg = try ProtoMessage.parse(":nick QUIT :goodbye!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .QUIT);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "goodbye!"));
    try expect(params.next() == null);
}

test "parse quit message with nick!user prefix" {
    const msg = try ProtoMessage.parse(":nick!user QUIT :goodbye!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.host orelse ""));

    try expect(msg.command == .QUIT);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "goodbye!"));
    try expect(params.next() == null);
}

test "parse quit message with nick@host prefix" {
    const msg = try ProtoMessage.parse(":nick@host QUIT :goodbye!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .QUIT);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "goodbye!"));
    try expect(params.next() == null);
}

test "parse quit message with nick!user@host prefix" {
    const msg = try ProtoMessage.parse(":nick!user@host QUIT :goodbye!");

    try expect(msg.prefix != null);

    try expect(std.mem.eql(u8, "nick", msg.prefix.?.nick orelse ""));
    try expect(std.mem.eql(u8, "user", msg.prefix.?.user orelse ""));
    try expect(std.mem.eql(u8, "host", msg.prefix.?.host orelse ""));

    try expect(msg.command == .QUIT);

    var params = msg.params;
    try expect(std.mem.eql(u8, params.next().?, "goodbye!"));
    try expect(params.next() == null);
}
