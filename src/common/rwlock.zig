// src/common/rwlock.zig
const std = @import("std");

pub fn RwLock(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex,
        data: T,
        
        const Self = @This();
        
        pub fn init(data: T) Self {
            return .{
                .mutex = std.Thread.Mutex{},
                .data = data,
            };
        }
        
        pub fn acquireRead(self: *Self) *const T {
            self.mutex.lock();
            return &self.data;
        }
        
        pub fn releaseRead(self: *Self) void {
            self.mutex.unlock();
        }
        
        pub fn acquireWrite(self: *Self) *T {
            self.mutex.lock();
            return &self.data;
        }
        
        pub fn releaseWrite(self: *Self) void {
            self.mutex.unlock();
        }
    };
}
