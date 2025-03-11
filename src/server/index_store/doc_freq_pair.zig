// src/server/index_store/doc_freq_pair.zig
const std = @import("std");

pub const DocFreqPair = struct {
    document_number: i64,
    word_frequency: i64,
    
    pub fn init(doc_num: i64, freq: i64) DocFreqPair {
        return .{
            .document_number = doc_num,
            .word_frequency = freq,
        };
    }
};
