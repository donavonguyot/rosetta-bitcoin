const std = @import("std");

pub const PortInfo = struct {
    pub const port_key = "zig";
    pub const binary_name = "zigbitnode";
    pub const display_name = "ZigNode";
    pub const default_datadir = "./data-zig";
    pub const marker_file = ".zigbitnode_native_storage";
    pub const lock_file = ".zigbitnode.lock";
    pub const rocksdb_dir = "chainstate-rocksdb";
    pub const rocksdb_shadow_dir = "chainstate-rocksdb-shadow";
    pub const native_dir = "chainstate-native";
};

pub const Outpoint = struct {
    txid: [32]u8,
    vout: u32,
};

pub const StoredUtxo = struct {
    height: u32,
    vout: u32,
    value_sats: u64,
    coinbase: bool,
    script_pubkey: []const u8,

    pub fn deinit(self: StoredUtxo, allocator: std.mem.Allocator) void {
        allocator.free(self.script_pubkey);
    }
};

pub const CreatedUtxo = struct {
    outpoint: Outpoint,
    utxo: StoredUtxo,
};

pub const UndoEntry = struct {
    outpoint: Outpoint,
    utxo: StoredUtxo,
};

pub const ChainstateBlockCommit = struct {
    height: u32,
    block_hash: [32]u8,
    spent_external: []const Outpoint,
    created_utxos: []const CreatedUtxo,
    undo_entries: []const UndoEntry,
    new_utxo_count: i64,
};

pub const Metadata = struct {
    validated_height: i64 = -1,
    validated_hash: []const u8 = "",
    header_height: i64 = -1,
    header_hash: []const u8 = "",
    stored_block_height: i64 = -1,
    stored_block_hash: []const u8 = "",
    chainstate_backend: []const u8 = "rocksdb",
    chainstate_status: []const u8 = "missing",
    sync_status: []const u8 = "starting",
    chainstate_utxo_count: i64 = 0,
    chainstate_set_hash: []const u8 = "",
    current_blocker: []const u8 = "",
};
