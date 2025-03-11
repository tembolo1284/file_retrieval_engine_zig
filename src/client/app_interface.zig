// src/client/app_interface.zig
const std = @import("std");
const ClientProcessingEngine = @import("engine.zig").ClientProcessingEngine;

/// Interface for controlling the client via command line
pub const ClientAppInterface = struct {
    allocator: std.mem.Allocator,
    engine: *ClientProcessingEngine,
    
    pub fn init(allocator: std.mem.Allocator, engine: *ClientProcessingEngine) !*ClientAppInterface {
        std.debug.print("Initializing ClientAppInterface\n", .{});
        
        var self = try allocator.create(ClientAppInterface);
        errdefer allocator.destroy(self);
        
        self.* = .{
            .allocator = allocator,
            .engine = engine,
        };
        
        return self;
    }
    
    pub fn deinit(self: *ClientAppInterface) void {
        std.debug.print("Deinitializing ClientAppInterface\n", .{});
        self.allocator.destroy(self);
    }
    
    pub fn readCommands(self: *ClientAppInterface) !void {
        std.debug.print("File Retrieval Engine Client\n", .{});
        std.debug.print("Available commands: connect, get_info, index, search, help, quit\n", .{});
        
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();
        
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        while (true) {
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
            const should_quit = self.handleCommand(command) catch |err| {
                std.debug.print("Error: {}\n", .{err});
                continue;
            };
            
            if (should_quit) {
                std.debug.print("Client shutdown complete.\n", .{});
                break;
            }
        }
    }
    
    fn handleCommand(self: *ClientAppInterface, command: []const u8) !bool {
        std.debug.print("Handling command: '{s}'\n", .{command});
        
        // Split command into parts
        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        
        var it = std.mem.tokenize(u8, command, " \t");
        while (it.next()) |part| {
            try parts.append(part);
        }
        
        if (parts.items.len == 0) {
            return false;
        }
        
        const cmd = parts.items[0];
        
        if (std.mem.eql(u8, cmd, "quit")) {
            std.debug.print("Disconnecting from server...\n", .{});
            try self.engine.disconnect();
            std.debug.print("Disconnected. Goodbye!\n", .{});
            return true;
        } else if (std.mem.eql(u8, cmd, "connect")) {
            if (parts.items.len != 3) {
                return error.UsageError;
            }
            
            const server_ip = parts.items[1];
            const server_port = parts.items[2];
            
            try self.engine.connect(server_ip, server_port);
            std.debug.print("Successfully connected to server at {s}:{s}\n", .{server_ip, server_port});
            return false;
        } else if (std.mem.eql(u8, cmd, "get_info")) {
            const client_id = self.engine.getClientId();
            
            if (client_id > 0) {
                std.debug.print("Client ID: {d}\n", .{client_id});
            } else {
                std.debug.print("Not connected to server\n", .{});
            }
            
            return false;
        } else if (std.mem.eql(u8, cmd, "index")) {
            if (parts.items.len != 2) {
                return error.UsageError;
            }
            
            const folder_path = parts.items[1];
            
            if (!self.engine.isServerConnected()) {
                return error.NotConnected;
            }
            
            const result = try self.engine.indexFolder(folder_path);
            
            std.debug.print("Indexing completed:\n", .{});
            std.debug.print("Total bytes processed: {d}\n", .{result.total_bytes_read});
            std.debug.print("Execution time: {d:.2} seconds\n", .{result.execution_time});
            
            const throughput = @intToFloat(f64, result.total_bytes_read) / (1024.0 * 1024.0) / result.execution_time;
            std.debug.print("Throughput: {d:.2} MB/s\n", .{throughput});
            
            return false;
        } else if (std.mem.eql(u8, cmd, "search")) {
            if (parts.items.len < 2) {
                return error.UsageError;
            }
            
            if (!self.engine.isServerConnected()) {
                return error.NotConnected;
            }
            
            // Extract search terms (handling "AND" terms)
            var terms = std.ArrayList([]const u8).init(self.allocator);
            defer terms.deinit();
            
            for (parts.items[1..]) |term| {
                if (!std.mem.eql(u8, term, "AND")) {
                    try terms.append(term);
                }
            }
            
            if (terms.items.len == 0) {
                return error.NoSearchTerms;
            }
            
            const start_time = std.time.nanoTimestamp();
            
            const result = try self.engine.search(terms.items);
            defer {
                var searchResult = result;
                searchResult.deinit(self.allocator);
            }
            
            const end_time = std.time.nanoTimestamp();
            const duration_ns = @intCast(u64, end_time - start_time);
            const duration_sec = @intToFloat(f64, duration_ns) / @intToFloat(f64, std.time.ns_per_s);
            
            std.debug.print("\nSearch completed in {d:.2} seconds\n", .{duration_sec});
            
            if (result.document_frequencies.len == 0) {
                std.debug.print("Search results (top 10 out of 0):\n", .{});
            } else {
                std.debug.print("Search results (top 10 out of {d}):\n", .{result.document_frequencies.len});
                
                // Take up to 10 results
                const max_results = @min(result.document_frequencies.len, 10);
                
                for (result.document_frequencies[0..max_results], 0..) |doc, i| {
                    const path = doc.document_path;
                    
                    // Try to extract client number from path
                    if (std.mem.startsWith(u8, path, "Client s:")) {
                        const content = path[9..]; // Skip "Client s:"
                        
                        if (std.mem.indexOf(u8, content, "/client_")) |client_pos| {
                            const client_id_start = client_pos + 8; // Skip "/client_"
                            
                            if (client_id_start < content.len) {
                                var client_id = std.ArrayList(u8).init(self.allocator);
                                defer client_id.deinit();
                                
                                var j: usize = client_id_start;
                                while (j < content.len and std.ascii.isDigit(content[j])) {
                                    try client_id.append(content[j]);
                                    j += 1;
                                }
                                
                                if (client_id.items.len > 0) {
                                    std.debug.print("* Client {s}:{s}: {d}\n", 
                                                  .{client_id.items, content, doc.word_frequency});
                                    continue;
                                }
                            }
                        }
                    }
                    
                    // If we couldn't extract a client ID, just print the original
                    std.debug.print("* {s}: {d}\n", .{path, doc.word_frequency});
                }
            }
            
            return false;
        } else if (std.mem.eql(u8, cmd, "help")) {
            std.debug.print("Available commands:\n", .{});
            std.debug.print("  connect <server IP> <server port> - Connect to server\n", .{});
            std.debug.print("  get_info                         - Display client ID\n", .{});
            std.debug.print("  index <folder path>              - Index documents in folder\n", .{});
            std.debug.print("  search <term1> AND <term2> ...   - Search indexed documents\n", .{});
            std.debug.print("  help                             - Show this help message\n", .{});
            std.debug.print("  quit                             - Exit the program\n", .{});
            
            return false;
        } else {
            std.debug.print("Unrecognized command! Type 'help' for available commands.\n", .{});
            return false;
        }
    }
};

