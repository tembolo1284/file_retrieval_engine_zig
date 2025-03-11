// src/client/engine.zig
const std = @import("std");
const WalkDir = @import("walkdir.zig").WalkDir;

/// Result of an indexing operation
pub const IndexResult = struct {
    execution_time: f64,
    total_bytes_read: i64,
};

/// Document path and word frequency pair for search results
pub const DocPathFreqPair = struct {
    document_path: []const u8,
    word_frequency: i64,
    
    pub fn init(allocator: std.mem.Allocator, path: []const u8, freq: i64) !DocPathFreqPair {
        return DocPathFreqPair{
            .document_path = try allocator.dupe(u8, path),
            .word_frequency = freq,
        };
    }
    
    pub fn deinit(self: *DocPathFreqPair, allocator: std.mem.Allocator) void {
        allocator.free(self.document_path);
    }
};

/// Document number and word frequency pair (internal use)
pub const DocFreqPair = struct {
    document_number: i64,
    word_frequency: i64,
};

/// Result of a search operation
pub const SearchResult = struct {
    execution_time: f64,
    document_frequencies: []DocPathFreqPair,
    
    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        for (self.document_frequencies) |*pair| {
            pair.deinit(allocator);
        }
        allocator.free(self.document_frequencies);
    }
};

/// Client engine for connecting to a server and performing indexing/searching
pub const ClientProcessingEngine = struct {
    allocator: std.mem.Allocator,
    client_socket: ?std.net.Stream,
    client_id: std.atomic.Value(i32),
    is_connected: std.atomic.Value(bool),
    socket_mutex: std.Thread.Mutex,
    
    const BATCH_SIZE: usize = 1024 * 1024;
    const BUFFER_SIZE: usize = 64 * 1024;
    
    pub fn init(allocator: std.mem.Allocator) !*ClientProcessingEngine {
        std.debug.print("Initializing ClientProcessingEngine\n", .{});
        
        var self = try allocator.create(ClientProcessingEngine);
        errdefer allocator.destroy(self);
        
        self.* = .{
            .allocator = allocator,
            .client_socket = null,
            .client_id = std.atomic.Value(i32).init(-1),
            .is_connected = std.atomic.Value(bool).init(false),
            .socket_mutex = std.Thread.Mutex{},
        };
        
        return self;
    }
    
    pub fn deinit(self: *ClientProcessingEngine) void {
        std.debug.print("Deinitializing ClientProcessingEngine\n", .{});
        
        // Close socket if connected
        self.disconnect() catch |err| {
            std.debug.print("Error during disconnect: {}\n", .{err});
        };
        
        // Free self
        self.allocator.destroy(self);
    }
    
    pub fn getDocumentPath(self: *ClientProcessingEngine, doc_id: i64) !?[]const u8 {
        std.debug.print("Getting document path for ID: {d}\n", .{doc_id});
        
        const request = try std.fmt.allocPrint(self.allocator, "GET_DOC_PATH {d}", .{doc_id});
        defer self.allocator.free(request);
        
        const response = try self.sendMessage(request);
        defer self.allocator.free(response);
        
        var parts = std.mem.split(u8, response, " ");
        const cmd = parts.next() orelse return null;
        
        if (std.mem.eql(u8, cmd, "DOC_PATH")) {
            const path = parts.rest();
            return try self.allocator.dupe(u8, path);
        }
        
        return null;
    }
    
    pub fn indexFolder(self: *ClientProcessingEngine, folder_path: []const u8) !IndexResult {
        std.debug.print("Indexing folder: {s}\n", .{folder_path});
        
        const start_time = std.time.nanoTimestamp();
        var total_bytes = std.atomic.Value(i64).init(0);
        
        // Ensure we're connected
        if (!self.is_connected.load(.SeqCst)) {
            return error.NotConnected;
        }
        
        // Get absolute path
        var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const absolute_path = try std.fs.realpath(folder_path, &path_buffer);
        
        std.debug.print("Indexing absolute path: {s}\n", .{absolute_path});
        
        // Collect files
        var files = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (files.items) |file| {
                self.allocator.free(file);
            }
            files.deinit();
        }
        
        // Walk directory recursively
        var walk_dir = try WalkDir.init(self.allocator, absolute_path);
        defer walk_dir.deinit();
        
        while (try walk_dir.next()) |entry| {
            if (entry.kind == .File) {
                // Add file to list
                const path_copy = try self.allocator.dupe(u8, entry.path);
                try files.append(path_copy);
            }
        }
        
        std.debug.print("Found {d} files to process\n", .{files.items.len});
        
        // Process files in chunks
        const chunk_size = @max(1, files.items.len / 4);
        
        var i: usize = 0;
        while (i < files.items.len) {
            const end = @min(i + chunk_size, files.items.len);
            const chunk = files.items[i..end];
            
            var word_freq_buffer = std.StringHashMap(i64).init(self.allocator);
            defer {
                var it = word_freq_buffer.iterator();
                while (it.next()) |kv| {
                    self.allocator.free(kv.key_ptr.*);
                }
                word_freq_buffer.deinit();
            }
            
            for (chunk) |file_path| {
                // Read file content
                const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch |err| {
                    std.debug.print("Failed to read file {s}: {}\n", .{file_path, err});
                    continue;
                };
                defer self.allocator.free(content);
                
                // Update total bytes processed
                _ = total_bytes.fetchAdd(@intCast(i64, content.len), .SeqCst);
                
                // Process document and get word frequencies
                word_freq_buffer.clearRetainingCapacity();
                try self.processDocumentEfficient(content, &word_freq_buffer);
                
                // Send index request
                try self.sendIndexRequest(file_path, &word_freq_buffer);
            }
            
            i += chunk_size;
        }
        
        const end_time = std.time.nanoTimestamp();
        const duration_ns = @intCast(u64, end_time - start_time);
        const duration_sec = @intToFloat(f64, duration_ns) / @intToFloat(f64, std.time.ns_per_s);
        
        return IndexResult{
            .execution_time = duration_sec,
            .total_bytes_read = total_bytes.load(.SeqCst),
        };
    }
    
    fn processDocumentEfficient(self: *ClientProcessingEngine, content: []const u8, word_freqs: *std.StringHashMap(i64)) !void {
        var current_word = std.ArrayList(u8).init(self.allocator);
        defer current_word.deinit();
        
        var in_word = false;
        
        for (content) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                try current_word.append(c);
                in_word = true;
            } else if (in_word) {
                if (current_word.items.len >= 3) {  // Minimum word length threshold
                    // Get or create entry in word frequency map
                    const word = current_word.items;
                    
                    const gop = try word_freqs.getOrPut(word);
                    if (gop.found_existing) {
                        gop.value_ptr.* += 1;
                    } else {
                        // Create a copy of the word for storage
                        const word_copy = try self.allocator.dupe(u8, word);
                        gop.key_ptr.* = word_copy;
                        gop.value_ptr.* = 1;
                    }
                }
                
                current_word.clearRetainingCapacity();
                in_word = false;
            }
        }
        
        // Process last word if any
        if (in_word and current_word.items.len >= 3) {
            const word = current_word.items;
            
            const gop = try word_freqs.getOrPut(word);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                // Create a copy of the word for storage
                const word_copy = try self.allocator.dupe(u8, word);
                gop.key_ptr.* = word_copy;
                gop.value_ptr.* = 1;
            }
        }
    }
    
    pub fn search(self: *ClientProcessingEngine, terms: []const []const u8) !SearchResult {
        std.debug.print("Searching for terms: {any}\n", .{terms});
        
        const start_time = std.time.nanoTimestamp();
        
        if (!self.is_connected.load(.SeqCst)) {
            return error.NotConnected;
        }
        
        // Create search request
        var request = std.ArrayList(u8).init(self.allocator);
        defer request.deinit();
        
        try request.appendSlice("SEARCH_REQUEST");
        
        for (terms) |term| {
            try request.append(' ');
            try request.appendSlice(term);
        }
        
        // Send request and get response
        const response = try self.sendMessage(request.items);
        defer self.allocator.free(response);
        
        // Parse response and build result
        const results = try self.handleSearchReply(response);
        
        const end_time = std.time.nanoTimestamp();
        const duration_ns = @intCast(u64, end_time - start_time);
        const duration_sec = @intToFloat(f64, duration_ns) / @intToFloat(f64, std.time.ns_per_s);
        
        return SearchResult{
            .execution_time = duration_sec,
            .document_frequencies = results,
        };
    }
    
    pub fn connect(self: *ClientProcessingEngine, server_ip: []const u8, server_port: []const u8) !void {
        std.debug.print("Connecting to {s}:{s}\n", .{server_ip, server_port});
        
        const port = try std.fmt.parseInt(u16, server_port, 10);
        
        // Create address
        var address: std.net.Address = undefined;
        
        // Check if using IPv4 or IPv6
        if (std.mem.indexOf(u8, server_ip, ":")) |_| {
            // IPv6
            var ip: [16]u8 = undefined;
            try std.net.Ip6Address.parse(server_ip, &ip);
            address = std.net.Address.initIp6(ip, port);
        } else {
            // IPv4
            var ip: [4]u8 = undefined;
            try std.net.Ip4Address.parse(server_ip, &ip);
            address = std.net.Address.initIp4(ip, port);
        }
        
        // Connect to server
        var stream = try std.net.tcpConnectToAddress(address);
        errdefer stream.close();
        
        // Set TCP_NODELAY option to disable Nagle's algorithm
        try stream.setNoDelay(true);
        
        // Lock socket mutex and update state
        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();
        
        // Close existing socket if any
        if (self.client_socket) |socket| {
            socket.close();
        }
        
        self.client_socket = stream;
        
        // Register with server
        const response = try self.sendMessage("REGISTER_REQUEST");
        defer self.allocator.free(response);
        
        // Parse response
        var parts = std.mem.split(u8, response, " ");
        const cmd = parts.next() orelse return error.InvalidResponse;
        const id_str = parts.next() orelse return error.InvalidResponse;
        
        if (!std.mem.eql(u8, cmd, "REGISTER_REPLY")) {
            return error.InvalidRegisterReply;
        }
        
        const id = try std.fmt.parseInt(i32, id_str, 10);
        
        self.client_id.store(id, .SeqCst);
        self.is_connected.store(true, .SeqCst);
        
        std.debug.print("Connected successfully, client ID: {d}\n", .{id});
    }
    
    pub fn disconnect(self: *ClientProcessingEngine) !void {
        std.debug.print("Disconnecting from server\n", .{});
        
        if (self.is_connected.load(.SeqCst)) {
            self.socket_mutex.lock();
            defer self.socket_mutex.unlock();
            
            if (self.client_socket) |socket| {
                // Send quit request
                _ = socket.write("QUIT_REQUEST\n") catch |err| {
                    std.debug.print("Error sending quit request: {}\n", .{err});
                };
                
                // Close socket
                socket.close();
                self.client_socket = null;
            }
            
            self.is_connected.store(false, .SeqCst);
            self.client_id.store(-1, .SeqCst);
        }
    }
    
    pub fn isServerConnected(self: *ClientProcessingEngine) bool {
        return self.is_connected.load(.SeqCst);
    }
    
    pub fn getClientId(self: *ClientProcessingEngine) i32 {
        return self.client_id.load(.SeqCst);
    }
    
    // Helper methods
    fn sendMessage(self: *ClientProcessingEngine, message: []const u8) ![]const u8 {
        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();
        
        const socket = self.client_socket orelse return error.NotConnected;
        
        // Format message with newline
        var formatted_message = try std.fmt.allocPrint(self.allocator, "{s}\n", .{message});
        defer self.allocator.free(formatted_message);
        
        // Send message
        try socket.writeAll(formatted_message);
        try socket.flush();
        
        // Read response
        var reader = socket.reader();
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        // Read until newline
        try reader.readUntilDelimiterArrayList(&buffer, '\n', 10 * 1024 * 1024);
        
        // Create copy of response
        return self.allocator.dupe(u8, buffer.items);
    }
    
    fn sendIndexRequest(self: *ClientProcessingEngine, file_path: []const u8, word_freqs: *const std.StringHashMap(i64)) !void {
        std.debug.print("Indexing file: {s} with {d} unique terms\n", .{file_path, word_freqs.count()});
        
        // Pre-calculate capacity needed
        var total_len: usize = 14; // "INDEX_REQUEST "
        total_len += file_path.len + 1; // file_path + space
        
        // Add space for each word and frequency
        var it = word_freqs.iterator();
        while (it.next()) |entry| {
            total_len += entry.key_ptr.len + 1; // word + space
            // Calculate digits in frequency
            var freq = entry.value_ptr.*;
            if (freq == 0) {
                total_len += 1; // "0"
            } else {
                while (freq > 0) {
                    total_len += 1;
                    freq /= 10;
                }
            }
            total_len += 1; // space
        }
        
        // Create buffer for batches
        var current_batch = std.ArrayList(u8).init(self.allocator);
        defer current_batch.deinit();
        
        // Start batch
        try current_batch.appendSlice("INDEX_REQUEST ");
        try current_batch.appendSlice(file_path);
        try current_batch.append(' ');
        
        var batch_word_count: usize = 0;
        var batch_size = current_batch.items.len;
        
        // Sort entries by word length to optimize batch packing
        var sorted_entries = std.ArrayList(struct { word: []const u8, freq: i64 }).init(self.allocator);
        defer sorted_entries.deinit();
        
        it = word_freqs.iterator();
        while (it.next()) |entry| {
            try sorted_entries.append(.{
                .word = entry.key_ptr.*,
                .freq = entry.value_ptr.*,
            });
        }
        
        // Sort by word length
        std.sort.sort(
            struct { word: []const u8, freq: i64 },
            sorted_entries.items,
            {},
            struct {
                fn lessThan(_: void, a: struct { word: []const u8, freq: i64 }, b: struct { word: []const u8, freq: i64 }) bool {
                    return a.word.len < b.word.len;
                }
            }.lessThan
        );
        
        // Add entries to batches
        for (sorted_entries.items) |entry| {
            // Format entry
            var word_entry = try std.fmt.allocPrint(self.allocator, "{s} {d} ", .{entry.word, entry.freq});
            defer self.allocator.free(word_entry);
            
            // Check if adding this word would exceed batch size
            if (batch_size + word_entry.len > BATCH_SIZE) {
                // Add newline at end of request
                try current_batch.append('\n');
                
                // Send current batch
                try self.sendMessage(current_batch.items);
                
                // Start new batch
                current_batch.clearRetainingCapacity();
                try current_batch.appendSlice("INDEX_REQUEST ");
                try current_batch.appendSlice(file_path);
                try current_batch.append(' ');
                
                batch_word_count = 0;
                batch_size = current_batch.items.len;
            }
            
            // Add word to batch
            try current_batch.appendSlice(word_entry);
            batch_size += word_entry.len;
            batch_word_count += 1;
        }
        
        // Send final batch if not empty
        if (batch_word_count > 0) {
            std.debug.print("Sending batch with {d} terms\n", .{batch_word_count});
            try current_batch.append('\n');
            try self.sendMessage(current_batch.items);
        }
    }
    
    fn handleSearchReply(self: *ClientProcessingEngine, reply: []const u8) ![]DocPathFreqPair {
        std.debug.print("Handling search reply\n", .{});
        
        var lines = std.mem.split(u8, reply, "\n");
        const first_line = lines.next() orelse return error.EmptyResponse;
        
        var parts = std.mem.split(u8, first_line, " ");
        const cmd = parts.next() orelse return error.InvalidReplyFormat;
        const count_str = parts.next() orelse return error.InvalidReplyFormat;
        
        if (!std.mem.eql(u8, cmd, "SEARCH_REPLY")) {
            return error.InvalidReplyFormat;
        }
        
        const num_results = try std.fmt.parseInt(usize, count_str, 10);
        
        if (num_results == 0) {
            return &[_]DocPathFreqPair{};
        }
        
        // Create results array
        var results = try std.ArrayList(DocPathFreqPair).initCapacity(self.allocator, num_results);
        errdefer {
            for (results.items) |*pair| {
                pair.deinit(self.allocator);
            }
            results.deinit();
        }
        
        // Process remaining lines
        while (lines.next()) |line| {
            if (line.len == 0) {
                continue;
            }
            
            // Find the last space in the line
            const last_space = std.mem.lastIndexOf(u8, line, " ") orelse continue;
            
            // Extract freq
            const freq_str = line[last_space + 1 ..];
            const freq = std.fmt.parseInt(i64, freq_str, 10) catch continue;
            
            // Extract path
            const path = line[0..last_space];
            
            // Create DocPathFreqPair
            var pair = try DocPathFreqPair.init(self.allocator, path, freq);
            
            try results.append(pair);
        }
        
        return results.toOwnedSlice();
    }
};

