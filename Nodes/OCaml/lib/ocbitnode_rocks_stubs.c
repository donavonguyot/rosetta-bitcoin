#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <rocksdb/c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
  rocksdb_t *db;
  rocksdb_readoptions_t *ro;
  rocksdb_writeoptions_t *wo_sync;
  rocksdb_writeoptions_t *wo_nosync;
  rocksdb_cache_t *block_cache;
  rocksdb_filterpolicy_t *filter_policy;
  rocksdb_block_based_table_options_t *table_options;
} ocbitnode_db;

typedef struct {
  rocksdb_writebatch_t *batch;
} ocbitnode_batch;

static void fail_rocks(char *err) {
  if (err == NULL) {
    caml_failwith("rocksdb error");
  }
  char *message = strdup(err);
  rocksdb_free(err);
  caml_failwith(message);
}

static void finalize_db(value v) {
  ocbitnode_db *wrapper = *(ocbitnode_db **)Data_custom_val(v);
  if (wrapper != NULL) {
    if (wrapper->db != NULL) {
      rocksdb_close(wrapper->db);
      wrapper->db = NULL;
    }
    if (wrapper->ro != NULL) rocksdb_readoptions_destroy(wrapper->ro);
    if (wrapper->wo_sync != NULL) rocksdb_writeoptions_destroy(wrapper->wo_sync);
    if (wrapper->wo_nosync != NULL) rocksdb_writeoptions_destroy(wrapper->wo_nosync);
    if (wrapper->table_options != NULL) rocksdb_block_based_options_destroy(wrapper->table_options);
    if (wrapper->filter_policy != NULL) rocksdb_filterpolicy_destroy(wrapper->filter_policy);
    if (wrapper->block_cache != NULL) rocksdb_cache_destroy(wrapper->block_cache);
    free(wrapper);
  }
}

static void finalize_batch(value v) {
  ocbitnode_batch *wrapper = *(ocbitnode_batch **)Data_custom_val(v);
  if (wrapper != NULL) {
    if (wrapper->batch != NULL) {
      rocksdb_writebatch_destroy(wrapper->batch);
      wrapper->batch = NULL;
    }
    free(wrapper);
  }
}