test "client app interface command parsing" {
    const allocator = std.testing.allocator;
    
    // Create mock engine for testing
    const MockEngine = struct {
        allocator: std.mem.Allocator,
        connected: bool,
        client_id: i32,
        
        fn init(allocator: std.mem.Allocator) !*@This() {
            var self = try allocator.create(@This());
            self.* = .{
                .allocator = allocator,
                .connected = false,
                .client_id = -1,
            };
            return self;
        }
        
        fn deinit(self: *@This()) void {
            self.allocator.destroy(self);
        }
        
        fn connect(self: *@This(), server_ip: []const u8, server_port: []const u8) !void {
            _ = server_ip;
            _ = server_port;
            self.connected = true;
            self.client_id = 123;
        }
        
        fn disconnect(self: *@This()) !void {
            self.connected = false;
            self.client_id = -1;
        }
        
        fn isServerConnected(self: *@This()) bool {
            return self.connected;
        }
        
        fn getClientId(self: *@This()) i32 {
            return self.client_id;
        }
    };
    
    // Create mock engine
    var engine = try MockEngine.init(allocator);
    defer engine.deinit();
    
    // Create interface with mock engine
    var interface = try ClientAppInterface.init(allocator, @ptrCast(*ClientProcessingEngine, engine));
    defer interface.deinit();
    
    // Test help command
    try std.testing.expect(!try interface.handleCommand("help"));
    
    // Test connect command
    try interface.handleCommand("connect 127.0.0.1 12345");
    try std.testing.expect(engine.connected);
    try std.testing.expectEqual(@as(i32, 123), engine.client_id);
    
    // Test get_info command
    try std.testing.expect(!try interface.handleCommand("get_info"));
    
    // Test quit command
    try std.testing.expect(try interface.handleCommand("quit"));
    try std.testing.expect(!engine.connected);
}
