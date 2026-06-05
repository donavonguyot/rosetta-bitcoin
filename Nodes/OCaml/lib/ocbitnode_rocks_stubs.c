#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <rocksdb/c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  rocksdb_t *db;
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

CAMLprim value ocbitnode_rocks_open(value path_v, value create_v) {
  CAMLparam2(path_v, create_v);
  CAMLlocal1(block);
  char *err = NULL;
  rocksdb_options_t *options = rocksdb_options_create();
  rocksdb_options_set_create_if_missing(options, Bool_val(create_v));
  rocksdb_options_set_compression(options, rocksdb_lz4_compression);
  rocksdb_options_increase_parallelism(options, 2);
  rocksdb_options_optimize_level_style_compaction(options, 0);
  rocksdb_t *db = rocksdb_open(options, String_val(path_v), &err);
  rocksdb_options_destroy(options);
  if (err != NULL) {
    fail_rocks(err);
  }
  ocbitnode_db *wrapper = malloc(sizeof(ocbitnode_db));
  if (wrapper == NULL) caml_failwith("out of memory");
  wrapper->db = db;
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

static rocksdb_writeoptions_t *write_options(value disable_wal_v, value sync_v) {
  rocksdb_writeoptions_t *options = rocksdb_writeoptions_create();
  rocksdb_writeoptions_disable_WAL(options, Bool_val(disable_wal_v));
  rocksdb_writeoptions_set_sync(options, Bool_val(sync_v));
  return options;
}

CAMLprim value ocbitnode_rocks_put(value db_v, value key_v, value value_v, value disable_wal_v, value sync_v) {
  CAMLparam5(db_v, key_v, value_v, disable_wal_v, sync_v);
  char *err = NULL;
  rocksdb_writeoptions_t *options = write_options(disable_wal_v, sync_v);
  rocksdb_put(db_val(db_v)->db, options, String_val(key_v), caml_string_length(key_v), String_val(value_v), caml_string_length(value_v), &err);
  rocksdb_writeoptions_destroy(options);
  if (err != NULL) fail_rocks(err);
  CAMLreturn(Val_unit);
}

CAMLprim value ocbitnode_rocks_get(value db_v, value key_v) {
  CAMLparam2(db_v, key_v);
  CAMLlocal2(result, some);
  char *err = NULL;
  size_t value_len = 0;
  rocksdb_readoptions_t *options = rocksdb_readoptions_create();
  char *raw_value = rocksdb_get(db_val(db_v)->db, options, String_val(key_v), caml_string_length(key_v), &value_len, &err);
  rocksdb_readoptions_destroy(options);
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

CAMLprim value ocbitnode_rocks_delete(value db_v, value key_v, value disable_wal_v, value sync_v) {
  CAMLparam4(db_v, key_v, disable_wal_v, sync_v);
  char *err = NULL;
  rocksdb_writeoptions_t *options = write_options(disable_wal_v, sync_v);
  rocksdb_delete(db_val(db_v)->db, options, String_val(key_v), caml_string_length(key_v), &err);
  rocksdb_writeoptions_destroy(options);
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
  rocksdb_writeoptions_t *options = write_options(disable_wal_v, sync_v);
  rocksdb_write(db_val(db_v)->db, options, batch_val(batch_v)->batch, &err);
  rocksdb_writeoptions_destroy(options);
  if (err != NULL) fail_rocks(err);
  CAMLreturn(Val_unit);
}

CAMLprim value ocbitnode_rocks_iter_prefix(value db_v, value prefix_v) {
  CAMLparam2(db_v, prefix_v);
  CAMLlocal5(list, pair, key_s, val_s, cons);
  const char *prefix = String_val(prefix_v);
  size_t prefix_len = caml_string_length(prefix_v);
  rocksdb_readoptions_t *options = rocksdb_readoptions_create();
  rocksdb_iterator_t *it = rocksdb_create_iterator(db_val(db_v)->db, options);
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
  rocksdb_readoptions_destroy(options);
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
