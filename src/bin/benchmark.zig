// src/bin/benchmark.zig
const std = @import("std");
const client = @import("client");
const ClientEngine = client.ClientProcessingEngine;
const IndexResult = iclient.IndexResult;

/// Results of a benchmark run
const BenchmarkResults = struct {
    total_time: f64,
    total_bytes_processed: i64,
    client_results: []IndexResult,
    
    pub fn deinit(self: *BenchmarkResults, allocator: std.mem.Allocator) void {
        allocator.free(self.client_results);
    }
};

/// Context for running a worker
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    client_id: i32,
    engine: *ClientEngine,
    server_ip: []const u8,
    server_port: []const u8,
    dataset_path: []const u8,
    
    pub fn runWorker(ctx: @This()) !IndexResult {
        std.debug.print("Worker {d} starting\n", .{ctx.client_id});
        
        // Connect to server
        try ctx.engine.connect(ctx.server_ip, ctx.server_port);
        std.debug.print("Client {d} connected to server\n", .{ctx.client_id});
        
        // Index the dataset
        const result = try ctx.engine.indexFolder(ctx.dataset_path);
        
        std.debug.print("Client {d} finished indexing.\n", .{ctx.client_id});
        std.debug.print("Bytes processed: {d}\n", .{result.total_bytes_read});
        std.debug.print("Time: {d:.2}s\n", .{result.execution_time});
        
        return result;
    }
};

