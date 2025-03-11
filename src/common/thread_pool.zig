// src/common/thread_pool.zig
const std = @import("std");

/// Job function to be executed by worker threads
pub const Job = struct {
    function: *const fn (data: ?*anyopaque) void,
    data: ?*anyopaque,
};

/// Worker thread that processes jobs from the queue
const Worker = struct {
    id: usize,
    thread: std.Thread,
    running: bool,

    pub fn init(id: usize, pool: *ThreadPool) !Worker {
        std.debug.print("Creating worker {d}\n", .{id});
        
        const thread = try std.Thread.spawn(.{}, workerLoop, .{ id, pool });
        
        return Worker{
            .id = id,
            .thread = thread,
            .running = true,
        };
    }

    pub fn deinit(self: *Worker) void {
        std.debug.print("Joining worker {d}\n", .{self.id});
        if (self.running) {
            self.thread.join();
            self.running = false;
        }
    }
};

/// Function that each worker thread executes
fn workerLoop(id: usize, pool: *ThreadPool) void {
    std.debug.print("Worker {d} started\n", .{id});

    while (true) {
        // Lock job queue
        pool.mutex.lock();
        
        // Check if we should stop
        if (pool.should_stop) {
            pool.mutex.unlock();
            break;
        }
        
        // Wait for a job if none available
        while (pool.job_queue.items.len == 0 and !pool.should_stop) {
            std.debug.print("Worker {d} waiting for job\n", .{id});
            pool.condition.wait(&pool.mutex);
            
            // Check again after being awakened
            if (pool.should_stop) {
                pool.mutex.unlock();
                std.debug.print("Worker {d} signaled to stop\n", .{id});
                return;
            }
        }
        
        // Check if there are any jobs (possibly got woken up to shut down)
        var job_opt: ?Job = null;
        if (pool.job_queue.items.len > 0) {
            job_opt = pool.job_queue.orderedRemove(0);
        }
        
        // Unlock as soon as we have a job
        pool.mutex.unlock();
        
        // If we got a job, execute it
        if (job_opt) |job| {
            std.debug.print("Worker {d} executing job\n", .{id});
            job.function(job.data);
            std.debug.print("Worker {d} completed job\n", .{id});
        }
    }
    
    std.debug.print("Worker {d} exiting\n", .{id});
}

/// Thread pool for executing jobs concurrently
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: std.ArrayList(Worker),
    job_queue: std.ArrayList(Job),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    should_stop: bool,
    
    pub const Error = error{
        InvalidThreadCount,
        ThreadCreationFailed,
    };
    
    /// Create a new thread pool with `num_threads` workers
    pub fn init(allocator: std.mem.Allocator, num_threads: usize) !*ThreadPool {
        std.debug.print("Initializing ThreadPool with {d} threads\n", .{num_threads});
        
        if (num_threads == 0) {
            return Error.InvalidThreadCount;
        }
        
        // Allocate the pool
        var pool = try allocator.create(ThreadPool);
        errdefer allocator.destroy(pool);
        
        // Initialize members
        pool.* = .{
            .allocator = allocator,
            .workers = std.ArrayList(Worker).init(allocator),
            .job_queue = std.ArrayList(Job).init(allocator),
            .mutex = std.Thread.Mutex{},
            .condition = std.Thread.Condition{},
            .should_stop = false,
        };
        
        // Create workers
        try pool.workers.ensureTotalCapacity(num_threads);
        
        for (0..num_threads) |i| {
            const worker = Worker.init(i, pool) catch |err| {
                std.debug.print("Failed to create worker {d}: {}\n", .{i, err});
                return Error.ThreadCreationFailed;
            };
            try pool.workers.append(worker);
        }
        
        return pool;
    }
    
    /// Clean up resources and signal all workers to stop
    pub fn deinit(self: *ThreadPool) void {
        std.debug.print("Shutting down ThreadPool\n", .{});
        
        // Signal all workers to stop
        {
            self.mutex.lock();
            self.should_stop = true;
            self.condition.broadcast();
            self.mutex.unlock();
        }
        
        // Wait for all workers to finish
        for (self.workers.items) |*worker| {
            worker.deinit();
        }
        
        // Clean up resources
        self.workers.deinit();
        self.job_queue.deinit();
        self.allocator.destroy(self);
        
        std.debug.print("ThreadPool shut down\n", .{});
    }
    
    /// Execute a function in a worker thread
    pub fn execute(self: *ThreadPool, comptime F: type, func: F, context: anytype) !void {
        const Context = @TypeOf(context);
        
        // Create job that captures the function and context
        const JobContext = struct {
            func: F,
            context: Context,
            
            fn wrapper(data: ?*anyopaque) void {
                const job_context = @ptrCast(*@This(), @alignCast(@alignOf(*@This()), data.?));
                job_context.func(job_context.context);
                // Free the job context
                std.heap.c_allocator.destroy(job_context);
            }
        };
        
        // Allocate a job context on the heap
        var job_context = try std.heap.c_allocator.create(JobContext);
        job_context.* = .{
            .func = func,
            .context = context,
        };
        
        // Add job to queue
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.job_queue.append(Job{
            .function = JobContext.wrapper,
            .data = job_context,
        });
        
        // Signal a worker that a job is available
        self.condition.signal();
        
        std.debug.print("Submitted job to ThreadPool, queue size: {d}\n", .{self.job_queue.items.len});
    }
    
    /// Execute a function and return a promise for its result
    pub fn executeWithPromise(self: *ThreadPool, comptime ResultT: type, comptime F: type, func: F, context: anytype) !*Promise(ResultT) {
        const Context = @TypeOf(context);
        
        // Create a promise for the result
        var promise = try Promise(ResultT).init(self.allocator);
        
        // Create job context that captures function, context, and promise
        const JobContext = struct {
            func: F,
            context: Context,
            promise: *Promise(ResultT),
            
            fn wrapper(data: ?*anyopaque) void {
                const job_context = @ptrCast(*@This(), @alignCast(@alignOf(*@This()), data.?));
                const result = job_context.func(job_context.context);
                job_context.promise.fulfill(result);
                // Free the job context
                std.heap.c_allocator.destroy(job_context);
            }
        };
        
        // Allocate a job context on the heap
        var job_context = try std.heap.c_allocator.create(JobContext);
        job_context.* = .{
            .func = func,
            .context = context,
            .promise = promise,
        };
        
        // Add job to queue
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.job_queue.append(Job{
            .function = JobContext.wrapper,
            .data = job_context,
        });
        
        // Signal a worker that a job is available
        self.condition.signal();
        
        std.debug.print("Submitted job with promise to ThreadPool\n", .{});
        
        return promise;
    }
};

