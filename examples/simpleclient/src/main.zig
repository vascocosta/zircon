const std = @import("std");
const zircon = @import("zircon");

/// Constants used to configure the bot.
const user = "zirconclient";
const nick = "zirconclient";
const real_name = "zirconclient";
const server = "irc.quakenet.org";
const port = 6667;
const tls = false;
var join_channels = [_][]const u8{"#aviation"};

/// Global Debug Allocator singleton.
var debug_allocator = std.heap.DebugAllocator(.{}).init;

pub fn main() !void {
    const allocator = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    // Create a zircon.Client with a given configuration.
    var client = try zircon.Client.init(allocator, .{
        .user = user,
        .nick = nick,
        .real_name = real_name,
        .server = server,
        .port = port,
        .tls = tls,
        .channels = &join_channels,
    });
    defer client.deinit();

    // Connect to the IRC server and perform registration.
    try client.connect();
    try client.register();

    std.debug.print("Connected...\n", .{});

    // Spawn a thread to execute clientWorker with our client logic.
    std.Thread.sleep(6000_000_000);
    const client_worker = try std.Thread.spawn(.{}, clientWorker, .{&client});
    client_worker.detach();

    // Enter the main loop that keeps reading incoming IRC messages forever.
    // The client loop accepts a LoopConfig struct with two optional fields.
    // These two fields, .msg_callback and .spawn_thread are callback pointers.
    // You set them to custom functions you define to customise the main loop.
    // .msg_callback lets you answer any received IRC message with another one.
    // .spawn_thread lets you tweak if you spawn a thread to run .msg_callback.
    try client.loop(.{
        .msg_callback = msgCallback,
        .spawn_thread = spawnThread,
    });
}

/// msgCallback is called by zircon.Client.loop when a new IRC message arrives.
/// The message parameter holds the IRC message that arrived from the server.
/// You can switch on the message tagged union to reply based on its kind.
/// On this example we only care about messages of type JOIN, PART or PRIVMSG.
/// We print the targets, nick and text of every message of type PRIVMSG.
fn msgCallback(message: zircon.Message) ?zircon.Message {
    switch (message) {
        .JOIN => |msg| {
            const msg_nick = extractNick(msg.prefix);
            std.debug.print("\n[{s}] {s} has joined.\n", .{ msg.channels, msg_nick });
        },
        .PART => |msg| {
            const msg_nick = extractNick(msg.prefix);
            std.debug.print("\n[{s}] {s} has left [{s}].\n", .{ msg.channels, msg_nick, msg.reason orelse "" });
        },
        .PRIVMSG => |msg| {
            const msg_nick = extractNick(msg.prefix);
            std.debug.print("\n[{s}] <{s}>: {s}\n", .{ msg.targets, msg_nick, msg.text });
        },
        else => return null,
    }

    std.debug.print("[#] <{s}>: ", .{nick});

    return null;
}

/// Helper function to extract the nick from a prefix.
fn extractNick(prefix: ?zircon.Prefix) []const u8 {
    return if (prefix) |p|
        if (p.nick) |n| n else "N/A"
    else
        "NA";
}

/// spawnThread is called by zircon.Client.loop to decide when to spawn a thread.
/// The message parameter holds the IRC message that arrived from the server.
/// You can switch on the message tagged union to decide based on its kind.
/// On this example we don't care about any particular kind of message.
/// Since this is a more general client, the threading logic happens elsewhere.
/// To spawn a thread we return true to the loop or false otherwise.
fn spawnThread(_: zircon.Message) bool {
    return false;
}

/// This is where we define the logic of our IRC client (handling commands).
fn clientWorker(client: *zircon.Client) !void {
    const allocator = debug_allocator.allocator();
    const stdin_reader = std.io.getStdIn().reader();
    while (true) {
        std.debug.print("[#] <{s}>: ", .{nick});
        const raw_command = try stdin_reader.readUntilDelimiterAlloc(allocator, '\n', 512);
        defer allocator.free(raw_command);

        const command = Command.parse(raw_command) orelse continue;
        switch (command.name) {
            // /say <#target(s)> <text>
            .say => {
                var iter = std.mem.tokenizeAny(u8, command.params, &std.ascii.whitespace);
                const targets = iter.next() orelse continue;
                const text = iter.rest();
                try client.privmsg(targets, text);
            },
            // /join <#channel(s)>
            .join => {
                try client.join(command.params);
            },
            // /part <#channel(s)> [reason]
            .part => {
                var iter = std.mem.tokenizeAny(u8, command.params, &std.ascii.whitespace);
                const channels = iter.next() orelse continue;
                const reason = iter.rest();
                try client.part(channels, reason);
            },
            // /quit [reason]
            .quit => try client.quit(command.params),
        }
    }
}

/// Command encapsulates each command that our IRC client supports.
const Command = struct {
    name: CommandName,
    params: []const u8,

    const CommandName = enum {
        join,
        part,
        quit,
        say,
    };

    const map = std.StaticStringMap(Command.CommandName).initComptime(.{
        .{ "/join", CommandName.join },
        .{ "/part", CommandName.part },
        .{ "/quit", CommandName.quit },
        .{ "/say", CommandName.say },
    });

    fn parse(raw_command: []const u8) ?Command {
        var iter = std.mem.tokenizeAny(u8, raw_command, &std.ascii.whitespace);
        const name = iter.next() orelse return null;
        if (name.len < 2) return null;
        return .{
            .name = map.get(name) orelse return null,
            .params = iter.rest(),
        };
    }
};
