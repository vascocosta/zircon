# zircon

A simple IRC library written in Zig.

The `zircon` library is easy to use, allowing the creation of either general IRC clients or bots. One of its core concepts is the use of threads for better performance. However this is done behind the scenes in a simple way, with a dedicated thread to write messages to the server, using the main thread to read messages from the server in the main client loop (`zircon.Client.loop`) and providing a callback mechanism to the user code.

# Features

* Multithreaded design
* Good network performance
* Simple API (callback based)
* TLS connection support
* Minimal dependencies (TLS)

# Installation

## Save zircon as a dependency in `build.zig.zon` with zig fetch

```sh
fetch --save git+https://github.com/vascocosta/zircon.git
```

## Configure zircon as a module in build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myproject",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zircon = b.dependency("zircon", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zircon", zircon.module("zircon"));
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

## Import zircon into your code

```zig
const zircon = @import("zircon");
```

# Usage

[API Documentation](https://vascocosta.github.io/zircon/)

By design, the user isn't required to create any threads for simple applications like a bot. The main client loop runs on the main thread and that loop calls the callback function pointed to by `msg_callback`. One way to use this library is to define this callback in the user code to customise how to reply to incoming IRC messages with your own IRC messages making use of `zircon.Message`. You can think of this callback pattern as something that triggers when a message event happens, letting you react with another message.

By default this callback you define also runs on the main thread, but you can use the `spawn_thread` callback to override this quite easily, by returning true to automatically enable a worker thread depending on the kind of message received. This is especially useful for creating long running commands in a background thread, without the need to spawn it yourself.

For more complex use cases, like a general purpose client, you may want to create your own thread(s) to handle user input like commands. However, you should still use the main client loop and its `msg_callback` to handle incoming IRC messages. Make sure you read the two examples below to understand in more detail how `zircon` works in both scenarios...

## Examples

### Simple IRC bot

```zig
const std = @import("std");
const zircon = @import("zircon");

/// Constants used to configure the bot.
const user = "zirconbot";
const nick = "zirconbot";
const real_name = "zirconbot";
const server = "irc.quakenet.org";
const port = 6667;
const tls = false;
var join_channels = [_][]const u8{"#geeks"};
const prefix_char = "!";

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
/// On this example we only care about messages of type JOIN, PRIVMSG or PART.
/// To reply to each message we finally return another message to the loop.
fn msgCallback(message: zircon.Message) ?zircon.Message {
    switch (message) {
        .JOIN => |msg| {
            return zircon.Message{
                .PRIVMSG = .{
                    .targets = msg.channels,
                    .text = "Welcome to the channel!",
                },
            };
        },
        .PRIVMSG => |msg| {
            if (std.mem.indexOf(u8, msg.text, prefix_char) != 0) return null;

            if (Command.parse(msg.prefix, msg.targets, msg.text)) |command| {
                return command.handle();
            }

            return null;
        },
        .PART => |msg| {
            if (std.mem.containsAtLeast(u8, msg.reason, 1, "goodbye")) {
                return zircon.Message{
                    .PRIVMSG = .{
                        .targets = msg.channels,
                        .text = "Goodbye for you too!",
                    },
                };
            }
        },
        .NICK => |msg| {
            return zircon.Message{ .PRIVMSG = .{
                .targets = "#geeks",
                .text = msg.nickname,
            } };
        },
        else => return null,
    }
    return null;
}

/// spawnThread is called by zircon.Client.loop to decide when to spawn a thread.
/// The message parameter holds the IRC message that arrived from the server.
/// You can switch on the message tagged union to decide based on its kind.
/// On this example we only care about messages of type PRIVMSG or PART.
/// To spawn a thread we return true to the loop or false otherwise.
/// We should spawn a thread for long running tasks like for instance a bot command.
/// Otherwise we might block the main thread where zircon.Client.loop is running.
fn spawnThread(message: zircon.Message) bool {
    switch (message) {
        .PRIVMSG => |data| {
            if (std.ascii.startsWithIgnoreCase(data.text, prefix_char)) {
                return true;
            } else {
                return false;
            }
        },
        .PART => return true,
        else => return false,
    }
}

/// Command encapsulates each command that our IRC bot supports.
pub const Command = struct {
    name: CommandName,
    prefix: ?zircon.Prefix,
    params: []const u8,
    targets: []const u8,

    pub const CommandName = enum {
        echo,
        help,
        quit,
    };

    const map = std.StaticStringMap(Command.CommandName).initComptime(.{
        .{ "echo", CommandName.echo },
        .{ "help", CommandName.help },
        .{ "quit", CommandName.quit },
    });

    pub fn parse(prefix: ?zircon.Prefix, targets: []const u8, text: []const u8) ?Command {
        var iter = std.mem.tokenizeAny(u8, text, &std.ascii.whitespace);
        const name = iter.next() orelse return null;
        if (name.len < 2) return null;
        return .{
            .name = map.get(name[1..]) orelse return null,
            .prefix = prefix,
            .params = iter.rest(),
            .targets = targets,
        };
    }

    pub fn handle(self: Command) ?zircon.Message {
        switch (self.name) {
            .echo => return echo(self.targets, self.params),
            .help => return help(self.prefix, self.targets),
            .quit => return quit(self.params),
        }
    }

    fn echo(targets: []const u8, params: []const u8) ?zircon.Message {
        return zircon.Message{
            .PRIVMSG = .{
                .targets = targets,
                .text = params,
            },
        };
    }

    fn help(prefix: ?zircon.Prefix, targets: []const u8) ?zircon.Message {
        return zircon.Message{
            .PRIVMSG = .{
                .targets = if (prefix) |p| p.nick orelse targets else targets,
                .text = "This is the help message!",
            },
        };
    }

    fn quit(params: []const u8) ?zircon.Message {
        return zircon.Message{
            .QUIT = .{
                .reason = params,
            },
        };
    }
};
```

#### Build simple IRC bot example

```
git clone https://github.com/vascocosta/zircon.git
cd zircon/examples/simplebot
zig build -Doptimize=ReleaseSafe
```

### Simple IRC client

```zig
const std = @import("std");
const zircon = @import("zircon");

/// Constants used to configure the bot.
const user = "zirconclient";
const nick = "zirconclient";
const real_name = "zirconclient";
const server = "irc.quakenet.org";
const port = 6667;
const tls = false;
var join_channels = [_][]const u8{"#geeks"};

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
/// On this example we only care about messages of type PRIVMSG.
/// We print the targets, nick and text of every message of type PRIVMSG.
fn msgCallback(message: zircon.Message) ?zircon.Message {
    switch (message) {
        .PRIVMSG => |msg| {
            var msg_nick: []const u8 = "N/A";
            if (msg.prefix) |p| {
                if (p.nick) |n| {
                    msg_nick = n;
                }
            }
            std.debug.print("\n[{s}] <{s}>: {s}\n", .{ msg.targets, msg_nick, msg.text });
            std.debug.print("[#] <{s}>: ", .{nick});
            return null;
        },
        else => return null,
    }
    return null;
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
```

#### Build simple IRC client example

```
git clone https://github.com/vascocosta/zircon.git
cd zircon/examples/simpleclient
zig build -Doptimize=ReleaseSafe
```
