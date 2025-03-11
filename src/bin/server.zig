// src/bin/server.zig
const std = @import("std");
const server = @import("server");
const common = @import("common");
const IndexStore = server.IndexStore;
const ServerProcessingEngine = @import("../server/engine.zig").ServerProcessingEngine;
const ServerAppInterface = @import("../server/app_interface.zig").ServerAppInterface;

pub fn main() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Parse command line arguments
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len != 2) {
        std.debug.print("Usage: {s} <server_port>\n", .{args[0]});
        std.debug.print("Note: Use a non-privileged port number (1024-65535)\n", .{});
        return error.InvalidArguments;
    }
    
    const server_port = try std.fmt.parseInt(u16, args[1], 10);
    if (server_port < 1024) {
        return error.PortTooLow;
    }
    
    // Create store
    var store = try IndexStore.init(allocator);
    defer store.deinit();
    
    // Create engine
    var engine = try ServerProcessingEngine.init(allocator, store, 8);
    defer engine.deinit();
    
    // Create interface
    var interface = try ServerAppInterface.init(allocator, engine);
    defer interface.deinit();
    
    std.debug.print("Starting File Retrieval Engine Server on port {d}\n", .{server_port});
    
    try engine.initialize(server_port);
    
    std.debug.print("Server initialized. Type 'list' to see connected clients or 'quit' to shutdown.\n", .{});
    
    try interface.readCommands();
}
