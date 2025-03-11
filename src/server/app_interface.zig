// src/server/app_interface.zig
const std = @import("std");
const ServerProcessingEngine = @import("engine.zig").ServerProcessingEngine;

/// Interface for controlling the server via command line
pub const ServerAppInterface = struct {
    allocator: std.mem.Allocator,
    engine: *ServerProcessingEngine,
    shutdown_requested: std.atomic.Value(bool),
    
    pub fn init(allocator: std.mem.Allocator, engine: *ServerProcessingEngine) !*ServerAppInterface {
        std.debug.print("Initializing ServerAppInterface\n", .{});
        
        var self = try allocator.create(ServerAppInterface);
        errdefer allocator.destroy(self);
        
        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .shutdown_requested = std.atomic.Value(bool).init(false),
        };
        
        return self;
    }
    
    pub fn deinit(self: *ServerAppInterface) void {
        std.debug.print("Deinitializing ServerAppInterface\n", .{});
        self.allocator.destroy(self);
    }
    
    pub fn readCommands(self: *ServerAppInterface) !void {
        std.debug.print("Server interface ready.\n", .{});
        std.debug.print("Available commands: 'list', 'quit', 'help'\n", .{});
        
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();
        
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        while (!self.shutdown_requested.load(.SeqCst)) {
            // Print prompt
            try stdout.writeAll("> ");
            
            // Clear buffer for next command
            buffer.clearRetainingCapacity();
            
            // Read a line
            stdin.readUntilDelimiterArrayList(&buffer, '\n', 1024) catch |err| {
                if (err == error.EndOfStream) {
                    // EOF, exit loop
                    break;
                }
                
                std.debug.print("Error reading command: {}\n", .{err});
                continue;
            };
            
            // Trim whitespace
            const command = std.mem.trim(u8, buffer.items, &std.ascii.spaces);
            
            if (command.len == 0) {
                continue;
            }
            
            // Handle command
            const should_quit = try self.handleCommand(command);
            if (should_quit) {
                break;
            }
        }
    }
    
    fn handleCommand(self: *ServerAppInterface, command: []const u8) !bool {
        std.debug.print("Handling command: '{s}'\n", .{command});
        
        if (std.mem.eql(u8, command, "quit")) {
            std.debug.print("Shutting down server...\n", .{});
            
            // Signal shutdown
            self.engine.shutdown();
            self.shutdown_requested.store(true, .SeqCst);
            
            std.debug.print("Server shutdown complete.\n", .{});
            return true;
        } else if (std.mem.eql(u8, command, "list")) {
            // Get connected clients
            var clients = self.engine.getConnectedClients();
            defer {
                for (clients) |client| {
                    self.allocator.free(client);
                }
                self.allocator.free(clients);
            }
            
            if (clients.len == 0) {
                std.debug.print("No clients currently connected.\n", .{});
            } else {
                std.debug.print("\nConnected Clients:\n", .{});
                std.debug.print("----------------------------------------\n", .{});
                
                for (clients) |client_info| {
                    std.debug.print("{s}\n", .{client_info});
                }
                
                std.debug.print("----------------------------------------\n", .{});
                std.debug.print("Total connected clients: {d}\n", .{clients.len});
            }
            
            return false;
        } else if (std.mem.eql(u8, command, "help")) {
            std.debug.print("Available commands:\n", .{});
            std.debug.print("  list - List all connected clients\n", .{});
            std.debug.print("  help - Show this help message\n", .{});
            std.debug.print("  quit - Shutdown the server\n", .{});
            
            return false;
        } else {
            std.debug.print("Unrecognized command! Available commands: 'list', 'help', 'quit'\n", .{});
            return false;
        }
    }
    
    pub fn isShutdownRequested(self: *ServerAppInterface) bool {
        return self.shutdown_requested.load(.SeqCst);
    }
};

test "server app interface commands" {
    // This is a simplified test since we can't easily mock the engine
    const allocator = std.testing.allocator;
    
    // We need a minimal engine mock for testing
    const MockEngine = struct {
        allocator: std.mem.Allocator,
        shutdown_called: bool,
        
        fn init(allocator: std.mem.Allocator) !*@This() {
            var self = try allocator.create(@This());
            self.* = .{
                .allocator = allocator,
                .shutdown_called = false,
            };
            return self;
        }
        
        fn deinit(self: *@This()) void {
            self.allocator.destroy(self);
        }
        
        fn shutdown(self: *@This()) void {
            self.shutdown_called = true;
        }
        
        fn getConnectedClients(self: *@This()) [][]const u8 {
            var result = self.allocator.alloc([]const u8, 1) catch return &[_][]const u8{};
            result[0] = self.allocator.dupe(u8, "Client ID: 1, IP: 127.0.0.1, Port: 12345") catch {
                self.allocator.free(result);
                return &[_][]const u8{};
            };
            return result;
        }
    };
    
    // Create mock engine
    var engine = try MockEngine.init(allocator);
    defer engine.deinit();
    
    // Create interface with mock engine
    var interface = try ServerAppInterface.init(allocator, @ptrCast(*ServerProcessingEngine, engine));
    defer interface.deinit();
    
    // Test help command
    try std.testing.expect(!try interface.handleCommand("help"));
    
    // Test list command
    try std.testing.expect(!try interface.handleCommand("list"));
    
    // Test quit command
    try std.testing.expect(try interface.handleCommand("quit"));
    try std.testing.expect(engine.shutdown_called);
}