static struct custom_operations db_ops = {
  "rb.ocbitnode.rocksdb",
  finalize_db,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static struct custom_operations batch_ops = {
  "rb.ocbitnode.rocksdb_batch",
  finalize_batch,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static ocbitnode_db *db_val(value v) {
  ocbitnode_db *wrapper = *(ocbitnode_db **)Data_custom_val(v);
  if (wrapper == NULL || wrapper->db == NULL) {
    caml_failwith("RocksDB handle is closed");
  }
  return wrapper;
}

static ocbitnode_batch *batch_val(value v) {
  ocbitnode_batch *wrapper = *(ocbitnode_batch **)Data_custom_val(v);
  if (wrapper == NULL || wrapper->batch == NULL) {
    caml_failwith("RocksDB batch handle is closed");
  }
  return wrapper;
}

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000LL + (long long)ts.tv_nsec / 1000000LL;
}

CAMLprim value ocbitnode_rocks_open(value path_v, value create_v) {
  CAMLparam2(path_v, create_v);
  CAMLlocal1(block);
  char *err = NULL;
  rocksdb_options_t *options = rocksdb_options_create();
  rocksdb_cache_t *block_cache = rocksdb_cache_create_lru(512 * 1024 * 1024);
  rocksdb_filterpolicy_t *filter_policy = rocksdb_filterpolicy_create_bloom(10);
  rocksdb_block_based_table_options_t *table_options = rocksdb_block_based_options_create();
  rocksdb_block_based_options_set_block_cache(table_options, block_cache);
  rocksdb_block_based_options_set_filter_policy(table_options, filter_policy);
  rocksdb_block_based_options_set_cache_index_and_filter_blocks(table_options, 1);
  rocksdb_block_based_options_set_pin_l0_filter_and_index_blocks_in_cache(table_options, 1);
  rocksdb_options_set_block_based_table_factory(options, table_options);
  rocksdb_options_set_create_if_missing(options, Bool_val(create_v));
  rocksdb_options_set_compression(options, rocksdb_lz4_compression);
  rocksdb_options_set_max_open_files(options, 1024);
  rocksdb_options_set_write_buffer_size(options, 128 * 1024 * 1024);
  rocksdb_options_set_max_write_buffer_number(options, 6);
  rocksdb_options_set_min_write_buffer_number_to_merge(options, 2);
  rocksdb_options_set_max_background_jobs(options, 4);
  rocksdb_options_set_level0_file_num_compaction_trigger(options, 8);
  rocksdb_options_set_level0_slowdown_writes_trigger(options, 20);
  rocksdb_options_set_level0_stop_writes_trigger(options, 36);
  rocksdb_options_set_target_file_size_base(options, 64 * 1024 * 1024);
  rocksdb_options_set_max_bytes_for_level_base(options, 512 * 1024 * 1024);
  rocksdb_options_increase_parallelism(options, 4);
  rocksdb_t *db = rocksdb_open(options, String_val(path_v), &err);
  rocksdb_options_destroy(options);
  if (err != NULL) {
    rocksdb_block_based_options_destroy(table_options);
    rocksdb_filterpolicy_destroy(filter_policy);
    rocksdb_cache_destroy(block_cache);
    fail_rocks(err);
  }
  ocbitnode_db *wrapper = malloc(sizeof(ocbitnode_db));
  if (wrapper == NULL) caml_failwith("out of memory");
  wrapper->db = db;
  wrapper->ro = rocksdb_readoptions_create();
  wrapper->wo_sync = rocksdb_writeoptions_create();
  wrapper->wo_nosync = rocksdb_writeoptions_create();
  rocksdb_writeoptions_set_sync(wrapper->wo_sync, 1);
  rocksdb_writeoptions_set_sync(wrapper->wo_nosync, 0);
  wrapper->block_cache = block_cache;
  wrapper->filter_policy = filter_policy;
  wrapper->table_options = table_options;
  block = caml_alloc_custom(&db_ops, sizeof(ocbitnode_db *), 0, 1);
  *((ocbitnode_db **)Data_custom_val(block)) = wrapper;
  CAMLreturn(block);
}

CAMLprim value ocbitnode_rocks_close(value db_v) {
  CAMLparam1(db_v);
  ocbitnode_db *wrapper = *(ocbitnode_db **)Data_custom_val(db_v);
  if (wrapper != NULL && wrapper->db != NULL) {
    rocksdb_close(wrapper->db);
    wrapper->db = NULL;
  }
  CAMLreturn(Val_unit);
}

static rocksdb_writeoptions_t *write_options(ocbitnode_db *db, value disable_wal_v, value sync_v) {
  if (!Bool_val(disable_wal_v)) {
    return Bool_val(sync_v) ? db->wo_sync : db->wo_nosync;
  }
  rocksdb_writeoptions_t *options = rocksdb_writeoptions_create();
  rocksdb_writeoptions_disable_WAL(options, Bool_val(disable_wal_v));
  rocksdb_writeoptions_set_sync(options, Bool_val(sync_v));
  return options;
}

CAMLprim value ocbitnode_rocks_put(value db_v, value key_v, value value_v, value disable_wal_v, value sync_v) {
  CAMLparam5(db_v, key_v, value_v, disable_wal_v, sync_v);
  char *err = NULL;
  ocbitnode_db *db = db_val(db_v);
  rocksdb_writeoptions_t *options = write_options(db, disable_wal_v, sync_v);
  rocksdb_put(db->db, options, String_val(key_v), caml_string_length(key_v), String_val(value_v), caml_string_length(value_v), &err);
  if (Bool_val(disable_wal_v)) rocksdb_writeoptions_destroy(options);
  if (err != NULL) fail_rocks(err);
  CAMLreturn(Val_unit);
}

CAMLprim value ocbitnode_rocks_get(value db_v, value key_v) {
  CAMLparam2(db_v, key_v);
  CAMLlocal2(result, some);
  char *err = NULL;
  size_t value_len = 0;
  ocbitnode_db *db = db_val(db_v);
  char *raw_value = rocksdb_get(db->db, db->ro, String_val(key_v), caml_string_length(key_v), &value_len, &err);
  if (err != NULL) fail_rocks(err);
  if (raw_value == NULL) {
    CAMLreturn(Val_none);
  }
  result = caml_alloc_string(value_len);
  memcpy(Bytes_val(result), raw_value, value_len);
  rocksdb_free(raw_value);
  some = caml_alloc(1, 0);
  Store_field(some, 0, result);
  CAMLreturn(some);
}

CAMLprim value ocbitnode_rocks_multi_get(value db_v, value keys_v) {
  CAMLparam2(db_v, keys_v);
  CAMLlocal3(result, value_s, some);
  ocbitnode_db *db = db_val(db_v);
  mlsize_t count = Wosize_val(keys_v);
  result = caml_alloc(count, 0);
  if (count == 0) CAMLreturn(result);
  const char **keys = malloc(sizeof(char *) * count);
  size_t *key_lens = malloc(sizeof(size_t) * count);
  char **values = calloc(count, sizeof(char *));
  size_t *value_lens = calloc(count, sizeof(size_t));
  char **errs = calloc(count, sizeof(char *));
  if (keys == NULL || key_lens == NULL || values == NULL || value_lens == NULL || errs == NULL) {
    free(keys);
    free(key_lens);
    free(values);
    free(value_lens);
    free(errs);
    caml_failwith("out of memory");
  }
  for (mlsize_t i = 0; i < count; i++) {
    value key_v = Field(keys_v, i);
    keys[i] = String_val(key_v);
    key_lens[i] = caml_string_length(key_v);
  }
  rocksdb_multi_get(db->db, db->ro, count, keys, key_lens, values, value_lens, errs);
  free(keys);
  free(key_lens);
  for (mlsize_t i = 0; i < count; i++) {
    if (errs[i] != NULL) {
      char *message = strdup(errs[i]);
      rocksdb_free(errs[i]);
      for (mlsize_t j = 0; j < count; j++) {
        if (values[j] != NULL) rocksdb_free(values[j]);
      }
      free(values);
      free(value_lens);
      free(errs);
      caml_failwith(message);
    }
    if (values[i] == NULL) {
      Store_field(result, i, Val_none);
    } else {
      value_s = caml_alloc_string(value_lens[i]);
      memcpy(Bytes_val(value_s), values[i], value_lens[i]);
      rocksdb_free(values[i]);
      some = caml_alloc(1, 0);
      Store_field(some, 0, value_s);
      Store_field(result, i, some);
    }
  }
  free(values);
  free(value_lens);
  free(errs);
  CAMLreturn(result);
}

static void encode_be32(char *dst, int value) {
  dst[0] = (char)((value >> 24) & 0xff);
  dst[1] = (char)((value >> 16) & 0xff);
  dst[2] = (char)((value >> 8) & 0xff);
  dst[3] = (char)(value & 0xff);
}

CAMLprim value ocbitnode_rocks_multi_get_utxo_raw(value db_v, value chain_v, value outpoints_v) {
  CAMLparam3(db_v, chain_v, outpoints_v);
  CAMLlocal5(result, value_s, some, stats, pair);
  ocbitnode_db *db = db_val(db_v);
  mlsize_t count = Wosize_val(outpoints_v);
  size_t chain_len = caml_string_length(chain_v);
  if (chain_len >= 0xfd) caml_invalid_argument("codec v2 chain name too long");
  size_t key_len = 1 + 1 + chain_len + 32 + 4;
  result = caml_alloc(count, 0);
  if (count == 0) {
    stats = caml_alloc_tuple(4);
    Store_field(stats, 0, Val_int(0));
    Store_field(stats, 1, Val_int(0));
    Store_field(stats, 2, Val_int(0));
    Store_field(stats, 3, Val_int(0));
    pair = caml_alloc_tuple(2);
    Store_field(pair, 0, result);
    Store_field(pair, 1, stats);
    CAMLreturn(pair);
  }

  char *key_bytes = malloc(key_len * count);
  const char **keys = malloc(sizeof(char *) * count);
  size_t *key_lens = malloc(sizeof(size_t) * count);
  char **values = calloc(count, sizeof(char *));
  size_t *value_lens = calloc(count, sizeof(size_t));
  char **errs = calloc(count, sizeof(char *));
  if (key_bytes == NULL || keys == NULL || key_lens == NULL || values == NULL || value_lens == NULL || errs == NULL) {
    free(key_bytes);
    free(keys);
    free(key_lens);
    free(values);
    free(value_lens);
    free(errs);
    caml_failwith("out of memory");
  }

  for (mlsize_t i = 0; i < count; i++) {
    value outpoint_v = Field(outpoints_v, i);
    value txid_v = Field(outpoint_v, 0);
    int vout = Int_val(Field(outpoint_v, 1));
    if (caml_string_length(txid_v) != 32) {
      free(key_bytes);
      free(keys);
      free(key_lens);
      free(values);
      free(value_lens);
      free(errs);
      caml_invalid_argument("UTXO txid must be 32 bytes");
    }
    char *dst = key_bytes + (key_len * i);
    dst[0] = 'u';
    dst[1] = (char)chain_len;
    memcpy(dst + 2, String_val(chain_v), chain_len);
    memcpy(dst + 2 + chain_len, String_val(txid_v), 32);
    encode_be32(dst + 2 + chain_len + 32, vout);
    keys[i] = dst;
    key_lens[i] = key_len;
  }

  long long started = now_ms();
  rocksdb_multi_get(db->db, db->ro, count, keys, key_lens, values, value_lens, errs);
  long long elapsed = now_ms() - started;
  free(keys);
  free(key_lens);
  size_t value_bytes = 0;
  for (mlsize_t i = 0; i < count; i++) {
    if (errs[i] != NULL) {
      char *message = strdup(errs[i]);
      rocksdb_free(errs[i]);
      for (mlsize_t j = 0; j < count; j++) {
        if (values[j] != NULL) rocksdb_free(values[j]);
      }
      free(key_bytes);
      free(values);
      free(value_lens);
      free(errs);
      caml_failwith(message);
    }
    if (values[i] == NULL) {
      Store_field(result, i, Val_none);
    } else {
      value_bytes += value_lens[i];
      value_s = caml_alloc_string(value_lens[i]);
      memcpy(Bytes_val(value_s), values[i], value_lens[i]);
      rocksdb_free(values[i]);
      some = caml_alloc(1, 0);
      Store_field(some, 0, value_s);
      Store_field(result, i, some);
    }
  }
  free(key_bytes);
  free(values);
  free(value_lens);
  free(errs);

  stats = caml_alloc_tuple(4);
  Store_field(stats, 0, Val_int(count));
  Store_field(stats, 1, Val_int(key_len * count));
  Store_field(stats, 2, Val_int(value_bytes));
  Store_field(stats, 3, Val_int(elapsed < 0 ? 0 : elapsed));
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, result);
  Store_field(pair, 1, stats);
  CAMLreturn(pair);
}

