// src/server/batch_processor.zig
const std = @import("std");
const IndexStore = @import("index_store/index_store.zig").IndexStore;

pub const NUM_SHARDS = 256;
pub const MIN_WORD_LENGTH = 3;

pub const BatchIndexProcessor = struct {
    allocator: std.mem.Allocator,
    store: *IndexStore,
    batch_size: usize,
    current_batches: []std.StringHashMap(i64),
    document_number: i64,
    word_buffer: std.ArrayList(u8),
    freq_map: std.StringHashMap(i64),
    
    pub fn init(allocator: std.mem.Allocator, store: *IndexStore) !*BatchIndexProcessor {
        std.debug.print("Initializing BatchIndexProcessor\n", .{});
        
        // Allocate the processor
        var self = try allocator.create(BatchIndexProcessor);
        errdefer allocator.destroy(self);
        
        // Create sharded batches
        var current_batches = try allocator.alloc(std.StringHashMap(i64), NUM_SHARDS);
        errdefer allocator.free(current_batches);
        
        // Initialize each shard with capacity
        for (0..NUM_SHARDS) |i| {
            current_batches[i] = std.StringHashMap(i64).init(allocator);
            // Pre-allocate some capacity
            try current_batches[i].ensureTotalCapacity(1000);
        }
        
        // Initialize the processor
        self.* = .{
            .allocator = allocator,
            .store = store,
            .batch_size = 10000,
            .current_batches = current_batches,
            .document_number = 0,
            .word_buffer = std.ArrayList(u8).initCapacity(allocator, 64) catch |err| {
                std.debug.print("Failed to create word buffer: {}\n", .{err});
                return err;
            },
            .freq_map = std.StringHashMap(i64).init(allocator),
        };
        
        // Pre-allocate some capacity for the frequency map
        try self.freq_map.ensureTotalCapacity(1000);
        
        return self;
    }
    
    pub fn deinit(self: *BatchIndexProcessor) void {
        std.debug.print("Deinitializing BatchIndexProcessor\n", .{});
        
        // Free all batches
        for (0..NUM_SHARDS) |i| {
            var it = self.current_batches[i].iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.current_batches[i].deinit();
        }
        
        self.allocator.free(self.current_batches);
        
        // Free the frequency map
        var it = self.freq_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.freq_map.deinit();
        
        // Free the word buffer
        self.word_buffer.deinit();
        
        // Free the processor itself
        self.allocator.destroy(self);
    }
    
    pub fn processDocument(self: *BatchIndexProcessor, content: []const u8, path: []const u8) !i64 {
        std.debug.print("Processing document: {s}\n", .{path});
        
        // Register document with the store
        const doc_num = self.store.putDocument(path);
        self.document_number = doc_num;
        
        // Clear previous data
        self.word_buffer.clearRetainingCapacity();
        
        // Clear the frequency map but keep its capacity
        var it = self.freq_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.freq_map.clearRetainingCapacity();
        
        var in_word = false;
        
        // Process content character by character
        for (content) |c| {
            if (isWordChar(c)) {
                try self.word_buffer.append(c);
                in_word = true;
            } else if (in_word) {
                try self.processWord();
                in_word = false;
            }
        }
        
        // Process last word if any
        if (in_word) {
            try self.processWord();
        }
        
        // Update batches with word frequencies
        var word_it = self.freq_map.iterator();
        while (word_it.next()) |entry| {
            const word = entry.key_ptr.*;
            const freq = entry.value_ptr.*;
            
            const shard = self.getShardIndex(word);
            
            // Need to duplicate the word for storage in the batch
            const word_copy = try self.allocator.dupe(u8, word);
            errdefer self.allocator.free(word_copy);
            
            // Store in batch
            try self.current_batches[shard].put(word_copy, freq);
            
            // Flush if batch is full
            if (self.current_batches[shard].count() >= self.batch_size) {
                try self.flushShard(shard);
            }
        }
        
        return doc_num;
    }
    
    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }
    
    fn processWord(self: *BatchIndexProcessor) !void {
        // Skip short words
        if (self.word_buffer.items.len < MIN_WORD_LENGTH) {
            return;
        }
        
        // Get current word
        const word = self.word_buffer.items;
        
        std.debug.print("  Found word: {s}\n", .{word});
        
        // Update frequency
        const gop = try self.freq_map.getOrPut(word);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            // We need to duplicate the word for storage
            const word_copy = try self.allocator.dupe(u8, word);
            gop.key_ptr.* = word_copy;
            gop.value_ptr.* = 1;
        }
        
        // Clear buffer for next word
        self.word_buffer.clearRetainingCapacity();
    }
    
    fn getShardIndex(self: *BatchIndexProcessor, word: []const u8) usize {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(word);
        const hash = hasher.final();
        return hash % NUM_SHARDS;
    }
    
    fn flushShard(self: *BatchIndexProcessor, shard: usize) !void {
        std.debug.print("Flushing shard {d} with {d} terms\n", .{shard, self.current_batches[shard].count()});
        
        if (self.current_batches[shard].count() == 0) {
            return;
        }
        
        // Create temporary copy of the batch
        var batch_copy = std.StringHashMap(i64).init(self.allocator);
        defer batch_copy.deinit();
        
        // Swap the maps
        std.mem.swap(
            std.StringHashMap(i64),
            &self.current_batches[shard],
            &batch_copy
        );
        
        // Ensure the new map has sufficient capacity
        try self.current_batches[shard].ensureTotalCapacity(1000);
        
        // Create a single document update
        self.store.updateIndex(self.document_number, batch_copy);
        
        // Free the words (now owned by batch_copy)
        var it = batch_copy.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
    }
    
    pub fn flushAll(self: *BatchIndexProcessor) !void {
        std.debug.print("Flushing all batches\n", .{});
        
        for (0..NUM_SHARDS) |shard| {
            if (self.current_batches[shard].count() > 0) {
                try self.flushShard(shard);
            }
        }
    }
};

test "batch processor basics" {
    const allocator = std.testing.allocator;
    
    // Create index store
    var store = try IndexStore.init(allocator);
    defer store.deinit();
    
    // Create batch processor
    var processor = try BatchIndexProcessor.init(allocator, store);
    defer processor.deinit();
    
    // Test document processing
    const doc_content = "test-word another_word simple test-word";
    const doc_path = "test/document.txt";
    
    _ = try processor.processDocument(doc_content, doc_path);
    try processor.flushAll();
    
    // Verify that words were added
    const results = store.lookupIndex("test-word");
    defer allocator.free(results);
    
    try std.testing.expect(results.len > 0);
    if (results.len > 0) {
        try std.testing.expectEqual(@as(i64, 2), results[0].word_frequency);
    }
}
