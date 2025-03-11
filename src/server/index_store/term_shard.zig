// src/server/index_store/term_shard.zig
const std = @import("std");
const DocFreqPair = @import("doc_freq_pair.zig").DocFreqPair;

pub const TermShard = struct {
    term_index: std.StringHashMap(std.ArrayList(DocFreqPair)),
    
    pub fn init(allocator: std.mem.Allocator) TermShard {
        std.debug.print("Initializing TermShard\n", .{});
        return .{
            .term_index = std.StringHashMap(std.ArrayList(DocFreqPair)).init(allocator),
        };
    }
    
    pub fn deinit(self: *TermShard) void {
        std.debug.print("Deinitializing TermShard\n", .{});
        var it = self.term_index.iterator();
        while (it.next()) |entry| {
            // Free the term string and the postings list
            entry.value_ptr.deinit();
            self.term_index.allocator.free(entry.key_ptr.*);
        }
        self.term_index.deinit();
    }
    
    // Update a single term's postings list
    pub fn updateTerm(self: *TermShard, allocator: std.mem.Allocator, term: []const u8, doc_num: i64, freq: i64) !void {
        std.debug.print("Updating term '{s}' for doc {d} with freq {d}\n", .{term, doc_num, freq});
        
        // Check if we already have this term
        var postings: *std.ArrayList(DocFreqPair) = undefined;
        if (self.term_index.getPtr(term)) |existing_postings| {
            postings = existing_postings;
            
            // Check if this document is already in postings
            for (postings.items) |*posting| {
                if (posting.document_number == doc_num) {
                    posting.word_frequency = freq;
                    return;
                }
            }
        } else {
            // Need to duplicate the term string for storage
            const term_copy = try allocator.dupe(u8, term);
            errdefer allocator.free(term_copy);
            
            // Create new postings list
            var new_postings = std.ArrayList(DocFreqPair).init(allocator);
            errdefer new_postings.deinit();
            
            try self.term_index.put(term_copy, new_postings);
            postings = self.term_index.getPtr(term_copy).?;
        }
        
        // Add new posting
        try postings.append(DocFreqPair.init(doc_num, freq));
    }
    
    // Batch update multiple terms
    pub fn batchUpdate(self: *TermShard, allocator: std.mem.Allocator, updates: std.StringHashMap(std.ArrayList(DocFreqPair))) !void {
        var it = updates.iterator();
        while (it.next()) |entry| {
            const term = entry.key_ptr.*;
            const new_postings = entry.value_ptr.*;
            
            std.debug.print("Batch updating term '{s}' with {d} postings\n", .{term, new_postings.items.len});
            
            for (new_postings.items) |posting| {
                try self.updateTerm(allocator, term, posting.document_number, posting.word_frequency);
            }
        }
    }
    
    // Get postings for a term
    pub fn getPostings(self: *const TermShard, term: []const u8) ?[]const DocFreqPair {
        if (self.term_index.get(term)) |postings| {
            return postings.items;
        }
        return null;
    }
};
