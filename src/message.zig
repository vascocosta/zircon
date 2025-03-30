const std = @import("std");

pub const Message = union(enum) {
    JOIN: struct {
        channels: []const u8,
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

    pub fn parse(raw_msg: []const u8) !ProtoMessage {
        // If the message is shorter than a numeric code, bail out soon.
        if (raw_msg.len < 3) {
            return MessageError.ParseError;
        }

        // Parse message prefix.
        var prefix: ?[]const u8 = null;
        var rest: []const u8 = std.mem.trim(u8, raw_msg, &std.ascii.whitespace);
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