CAMLprim value ocbitnode_rocks_delete(value db_v, value key_v, value disable_wal_v, value sync_v) {
  CAMLparam4(db_v, key_v, disable_wal_v, sync_v);
  char *err = NULL;
  ocbitnode_db *db = db_val(db_v);
  rocksdb_writeoptions_t *options = write_options(db, disable_wal_v, sync_v);
  rocksdb_delete(db->db, options, String_val(key_v), caml_string_length(key_v), &err);
  if (Bool_val(disable_wal_v)) rocksdb_writeoptions_destroy(options);
  if (err != NULL) fail_rocks(err);
  CAMLreturn(Val_unit);
}

CAMLprim value ocbitnode_rocks_batch_create(value unit_v) {
  CAMLparam1(unit_v);
  CAMLlocal1(block);
  ocbitnode_batch *wrapper = malloc(sizeof(ocbitnode_batch));
  if (wrapper == NULL) caml_failwith("out of memory");
  wrapper->batch = rocksdb_writebatch_create();
  block = caml_alloc_custom(&batch_ops, sizeof(ocbitnode_batch *), 0, 1);
  *((ocbitnode_batch **)Data_custom_val(block)) = wrapper;
  CAMLreturn(block);
}

CAMLprim value ocbitnode_rocks_batch_put(value batch_v, value key_v, value value_v) {
  CAMLparam3(batch_v, key_v, value_v);
  rocksdb_writebatch_put(batch_val(batch_v)->batch, String_val(key_v), caml_string_length(key_v), String_val(value_v), caml_string_length(value_v));
  CAMLreturn(Val_unit);
}

