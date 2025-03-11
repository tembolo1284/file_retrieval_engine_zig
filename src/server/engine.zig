// src/server/engine.zig
const std = @import("std");
const IndexStore = @import("index_store/index_store.zig").IndexStore;
const ThreadPool = @import("../common/thread_pool.zig").ThreadPool;
const BatchProcessor = @import("batch_processor.zig").BatchIndexProcessor;

/// Information about a connected client
pub const ClientInfo = struct {
    client_id: i32,
    ip_address: []const u8,
    port: i32,

    pub fn init(allocator: std.mem.Allocator, id: i32, ip: []const u8, port: i32) !ClientInfo {
        return ClientInfo{
            .client_id = id,
            .ip_address = try allocator.dupe(u8, ip),
            .port = port,
        };
    }

    pub fn deinit(self: *ClientInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.ip_address);
    }
};

/// Batch of indexed terms for a document
const IndexBatch = struct {
    document_number: i64,
    word_frequencies: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator, doc_num: i64) !IndexBatch {
        return IndexBatch{
            .document_number = doc_num,
            .word_frequencies = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *IndexBatch) void {
        var it = self.word_frequencies.iterator();
        while (it.next()) |entry| {
            self.word_frequencies.allocator.free(entry.key_ptr.*);
        }
        self.word_frequencies.deinit();
    }
};

