// src/server/index_store/index_store.zig
const std = @import("std");
const RwLock = @import("../../common/rwlock.zig").RwLock;
const DocFreqPair = @import("doc_freq_pair.zig").DocFreqPair;
const DocumentShard = @import("document_shard.zig").DocumentShard;
const TermShard = @import("term_shard.zig").TermShard;

pub const NUM_SHARDS = 256;

pub const IndexStore = struct {
    allocator: std.mem.Allocator,
    doc_map_shards: []RwLock(DocumentShard),
    term_index_shards: []RwLock(TermShard),
    next_document_number: std.atomic.Value(i64),

    pub fn init(allocator: std.mem.Allocator) !*IndexStore {
        std.debug.print("Initializing IndexStore with {d} shards\n", .{NUM_SHARDS});
        
        // Allocate the IndexStore itself
        var self = try allocator.create(IndexStore);
        errdefer allocator.destroy(self);
        
        // Allocate shard arrays
        var doc_map_shards = try allocator.alloc(RwLock(DocumentShard), NUM_SHARDS);
        errdefer allocator.free(doc_map_shards);
        
        var term_index_shards = try allocator.alloc(RwLock(TermShard), NUM_SHARDS);
        errdefer allocator.free(term_index_shards);
        
        // Initialize all shards
        for (0..NUM_SHARDS) |i| {
            doc_map_shards[i] = RwLock(DocumentShard).init(DocumentShard.init(allocator));
            term_index_shards[i] = RwLock(TermShard).init(TermShard.init(allocator));
            std.debug.print("Initialized shard {d}\n", .{i});
        }
        
        // Initialize the IndexStore
        self.* = .{
            .allocator = allocator,
            .doc_map_shards = doc_map_shards,
            .term_index_shards = term_index_shards,
            .next_document_number = std.atomic.Value(i64).init(1),
        };
        
        return self;
    }
    
    pub fn deinit(self: *IndexStore) void {
        std.debug.print("Deinitializing IndexStore\n", .{});
        
        // Deinitialize all shards
        for (0..NUM_SHARDS) |i| {
            var doc_shard = self.doc_map_shards[i].acquireWrite();
            doc_shard.deinit();
            self.doc_map_shards[i].releaseWrite();
            
            var term_shard = self.term_index_shards[i].acquireWrite();
            term_shard.deinit();
            self.term_index_shards[i].releaseWrite();
            
            std.debug.print("Deinitialized shard {d}\n", .{i});
        }
        
        // Free shard arrays
        self.allocator.free(self.doc_map_shards);
        self.allocator.free(self.term_index_shards);
        
        // Free the IndexStore itself
        self.allocator.destroy(self);
    }
    
    // Hash function to determine shard index for documents
    fn getDocMapShardIndex(self: *const IndexStore, path: []const u8) usize {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(path);
        const hash = hasher.final();
        const shard = hash % NUM_SHARDS;
        std.debug.print("Doc shard for '{s}': {d}\n", .{path, shard});
        return shard;
    }

    // Hash function to determine shard index for terms
    fn getTermShardIndex(self: *const IndexStore, term: []const u8) usize {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(term);
        const hash = hasher.final();
        const shard = hash % NUM_SHARDS;
        std.debug.print("Term shard for '{s}': {d}\n", .{term, shard});
        return shard;
    }

    // Add or get a document number for a path
    pub fn putDocument(self: *IndexStore, document_path: []const u8) i64 {
        std.debug.print("Putting document: {s}\n", .{document_path});
        
        const shard_idx = self.getDocMapShardIndex(document_path);
        var shard = self.doc_map_shards[shard_idx].acquireWrite();
        defer self.doc_map_shards[shard_idx].releaseWrite();
        
        // Check if document already exists
        if (shard.getDocumentNumber(document_path)) |doc_num| {
            std.debug.print("  Document already exists with ID: {d}\n", .{doc_num});
            return doc_num;
        }
        
        // Assign new document number
        const doc_num = self.next_document_number.fetchAdd(1, .SeqCst);
        std.debug.print("  Assigned new document ID: {d}\n", .{doc_num});
        
        // Store document path
        shard.putDocument(self.allocator, document_path, doc_num) catch |err| {
            std.debug.print("  Error storing document: {}\n", .{err});
        };
        
        return doc_num;
    }

    // Get document path from document number
    pub fn getDocument(self: *const IndexStore, document_number: i64) ?[]const u8 {
        std.debug.print("Getting document with ID: {d}\n", .{document_number});
        
        // Search all shards since we don't know which one contains the document
        for (0..NUM_SHARDS) |i| {
            var shard = self.doc_map_shards[i].acquireRead();
            defer self.doc_map_shards[i].releaseRead();
            
            if (shard.getDocumentPath(document_number)) |path| {
                std.debug.print("  Found document in shard {d}: {s}\n", .{i, path});
                return path;
            }
        }
        
        std.debug.print("  Document not found\n", .{});
        return null;
    }

    // Update the index with word frequencies for a document
    pub fn updateIndex(self: *IndexStore, document_number: i64, word_frequencies: std.StringHashMap(i64)) void {
        std.debug.print("Updating index for doc {d}, words: {d}\n", .{document_number, word_frequencies.count()});
        
        // Group updates by shard
        var shard_updates = std.AutoHashMap(usize, std.StringHashMap(i64)).init(self.allocator);
        defer {
            var it = shard_updates.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            shard_updates.deinit();
        }
        
        // Distribute words to their respective shards
        var word_it = word_frequencies.iterator();
        while (word_it.next()) |entry| {
            const word = entry.key_ptr.*;
            const freq = entry.value_ptr.*;
            const shard = self.getTermShardIndex(word);
            
            // Get or create hashmap for this shard
            if (!shard_updates.contains(shard)) {
                shard_updates.put(shard, std.StringHashMap(i64).init(self.allocator)) catch |err| {
                    std.debug.print("Failed to create hashmap for shard {d}: {}\n", .{shard, err});
                    continue;
                };
            }
            
            // Add word to shard updates
            if (shard_updates.getPtr(shard)) |shard_map| {
                shard_map.put(word, freq) catch |err| {
                    std.debug.print("Failed to add word to shard {d}: {}\n", .{shard, err});
                };
            }
        }
        
        // Apply updates to each shard
        var shard_it = shard_updates.iterator();
        while (shard_it.next()) |entry| {
            const shard_idx = entry.key_ptr.*;
            const updates = entry.value_ptr.*;
            
            if (updates.count() > 0) {
                var shard = self.term_index_shards[shard_idx].acquireWrite();
                defer self.term_index_shards[shard_idx].releaseWrite();
                
                var update_it = updates.iterator();
                while (update_it.next()) |update| {
                    const word = update.key_ptr.*;
                    const freq = update.value_ptr.*;
                    
                    shard.updateTerm(self.allocator, word, document_number, freq) catch |err| {
                        std.debug.print("Failed to update term '{s}': {}\n", .{word, err});
                    };
                }
            }
        }
    }

    // Batch update index with multiple documents
    pub fn batchUpdateIndex(self: *IndexStore, updates: []const struct { doc_num: i64, freqs: std.StringHashMap(i64) }) void {
        std.debug.print("Batch updating index with {d} documents\n", .{updates.len});
        
        // Group by shard
        var shard_updates = std.AutoHashMap(usize, std.StringHashMap(std.ArrayList(DocFreqPair))).init(self.allocator);
        defer {
            var it = shard_updates.iterator();
            while (it.next()) |entry| {
                var term_it = entry.value_ptr.iterator();
                while (term_it.next()) |term_entry| {
                    term_entry.value_ptr.deinit();
                }
                entry.value_ptr.deinit();
            }
            shard_updates.deinit();
        }
        
        // Process all documents and group updates by shard and term
        for (updates) |update| {
            var word_it = update.freqs.iterator();
            while (word_it.next()) |entry| {
                const word = entry.key_ptr.*;
                const freq = entry.value_ptr.*;
                const shard = self.getTermShardIndex(word);
                
                // Get or create map for this shard
                if (!shard_updates.contains(shard)) {
                    shard_updates.put(shard, std.StringHashMap(std.ArrayList(DocFreqPair)).init(self.allocator)) catch |err| {
                        std.debug.print("Failed to create map for shard {d}: {}\n", .{shard, err});
                        continue;
                    };
                }
                
                var shard_map = shard_updates.getPtr(shard).?;
                
                // Get or create postings list for this term
                if (!shard_map.contains(word)) {
                    shard_map.put(word, std.ArrayList(DocFreqPair).init(self.allocator)) catch |err| {
                        std.debug.print("Failed to create list for term '{s}': {}\n", .{word, err});
                        continue;
                    };
                }
                
                var postings = shard_map.getPtr(word).?;
                
                // Add posting
                postings.append(DocFreqPair.init(update.doc_num, freq)) catch |err| {
                    std.debug.print("Failed to append posting: {}\n", .{err});
                };
            }
        }
        
        // Apply updates to each shard
        var shard_it = shard_updates.iterator();
        while (shard_it.next()) |entry| {
            const shard_idx = entry.key_ptr.*;
            const shard_map = entry.value_ptr.*;
            
            if (shard_map.count() > 0) {
                var shard = self.term_index_shards[shard_idx].acquireWrite();
                defer self.term_index_shards[shard_idx].releaseWrite();
                
                shard.batchUpdate(self.allocator, shard_map) catch |err| {
                    std.debug.print("Failed to batch update shard {d}: {}\n", .{shard_idx, err});
                };
            }
        }
    }

    // Look up postings for a term
    pub fn lookupIndex(self: *const IndexStore, term: []const u8) []DocFreqPair {
        std.debug.print("Looking up term: '{s}'\n", .{term});
        
        // Find the shard for this term
        const shard_idx = self.getTermShardIndex(term);
        var shard = self.term_index_shards[shard_idx].acquireRead();
        defer self.term_index_shards[shard_idx].releaseRead();
        
        var results = std.ArrayList(DocFreqPair).init(self.allocator);
        
        if (shard.getPostings(term)) |postings| {
            std.debug.print("  Found {d} postings\n", .{postings.len});
            for (postings) |posting| {
                results.append(posting) catch |err| {
                    std.debug.print("  Failed to append posting: {}\n", .{err});
                };
            }
        } else {
            std.debug.print("  No postings found\n", .{});
        }
        
        return results.toOwnedSlice() catch |err| {
            std.debug.print("Failed to convert results to slice: {}\n", .{err});
            return &[_]DocFreqPair{};
        };
    }

    // Search for documents matching multiple terms
    pub fn search(self: *const IndexStore, terms: []const []const u8) []struct { path: []const u8, freq: i64 } {
        std.debug.print("Searching for {d} terms\n", .{terms.len});
        
        if (terms.len == 0) {
            return &[_]struct { path: []const u8, freq: i64 }{};
        }
        
        // Get results for each term
        var all_results = std.ArrayList([]DocFreqPair).init(self.allocator);
        defer {
            for (all_results.items) |results| {
                self.allocator.free(results);
            }
            all_results.deinit();
        }
        
        for (terms) |term| {
            var results = self.lookupIndex(term);
            all_results.append(results) catch |err| {
                std.debug.print("Failed to append results: {}\n", .{err});
                continue;
            };
        }
        
        if (all_results.items.len == 0) {
            return &[_]struct { path: []const u8, freq: i64 }{};
        }
        
        // Combine results (AND operation)
        var combined_freqs = std.AutoHashMap(i64, i64).init(self.allocator);
        defer combined_freqs.deinit();
        
        // Start with first term's results
        for (all_results.items[0]) |pair| {
            combined_freqs.put(pair.document_number, pair.word_frequency) catch |err| {
                std.debug.print("Failed to add to combined results: {}\n", .{err});
            };
        }
        
        // AND with remaining terms
        for (all_results.items[1..]) |term_results| {
            var new_freqs = std.AutoHashMap(i64, i64).init(self.allocator);
            defer new_freqs.deinit();
            
            for (term_results) |pair| {
                if (combined_freqs.get(pair.document_number)) |prev_freq| {
                    new_freqs.put(pair.document_number, prev_freq + pair.word_frequency) catch |err| {
                        std.debug.print("Failed to add to new freqs: {}\n", .{err});
                    };
                }
            }
            
            // Replace combined_freqs with new_freqs
            var temp = combined_freqs;
            combined_freqs = new_freqs;
            temp.deinit();
        }
        
        // Convert to sorted array of results with paths
        var sorted_results = std.ArrayList(struct { path: []const u8, freq: i64 }).init(self.allocator);
        defer sorted_results.deinit();
        
        var it = combined_freqs.iterator();
        while (it.next()) |entry| {
            const doc_num = entry.key_ptr.*;
            const freq = entry.value_ptr.*;
            
            if (self.getDocument(doc_num)) |path| {
                // Create a copy of the path
                const path_copy = self.allocator.dupe(u8, path) catch |err| {
                    std.debug.print("Failed to duplicate path: {}\n", .{err});
                    continue;
                };
                
                sorted_results.append(.{ .path = path_copy, .freq = freq }) catch |err| {
                    std.debug.print("Failed to append result: {}\n", .{err});
                    self.allocator.free(path_copy);
                };
            }
        }
        
        // Sort by frequency (highest first)
        std.sort.sort(struct { path: []const u8, freq: i64 }, sorted_results.items, {}, struct {
            fn lessThan(_: void, a: struct { path: []const u8, freq: i64 }, b: struct { path: []const u8, freq: i64 }) bool {
                return b.freq < a.freq; // Descending order
            }
        }.lessThan);
        
        // Keep top 10 results
        if (sorted_results.items.len > 10) {
            for (sorted_results.items[10..]) |item| {
                self.allocator.free(item.path);
            }
            sorted_results.shrinkRetainingCapacity(10);
        }
        
        return sorted_results.toOwnedSlice() catch |err| {
            std.debug.print("Failed to convert to slice: {}\n", .{err});
            return &[_]struct { path: []const u8, freq: i64 }{};
        };
    }
};