CAMLprim value ocbitnode_rocks_batch_delete(value batch_v, value key_v) {
  CAMLparam2(batch_v, key_v);
  rocksdb_writebatch_delete(batch_val(batch_v)->batch, String_val(key_v), caml_string_length(key_v));
  CAMLreturn(Val_unit);
}

CAMLprim value ocbitnode_rocks_batch_write(value db_v, value batch_v, value disable_wal_v, value sync_v) {
  CAMLparam4(db_v, batch_v, disable_wal_v, sync_v);
  char *err = NULL;
  ocbitnode_db *db = db_val(db_v);
  rocksdb_writeoptions_t *options = write_options(db, disable_wal_v, sync_v);
  ocbitnode_batch *wrapper = batch_val(batch_v);
  rocksdb_write(db->db, options, wrapper->batch, &err);
  rocksdb_writebatch_destroy(wrapper->batch);
  wrapper->batch = NULL;
  if (Bool_val(disable_wal_v)) rocksdb_writeoptions_destroy(options);
  if (err != NULL) fail_rocks(err);
  CAMLreturn(Val_unit);
}

CAMLprim value ocbitnode_rocks_batch_write_timed(value db_v, value batch_v, value disable_wal_v, value sync_v) {
  CAMLparam4(db_v, batch_v, disable_wal_v, sync_v);
  char *err = NULL;
  ocbitnode_db *db = db_val(db_v);
  rocksdb_writeoptions_t *options = write_options(db, disable_wal_v, sync_v);
  ocbitnode_batch *wrapper = batch_val(batch_v);
  long long started = now_ms();
  rocksdb_write(db->db, options, wrapper->batch, &err);
  long long elapsed = now_ms() - started;
  rocksdb_writebatch_destroy(wrapper->batch);
  wrapper->batch = NULL;
  if (Bool_val(disable_wal_v)) rocksdb_writeoptions_destroy(options);
  if (err != NULL) fail_rocks(err);
  CAMLreturn(Val_int(elapsed < 0 ? 0 : elapsed));
}