// WalkDir implementation for recursively iterating directory entries
pub const walkdir = struct {
    pub const WalkDir = struct {
        allocator: std.mem.Allocator,
        stack: std.ArrayList(std.fs.IterableDir),
        current_iter: ?std.fs.IterableDir.Iterator,
        base_path: []const u8,
        
        pub fn init(allocator: std.mem.Allocator, path: []const u8) !WalkDir {
            var dir = try std.fs.cwd().openIterableDir(path, .{});
            var stack = std.ArrayList(std.fs.IterableDir).init(allocator);
            try stack.append(dir);
            
            return WalkDir{
                .allocator = allocator,
                .stack = stack,
                .current_iter = null,
                .base_path = try allocator.dupe(u8, path),
            };
        }
        
        pub fn deinit(self: *WalkDir) void {
            for (self.stack.items) |*dir| {
                dir.close();
            }
            self.stack.deinit();
            self.allocator.free(self.base_path);
        }
        
        pub fn next(self: *WalkDir) !?struct { path: []const u8, kind: std.fs.File.Kind } {
            while (true) {
                if (self.current_iter == null) {
                    if (self.stack.items.len == 0) {
                        return null;
                    }
                    
                    var dir = self.stack.items[self.stack.items.len - 1];
                    self.current_iter = dir.iterate();
                }
                
                var entry = (self.current_iter.?).next() catch |err| {
                    std.debug.print("Error iterating directory: {}\n", .{err});
                    self.current_iter = null;
                    _ = self.stack.pop();
                    continue;
                };
                
                if (entry) |e| {
                    // Get full path
                    var path_buffer = std.ArrayList(u8).init(self.allocator);
                    defer path_buffer.deinit();
                    
                    try path_buffer.appendSlice(self.base_path);
                    try path_buffer.append('/');
                    
                    for (0..self.stack.items.len - 1) |i| {
                        const dir = self.stack.items[i + 1];
                        const dir_name = std.fs.path.basename(dir.dir.fd.name);
                        try path_buffer.appendSlice(dir_name);
                        try path_buffer.append('/');
                    }
                    
                    try path_buffer.appendSlice(e.name);
                    
                    const full_path = try self.allocator.dupe(u8, path_buffer.items);
                    errdefer self.allocator.free(full_path);
                    
                    // Handle different entry types
                    switch (e.kind) {
                        .Directory => {
                            // Open subdirectory and add to stack
                            const current_dir = self.stack.items[self.stack.items.len - 1];
                            var subdir = current_dir.dir.openIterableDir(e.name, .{}) catch |err| {
                                std.debug.print("Error opening directory {s}: {}\n", .{e.name, err});
                                self.allocator.free(full_path);
                                continue;
                            };
                            
                            try self.stack.append(subdir);
                            self.current_iter = null;
                            
                            self.allocator.free(full_path);
                            continue;
                        },
                        .File => {
                            return .{ .path = full_path, .kind = .File };
                        },
                        else => {
                            self.allocator.free(full_path);
                            continue;
                        },
                    }
                } else {
                    // End of current directory
                    self.current_iter = null;
                    _ = self.stack.pop();
                }
            }
            
            return null;
        }
    };
};
