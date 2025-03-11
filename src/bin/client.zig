// src/bin/client.zig
const std = @import("std");
const client = @import("client");
const ClientEngine = client.ClientProcessingEngine;
const ClientAppInterface = @import("../client/app_interface.zig").ClientAppInterface;

pub fn main() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create engine
    var engine = try ClientEngine.init(allocator);
    defer engine.deinit();
    
    // Create interface
    var interface = try ClientAppInterface.init(allocator, engine);
    defer interface.deinit();
    
    std.debug.print("File Retrieval Engine Client\n", .{});
    std.debug.print("Use 'connect <server_ip> <port>' to connect to a server\n", .{});
    std.debug.print("Type 'help' for list of available commands\n\n", .{});
    
    try interface.readCommands();
}