CAMLprim value ocbitnode_rocks_iter_prefix(value db_v, value prefix_v) {
  CAMLparam2(db_v, prefix_v);
  CAMLlocal5(list, pair, key_s, val_s, cons);
  const char *prefix = String_val(prefix_v);
  size_t prefix_len = caml_string_length(prefix_v);
  ocbitnode_db *db = db_val(db_v);
  rocksdb_iterator_t *it = rocksdb_create_iterator(db->db, db->ro);
  list = Val_emptylist;
  rocksdb_iter_seek(it, prefix, prefix_len);
  while (rocksdb_iter_valid(it)) {
    size_t key_len = 0;
    size_t value_len = 0;
    const char *key = rocksdb_iter_key(it, &key_len);
    if (key_len < prefix_len || memcmp(key, prefix, prefix_len) != 0) break;
    const char *raw_value = rocksdb_iter_value(it, &value_len);
    key_s = caml_alloc_string(key_len);
    memcpy(Bytes_val(key_s), key, key_len);
    val_s = caml_alloc_string(value_len);
    memcpy(Bytes_val(val_s), raw_value, value_len);
    pair = caml_alloc_tuple(2);
    Store_field(pair, 0, key_s);
    Store_field(pair, 1, val_s);
    cons = caml_alloc_small(2, 0);
    Field(cons, 0) = pair;
    Field(cons, 1) = list;
    list = cons;
    rocksdb_iter_next(it);
  }
  char *err = NULL;
  rocksdb_iter_get_error(it, &err);
  rocksdb_iter_destroy(it);
  if (err != NULL) fail_rocks(err);
  CAMLreturn(list);
}

CAMLprim value ocbitnode_rocks_version(value unit_v) {
  CAMLparam1(unit_v);
  CAMLreturn(caml_copy_string("rocksdb-c-api"));
}

CAMLprim value ocbitnode_rocks_stats(value db_v) {
  CAMLparam1(db_v);
  char *stats = rocksdb_property_value(db_val(db_v)->db, "rocksdb.stats");
  if (stats == NULL) {
    CAMLreturn(caml_copy_string(""));
  }
  value result = caml_copy_string(stats);
  rocksdb_free(stats);
  CAMLreturn(result);
}
