//! Re-exports the Zig node library. Build options select store and crypto lane.
//! Importers use these names. This file does not connect blocks or open a store.
//! Does not grow past the export list. New code belongs in the module that owns the rule.

const build_options = @import("crypto_options");

pub const script_verify_split = @import("script_verify_split.zig");
pub const store_mode = build_options.store;
pub const rocksdb_compiled = build_options.store_rocksdb;
pub const shared_root = build_options.shared_root;
pub const fixtures_root = build_options.fixtures_root;
pub const chain_params = @import("chain_params.zig");
pub const consensus_context = @import("consensus_context.zig");
pub const tx = @import("tx.zig");
pub const block = @import("block.zig");
pub const script = @import("script.zig");
pub const p2p = @import("p2p.zig");
pub const store = @import("store.zig");
pub const native_store = @import("native_store.zig");
pub const coins_view = @import("coins_view.zig");
pub const mempool = @import("mempool.zig");
pub const template = @import("template.zig");
pub const context_fixture = @import("context_fixture.zig");
pub const rung0 = @import("rung0.zig");
pub const types = @import("types.zig");
pub const codec = @import("codec.zig");
pub const datadir = @import("datadir.zig");
pub const crypto_glue = @import("crypto_glue.zig");
pub const crypto = crypto_glue.crypto;
pub const connect = @import("connect.zig");
pub const rocks_store = @import("rocks_store.zig");
pub const shadow_store = @import("shadow_store.zig");
pub const RocksDb = rocks_store.RocksDb;
pub const ShadowStore = shadow_store.ShadowStore;

test {
    _ = crypto;
    _ = tx;
    _ = block;
    _ = script;
    _ = connect;
    _ = codec;
    _ = rocks_store;
    _ = shadow_store;
    _ = types;
    _ = datadir;
}