/// A promise for a value that will be available in the future
pub fn Promise(comptime T: type) type {
    return struct {
        const Self = @This();
        
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        value: ?T,
        is_fulfilled: bool,
        
        pub fn init(allocator: std.mem.Allocator) !*Self {
            var self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .mutex = std.Thread.Mutex{},
                .condition = std.Thread.Condition{},
                .value = null,
                .is_fulfilled = false,
            };
            return self;
        }
        
        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }
        
        pub fn fulfill(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            self.value = value;
            self.is_fulfilled = true;
            self.condition.broadcast();
        }
        
        pub fn await(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            while (!self.is_fulfilled) {
                self.condition.wait(&self.mutex);
            }
            
            return self.value.?;
        }
        
        pub fn tryGet(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            return if (self.is_fulfilled) self.value else null;
        }
    };
}

// Test ThreadPool functionality
test "thread pool basics" {
    const allocator = std.testing.allocator;
    const pool = try ThreadPool.init(allocator, 4);
    defer pool.deinit();
    
    const TestContext = struct {
        counter: *std.atomic.Value(usize),
        
        fn increment(ctx: @This()) void {
            _ = ctx.counter.fetchAdd(1, .SeqCst);
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    };
    
    var counter = std.atomic.Value(usize).init(0);
    const context = TestContext{ .counter = &counter };
    
    // Submit 10 jobs
    for (0..10) |_| {
        try pool.execute(
            @TypeOf(TestContext.increment), 
            TestContext.increment, 
            context
        );
    }
    
    // Sleep to give time for jobs to complete
    std.time.sleep(100 * std.time.ns_per_ms);
    
    try std.testing.expectEqual(@as(usize, 10), counter.load(.SeqCst));
}

test "thread pool with promise" {
    const allocator = std.testing.allocator;
    const pool = try ThreadPool.init(allocator, 4);
    defer pool.deinit();
    
    const TestContext = struct {
        value: usize,
        
        fn compute(ctx: @This()) usize {
            std.time.sleep(10 * std.time.ns_per_ms);
            return ctx.value * 2;
        }
    };
    
    var promises = std.ArrayList(*Promise(usize)).init(allocator);
    defer {
        for (promises.items) |promise| {
            promise.deinit();
        }
        promises.deinit();
    }
    
    // Submit 5 jobs with promises
    for (0..5) |i| {
        const context = TestContext{ .value = i };
        const promise = try pool.executeWithPromise(
            usize,
            @TypeOf(TestContext.compute),
            TestContext.compute,
            context
        );
        try promises.append(promise);
    }
    
    // Wait for promises and check results
    for (0..5) |i| {
        const result = promises.items[i].await();
        try std.testing.expectEqual(i * 2, result);
    }
}
