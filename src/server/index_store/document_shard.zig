// src/server/index_store/document_shard.zig
const std = @import("std");

pub const DocumentShard = struct {
    path_to_number: std.StringHashMap(i64),
    number_to_path: std.AutoHashMap(i64, []const u8),
    
    pub fn init(allocator: std.mem.Allocator) DocumentShard {
        std.debug.print("Initializing DocumentShard\n", .{});
        return .{
            .path_to_number = std.StringHashMap(i64).init(allocator),
            .number_to_path = std.AutoHashMap(i64, []const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *DocumentShard) void {
        std.debug.print("Deinitializing DocumentShard\n", .{});
        // Free all stored paths (they are owned by this struct)
        var it = self.number_to_path.iterator();
        while (it.next()) |entry| {
            self.number_to_path.allocator.free(entry.value_ptr.*);
        }
        self.path_to_number.deinit();
        self.number_to_path.deinit();
    }
    
    pub fn putDocument(self: *DocumentShard, allocator: std.mem.Allocator, path: []const u8, doc_num: i64) !void {
        // First check if document already exists
        if (self.path_to_number.get(path)) |_| {
            return; // Already in the map, no need to add again
        }
        
        // Duplicate the path string since we need to own it
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        
        // Add to both maps
        try self.path_to_number.put(path_copy, doc_num);
        errdefer _ = self.path_to_number.remove(path_copy);
        
        try self.number_to_path.put(doc_num, path_copy);
    }
    
    pub fn getDocumentNumber(self: *const DocumentShard, path: []const u8) ?i64 {
        return self.path_to_number.get(path);
    }
    
    pub fn getDocumentPath(self: *const DocumentShard, doc_num: i64) ?[]const u8 {
        return self.number_to_path.get(doc_num);
    }
};