/// The main server engine that handles client connections and requests
pub const ServerProcessingEngine = struct {
    allocator: std.mem.Allocator,
    store: *IndexStore,
    worker_pool: *ThreadPool,
    connected_clients: std.StringHashMap(ClientInfo),
    clients_mutex: std.Thread.Mutex,
    next_client_id: std.atomic.Value(i32),
    should_stop: std.atomic.Value(bool),
    batch_channel: std.Channel(IndexBatch),
    server_socket: ?std.net.Server,
    listener_thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, store: *IndexStore, num_threads: usize) !*ServerProcessingEngine {
        std.debug.print("Initializing ServerProcessingEngine with {d} threads\n", .{num_threads});
        
        // Create worker pool
        var worker_pool = try ThreadPool.init(allocator, num_threads);
        errdefer worker_pool.deinit();
        
        // Create server engine
        var self = try allocator.create(ServerProcessingEngine);
        errdefer allocator.destroy(self);
        
        // Initialize fields
        self.* = .{
            .allocator = allocator,
            .store = store,
            .worker_pool = worker_pool,
            .connected_clients = std.StringHashMap(ClientInfo).init(allocator),
            .clients_mutex = std.Thread.Mutex{},
            .next_client_id = std.atomic.Value(i32).init(1),
            .should_stop = std.atomic.Value(bool).init(false),
            .batch_channel = std.Channel(IndexBatch).init(),
            .server_socket = null,
            .listener_thread = null,
        };
        
        // Start batch processor
        try self.startBatchProcessor();
        
        return self;
    }
    
    pub fn deinit(self: *ServerProcessingEngine) void {
        std.debug.print("Shutting down ServerProcessingEngine\n", .{});
        
        // Signal shutdown
        self.should_stop.store(true, .SeqCst);
        
        // Close server socket to stop accepting connections
        if (self.server_socket) |*server| {
            server.close();
            self.server_socket = null;
        }
        
        // Wait for listener thread
        if (self.listener_thread) |thread| {
            thread.join();
            self.listener_thread = null;
        }
        
        // Close batch channel
        self.batch_channel.close();
        
        // Clean up worker pool
        self.worker_pool.deinit();
        
        // Clean up connected clients
        {
            self.clients_mutex.lock();
            defer self.clients_mutex.unlock();
            
            var it = self.connected_clients.iterator();
            while (it.next()) |entry| {
                var client_info = entry.value_ptr;
                client_info.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
            }
            self.connected_clients.deinit();
        }
        
        // Destroy self
        self.allocator.destroy(self);
    }
    
    pub fn initialize(self: *ServerProcessingEngine, server_port: u16) !void {
        std.debug.print("Initializing server on port {d}\n", .{server_port});
        
        // Create TCP listener
        var server = try std.net.Server.init(.{
            .address = std.net.Address.initIp4(.{0,0,0,0}, server_port),
            .reuse_address = true,
        });
        errdefer server.deinit();
        
        self.server_socket = server;
        
        // Start listener thread
        self.listener_thread = try std.Thread.spawn(.{}, listenerThread, .{self});
        
        std.debug.print("Server initialized on port {d}\n", .{server_port});
    }
    
    fn listenerThread(self: *ServerProcessingEngine) void {
        std.debug.print("Listener thread started\n", .{});
        
        while (!self.should_stop.load(.SeqCst)) {
            if (self.server_socket) |*server| {
                // Accept client connection (with timeout)
                var accept_result = server.accept(.{ .timeout_ms = 1000 }) catch |err| {
                    if (err == error.WouldBlock or err == error.ConnectionAborted or err == error.Timeout) {
                        // Non-fatal errors, just continue
                        continue;
                    }
                    
                    std.debug.print("Error accepting connection: {}\n", .{err});
                    if (!self.should_stop.load(.SeqCst)) {
                        // Log error but continue if not stopping
                        continue;
                    } else {
                        // Break loop if we're stopping
                        break;
                    }
                };
                
                // Handle new client
                var stream = accept_result.stream;
                var address = accept_result.address;
                
                std.debug.print("New connection from {}\n", .{address});
                
                // Create client info
                const client_id = self.next_client_id.fetchAdd(1, .SeqCst);
                
                var ip_buffer: [64]u8 = undefined;
                const ip_str = address.format(&ip_buffer, false) catch "unknown";
                
                var client_info = ClientInfo.init(self.allocator, client_id, ip_str, @intCast(i32, address.getPort())) catch |err| {
                    std.debug.print("Failed to create client info: {}\n", .{err});
                    stream.close();
                    continue;
                };
                
                // Generate unique key for client
                var key_buffer = std.ArrayList(u8).init(self.allocator);
                defer key_buffer.deinit();
                
                std.fmt.format(key_buffer.writer(), "client_{d}", .{client_id}) catch |err| {
                    std.debug.print("Failed to format client key: {}\n", .{err});
                    client_info.deinit(self.allocator);
                    stream.close();
                    continue;
                };
                
                var key = key_buffer.toOwnedSlice() catch |err| {
                    std.debug.print("Failed to create client key: {}\n", .{err});
                    client_info.deinit(self.allocator);
                    stream.close();
                    continue;
                };
                
                // Add client to connected clients
                {
                    self.clients_mutex.lock();
                    defer self.clients_mutex.unlock();
                    
                    self.connected_clients.put(key, client_info) catch |err| {
                        std.debug.print("Failed to add client to map: {}\n", .{err});
                        self.allocator.free(key);
                        client_info.deinit(self.allocator);
                        stream.close();
                        continue;
                    };
                }
                
                // Create client handler context
                const HandlerContext = struct {
                    engine: *ServerProcessingEngine,
                    stream: std.net.Stream,
                    client_id: i32,
                    client_key: []const u8,
                };
                
                var context = HandlerContext{
                    .engine = self,
                    .stream = stream,
                    .client_id = client_id,
                    .client_key = key,
                };
                
                // Submit client handler to worker pool
                self.worker_pool.execute(
                    @TypeOf(handleClientConnection),
                    handleClientConnection,
                    context
                ) catch |err| {
                    std.debug.print("Failed to submit client handler to worker pool: {}\n", .{err});
                    
                    // Remove client from map
                    {
                        self.clients_mutex.lock();
                        defer self.clients_mutex.unlock();
                        
                        if (self.connected_clients.fetchRemove(key)) |entry| {
                            entry.value.deinit(self.allocator);
                        }
                    }
                    
                    self.allocator.free(key);
                    stream.close();
                };
            } else {
                // No server socket, exit thread
                break;
            }
        }
        
        std.debug.print("Listener thread exiting\n", .{});
    }
    
    fn handleClientConnection(ctx: anytype) void {
        const engine = ctx.engine;
        var stream = ctx.stream;
        const client_id = ctx.client_id;
        const client_key = ctx.client_key;
        
        defer {
            std.debug.print("Client {d} disconnected\n", .{client_id});
            
            // Remove client from map
            {
                engine.clients_mutex.lock();
                defer engine.clients_mutex.unlock();
                
                if (engine.connected_clients.fetchRemove(client_key)) |entry| {
                    entry.value.deinit(engine.allocator);
                }
            }
            
            // Free client key
            engine.allocator.free(client_key);
            
            // Close stream
            stream.close();
        }
        
        std.debug.print("Handling client {d}\n", .{client_id});
        
        var buffer = std.ArrayList(u8).init(engine.allocator);
        defer buffer.deinit();
        
        while (!engine.should_stop.load(.SeqCst)) {
            // Clear buffer for next message
            buffer.clearRetainingCapacity();
            
            // Read message
            var reader = stream.reader();
            
            // Read line (assume each message ends with newline)
            reader.readUntilDelimiterArrayList(&buffer, '\n', 1024 * 1024) catch |err| {
                if (err == error.EndOfStream) {
                    // Client disconnected
                    break;
                }
                
                std.debug.print("Error reading from client {d}: {}\n", .{client_id, err});
                break;
            };
            
            const message = buffer.items;
            if (message.len == 0) {
                continue;
            }
            
            std.debug.print("Received from client {d}: '{s}'\n", .{client_id, message});
            
            // Process message
            var response = engine.processMessage(message, client_id) catch |err| {
                std.debug.print("Error processing message: {}\n", .{err});
                continue;
            };
            defer engine.allocator.free(response);
            
            // Send response
            var writer = stream.writer();
            writer.writeAll(response) catch |err| {
                std.debug.print("Error writing to client {d}: {}\n", .{client_id, err});
                break;
            };
            
            // Flush
            stream.flush() catch |err| {
                std.debug.print("Error flushing stream for client {d}: {}\n", .{client_id, err});
                break;
            };
        }
    }
    
    fn processMessage(self: *ServerProcessingEngine, message: []const u8, client_id: i32) ![]const u8 {
        // Split the message into parts
        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        
        var it = std.mem.split(u8, message, " ");
        while (it.next()) |part| {
            try parts.append(part);
        }
        
        if (parts.items.len == 0) {
            return self.allocator.dupe(u8, "ERROR Empty request\n");
        }
        
        const command = parts.items[0];
        
        if (std.mem.eql(u8, command, "REGISTER_REQUEST")) {
            // Handle registration
            var response = try std.fmt.allocPrint(self.allocator, "REGISTER_REPLY {d}\n", .{client_id});
            std.debug.print("Client {d} registered\n", .{client_id});
            return response;
        } else if (std.mem.eql(u8, command, "INDEX_REQUEST")) {
            // Handle index request
            if (parts.items.len < 2) {
                return self.allocator.dupe(u8, "ERROR Invalid index request format\n");
            }
            
            const doc_path = parts.items[1];
            var word_frequencies = std.StringHashMap(i64).init(self.allocator);
            defer {
                var freq_it = word_frequencies.iterator();
                while (freq_it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                }
                word_frequencies.deinit();
            }
            
            // Parse word-frequency pairs
            var i: usize = 2;
            while (i + 1 < parts.items.len) {
                const word = parts.items[i];
                const freq_str = parts.items[i + 1];
                
                const freq = std.fmt.parseInt(i64, freq_str, 10) catch {
                    i += 1;
                    continue;
                };
                
                var word_copy = try self.allocator.dupe(u8, word);
                errdefer self.allocator.free(word_copy);
                
                try word_frequencies.put(word_copy, freq);
                
                i += 2;
            }
            
            // Process document
            const doc_num = self.store.putDocument(doc_path);
            self.store.updateIndex(doc_num, word_frequencies);
            
            return self.allocator.dupe(u8, "INDEX_REPLY SUCCESS\n");
        } else if (std.mem.eql(u8, command, "SEARCH_REQUEST")) {
            // Handle search request
            if (parts.items.len < 2) {
                return self.allocator.dupe(u8, "ERROR Empty search terms\n");
            }
            
            // Extract search terms
            var search_terms = std.ArrayList([]const u8).init(self.allocator);
            defer search_terms.deinit();
            
            for (parts.items[1..]) |term| {
                try search_terms.append(term);
            }
            
            // Search
            var results = self.store.search(search_terms.items);
            defer {
                for (results) |result| {
                    self.allocator.free(result.path);
                }
                self.allocator.free(results);
            }
            
            // Format response
            var response = std.ArrayList(u8).init(self.allocator);
            defer response.deinit();
            
            try std.fmt.format(response.writer(), "SEARCH_REPLY {d}\n", .{results.len});
            
            for (results) |result| {
                // Extract client ID if possible
                var client_prefix = "Client s:";
                
                if (std.mem.indexOf(u8, result.path, "/client_")) |client_pos| {
                    const client_id_start = client_pos + 8; // Skip "/client_"
                    
                    if (client_id_start < result.path.len) {
                        var end_pos = client_id_start;
                        while (end_pos < result.path.len and std.ascii.isDigit(result.path[end_pos])) {
                            end_pos += 1;
                        }
                        
                        if (end_pos > client_id_start) {
                            const extracted_id = result.path[client_id_start..end_pos];
                            try std.fmt.format(response.writer(), "Client {s}:{s} {d}\n", .{
                                extracted_id, result.path, result.freq
                            });
                            continue;
                        }
                    }
                }
                
                // Fallback to generic format
                try std.fmt.format(response.writer(), "{s}{s} {d}\n", .{
                    client_prefix, result.path, result.freq
                });
            }
            
            return response.toOwnedSlice();
        } else if (std.mem.eql(u8, command, "GET_DOC_PATH")) {
            // Handle document path request
            if (parts.items.len != 2) {
                return self.allocator.dupe(u8, "ERROR Invalid document ID request\n");
            }
            
            const doc_id = std.fmt.parseInt(i64, parts.items[1], 10) catch {
                return self.allocator.dupe(u8, "ERROR Invalid document ID\n");
            };
            
            if (self.store.getDocument(doc_id)) |path| {
                var response = try std.fmt.allocPrint(self.allocator, "DOC_PATH {s}\n", .{path});
                return response;
            } else {
                return self.allocator.dupe(u8, "ERROR Document not found\n");
            }
        } else {
            return self.allocator.dupe(u8, "ERROR Invalid request\n");
        }
    }
    
    fn startBatchProcessor(self: *ServerProcessingEngine) !void {
        // Start a thread to process batches
        _ = try std.Thread.spawn(.{}, batchProcessorThread, .{self});
    }
    
    fn batchProcessorThread(self: *ServerProcessingEngine) void {
        std.debug.print("Batch processor thread started\n", .{});
        
        // Process batches until stopped
        while (!self.should_stop.load(.SeqCst)) {
            // Receive batch with timeout
            const received = self.batch_channel.receive(1_000_000_000) catch {
                // Timeout or error, check if stopping
                continue;
            };
            
            // Process batch
            var updates = std.ArrayList(struct { doc_num: i64, freqs: std.StringHashMap(i64) }).init(self.allocator);
            
            // Add received batch to updates
            updates.append(.{
                .doc_num = received.document_number,
                .freqs = received.word_frequencies,
            }) catch |err| {
                std.debug.print("Failed to append batch: {}\n", .{err});
                received.deinit();
                continue;
            };
            
            // Check for more batches in the queue (batch processing)
            var batch_count: usize = 1;
            const MAX_BATCH_SIZE = 100;
            
            while (batch_count < MAX_BATCH_SIZE and 
                   !self.should_stop.load(.SeqCst)) {
                const next = self.batch_channel.receive(0) catch {
                    // No more batches available
                    break;
                };
                
                updates.append(.{
                    .doc_num = next.document_number,
                    .freqs = next.word_frequencies,
                }) catch |err| {
                    std.debug.print("Failed to append batch: {}\n", .{err});
                    next.deinit();
                    continue;
                };
                
                batch_count += 1;
            }
            
            // Process all batches
            if (updates.items.len > 0) {
                self.store.batchUpdateIndex(updates.items);
                
                // Clean up
                for (updates.items) |*update| {
                    var it = update.freqs.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                    }
                    update.freqs.deinit();
                }
            }
            
            updates.deinit();
        }
        
        std.debug.print("Batch processor thread exiting\n", .{});
    }
    
    pub fn getConnectedClients(self: *ServerProcessingEngine) [][]const u8 {
        var clients = std.ArrayList([]const u8).init(self.allocator);
        
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        
        var it = self.connected_clients.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr;
            
            var client_info = std.fmt.allocPrint(
                self.allocator,
                "Client ID: {d}, IP: {s}, Port: {d}",
                .{info.client_id, info.ip_address, info.port}
            ) catch continue;
            
            clients.append(client_info) catch {
                self.allocator.free(client_info);
                continue;
            };
        }
        
        return clients.toOwnedSlice() catch &[_][]const u8{};
    }
    
    pub fn shutdown(self: *ServerProcessingEngine) void {
        self.should_stop.store(true, .SeqCst);
        
        // Close server socket to stop accepting connections
        if (self.server_socket) |*server| {
            server.close();
        }
        
        // Notify any waiting threads
        self.batch_channel.close();
    }
};

