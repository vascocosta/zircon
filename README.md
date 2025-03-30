# zircon

A simple IRC lib written in Zig.

The zircon lib is easy to use, allowing the creation of either IRC clients or bots. One of its core concepts is the use of threads for better performance. However this is done in a simple way, with a dedicated thread to write messages to the server and using the main thread to read messages from the server.

# Features

* Multithreading
* Performance
* Simple API
* TLS support

# Examples

## Simple IRC bot

```zig
const std = @import("std");
const zircon = @import("zircon");

/// Constants used to configure the client.
const user = "zircon_bot";
const nick = "zircon_bot";
const real_name = "zircon_bot";
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

            if (Command.parse(msg.targets, msg.text)) |command| {
                return command.handle();
            }

            return null;
        },
        .PART => |msg| {
            if (std.mem.containsAtLeast(u8, msg.text, 1, "goodbye")) {
                return zircon.Message{
                    .PRIVMSG = .{
                        .targets = msg.channels,
                        .text = "Goodbye for you too!",
                    },
                };
            }
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

    pub fn parse(targets: []const u8, text: []const u8) ?Command {
        var iter = std.mem.tokenizeAny(u8, text, &std.ascii.whitespace);
        const name = iter.next() orelse return null;
        if (name.len < 2) return null;
        return .{
            .name = map.get(name[1..]) orelse return null,
            .params = iter.rest(),
            .targets = targets,
        };
    }

    pub fn handle(self: Command) ?zircon.Message {
        switch (self.name) {
            .echo => return echo(self.targets, self.params),
            .help => return help(self.targets),
            .quit => std.process.exit(0),
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

    fn help(targets: []const u8) ?zircon.Message {
        return zircon.Message{
            .PRIVMSG = .{
                .targets = targets,
                .text = "This is the help message!",
            },
        };
    }
};
```