pub fn main() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Parse command line arguments
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 5) {
        std.debug.print("Usage: {s} <server_ip> <server_port> <num_clients> <dataset_path1> [dataset_path2 ...]\n", .{args[0]});
        return error.InvalidArguments;
    }
    
    const server_ip = args[1];
    const server_port = args[2];
    
    const num_clients = std.fmt.parseInt(usize, args[3], 10) catch {
        std.debug.print("Invalid number of clients\n", .{});
        return error.InvalidArguments;
    };
    
    if (num_clients <= 0) {
        std.debug.print("Number of clients must be positive\n", .{});
        return error.InvalidArguments;
    }
    
    if (args.len < 4 + num_clients) {
        std.debug.print("Not enough dataset paths provided\n", .{});
        return error.InvalidArguments;
    }
    
    // Collect dataset paths
    var dataset_paths = std.ArrayList([]const u8).init(allocator);
    defer dataset_paths.deinit();
    
    for (0..num_clients) |i| {
        try dataset_paths.append(args[i + 4]);
    }
    
    const start_time = std.time.nanoTimestamp();
    
    var benchmark_results = BenchmarkResults{
        .total_time = 0.0,
        .total_bytes_processed = 0,
        .client_results = try allocator.alloc(IndexResult, num_clients),
    };
    defer benchmark_results.deinit(allocator);
    
    // Create engines for each client
    var engines = std.ArrayList(*ClientEngine).init(allocator);
    defer {
        for (engines.items) |engine| {
            engine.deinit();
        }
        engines.deinit();
    }
    
    // Create and initialize worker engines
    for (0..num_clients) |_| {
        const engine = try ClientEngine.init(allocator);
        try engines.append(engine);
    }
    
    // Create a promise array for results
    const Promise = struct {
        result: ?IndexResult = null,
        error: ?anyerror = null,
        done: bool = false,
        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},
        
        pub fn fulfill(self: *@This(), result: IndexResult) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            self.result = result;
            self.done = true;
            self.condition.signal();
        }
        
        pub fn fail(self: *@This(), err: anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            self.error = err;
            self.done = true;
            self.condition.signal();
        }
        
        pub fn await(self: *@This()) !IndexResult {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            while (!self.done) {
                self.condition.wait(&self.mutex);
            }
            
            if (self.error) |err| {
                return err;
            }
            
            return self.result.?;
        }
    };
    
    var promises = try allocator.alloc(Promise, num_clients);
    defer allocator.free(promises);
    for (promises) |*promise| {
        promise.* = .{};
    }
    
    // Create and start benchmark workers
    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();
    
    for (0..num_clients) |i| {
        const worker_context = WorkerContext{
            .allocator = allocator,
            .client_id = @intCast(i32, i + 1),
            .engine = engines.items[i],
            .server_ip = server_ip,
            .server_port = server_port,
            .dataset_path = dataset_paths.items[i],
        };
        
        const promise_index = i;
        
        // Create worker thread
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(ctx: WorkerContext, promise: *Promise) void {
                ctx.runWorker() catch |err| {
                    std.debug.print("Worker {d} error: {}\n", .{ctx.client_id, err});
                    promise.fail(err);
                    return;
                } |result| {
                    promise.fulfill(result);
                };
            }
        }.run, .{ worker_context, &promises[promise_index] });
        
        try threads.append(thread);
    }
    
    // Wait for all workers to complete
    for (0..num_clients) |i| {
        const result = promises[i].await() catch |err| {
            std.debug.print("Worker {d} failed: {}\n", .{i + 1, err});
            continue;
        };
        
        benchmark_results.total_bytes_processed += result.total_bytes_read;
        benchmark_results.client_results[i] = result;
    }
    
    // Join all threads
    for (threads.items) |thread| {
        thread.join();
    }
    
    const end_time = std.time.nanoTimestamp();
    const duration_ns = @intCast(u64, end_time - start_time);
    const duration_sec = @intToFloat(f64, duration_ns) / @intToFloat(f64, std.time.ns_per_s);
    benchmark_results.total_time = duration_sec;
    
    // Print benchmark results
    std.debug.print("\n----------------------------------------\n", .{});
    std.debug.print("Benchmark Results:\n", .{});
    std.debug.print("Number of clients: {d}\n", .{num_clients});
    std.debug.print("Total execution time: {d:.2} seconds\n", .{benchmark_results.total_time});
    std.debug.print("Total data processed: {d} bytes\n", .{benchmark_results.total_bytes_processed});
    
    const throughput = @intToFloat(f64, benchmark_results.total_bytes_processed) / (1024.0 * 1024.0) 
        / benchmark_results.total_time;
    std.debug.print("Overall throughput: {d:.2} MB/s\n", .{throughput});
    
    // Per-client statistics
    std.debug.print("\nPer-client Statistics:\n", .{});
    for (benchmark_results.client_results, 0..) |result, i| {
        const client_throughput = @intToFloat(f64, result.total_bytes_read) / (1024.0 * 1024.0) 
            / result.execution_time;
        std.debug.print("Client {d}:\n", .{i + 1});
        std.debug.print("  Time: {d:.2}s\n", .{result.execution_time});
        std.debug.print("  Data: {d} bytes\n", .{result.total_bytes_read});
        std.debug.print("  Throughput: {d:.2} MB/s\n", .{client_throughput});
    }
    std.debug.print("----------------------------------------\n", .{});
    
    // Run search queries on the first client
    if (engines.items.len > 0) {
        std.debug.print("\nRunning benchmark searches on first client...\n", .{});
        
        const test_queries = [_][]const []const u8{
            &[_][]const u8{"test"},
            &[_][]const u8{"test", "example"},
            &[_][]const u8{"performance", "benchmark", "test"},
        };
        
        for (test_queries) |query| {
            var query_str = std.ArrayList(u8).init(allocator);
            defer query_str.deinit();
            
            for (query, 0..) |term, j| {
                if (j > 0) {
                    try query_str.appendSlice(" AND ");
                }
                try query_str.appendSlice(term);
            }
            
            std.debug.print("\nExecuting query: {s}\n", .{query_str.items});
            
            const search_result = engines.items[0].search(query) catch |err| {
                std.debug.print("Search failed: {}\n", .{err});
                continue;
            };
            defer {
                var result = search_result;
                result.deinit(allocator);
            };
            
            std.debug.print("Search completed in {d:.3} seconds\n", .{search_result.execution_time});
            std.debug.print("Found {d} results\n", .{search_result.document_frequencies.len});
            
            std.debug.print("Search results:\n", .{});
            for (search_result.document_frequencies, 0..) |doc, i| {
                // Extract client number from the path
                var formatted_path = doc.document_path;
                
                if (std.mem.startsWith(u8, doc.document_path, "Client s:")) {
                    const content = doc.document_path[9..]; // Skip "Client s:"
                    
                    if (std.mem.indexOf(u8, content, "/client_")) |client_pos| {
                        const client_id_start = client_pos + 8; // Skip "/client_"
                        
                        if (client_id_start < content.len) {
                            var client_id = std.ArrayList(u8).init(allocator);
                            defer client_id.deinit();
                            
                            var j: usize = client_id_start;
                            while (j < content.len and std.ascii.isDigit(content[j])) {
                                try client_id.append(content[j]);
                                j += 1;
                            }
                            
                            if (client_id.items.len > 0) {
                                var formatted = try std.fmt.allocPrint(allocator, 
                                    "Client {s}:{s}", .{client_id.items, content});
                                defer allocator.free(formatted);
                                
                                std.debug.print("  {d}. {s} (score: {d})\n", 
                                    .{i+1, formatted, doc.word_frequency});
                                continue;
                            }
                        }
                    }
                }
                
                std.debug.print("  {d}. {s} (score: {d})\n", 
                    .{i+1, formatted_path, doc.word_frequency});
            }
            std.debug.print("\n", .{});
        }
    }
    
    // Disconnect all clients
    for (engines.items) |engine| {
        engine.disconnect() catch |err| {
            std.debug.print("Error disconnecting client: {}\n", .{err});
        };
    }
}