// Channel implementation for batch processing
pub fn Channel(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        queue: std.ArrayList(T),
        closed: bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .mutex = std.Thread.Mutex{},
                .condition = std.Thread.Condition{},
                .queue = std.ArrayList(T).init(allocator),
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            self.queue.deinit();
            self.closed = true;
        }

        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            if (self.closed) {
                return error.ChannelClosed;
            }
            
            try self.queue.append(item);
            self.condition.signal();
        }

        pub fn receive(self: *Self, timeout_ns: u64) !T {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            if (self.closed and self.queue.items.len == 0) {
                return error.ChannelClosed;
            }
            
            const start = std.time.nanoTimestamp();
            
            while (self.queue.items.len == 0) {
                if (self.closed) {
                    return error.ChannelClosed;
                }
                
                if (timeout_ns > 0) {
                    const now = std.time.nanoTimestamp();
                    const elapsed = @intCast(u64, now - start);
                    
                    if (elapsed >= timeout_ns) {
                        return error.Timeout;
                    }
                    
                    const remaining = timeout_ns - elapsed;
                    
                    // Wait with timeout
                    if (!self.condition.timedWait(&self.mutex, remaining)) {
                        // Timeout
                        return error.Timeout;
                    }
                } else {
                    // Wait indefinitely
                    self.condition.wait(&self.mutex);
                }
                
                if (self.closed and self.queue.items.len == 0) {
                    return error.ChannelClosed;
                }
            }
            
            return self.queue.orderedRemove(0);
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            self.closed = true;
            self.condition.broadcast();
        }
    };
}
