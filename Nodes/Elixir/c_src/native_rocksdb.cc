#include <stdlib.h>
#include <string.h>

#include "erl_nif.h"
#include "rocksdb/c.h"

typedef struct {
  rocksdb_t *db;
  rocksdb_options_t *options;
  char *path;
} db_resource_t;

static ErlNifResourceType *DB_RES = NULL;

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_nil;
static ERL_NIF_TERM atom_put;
static ERL_NIF_TERM atom_delete;

static long env_long(const char *name, long default_value) {
  const char *raw = getenv(name);
  if (raw == NULL || raw[0] == 0) return default_value;
  char *end = NULL;
  long parsed = strtol(raw, &end, 10);
  if (end == raw || parsed <= 0) return default_value;
  return parsed;
}

static int env_flag(const char *name) {
  const char *raw = getenv(name);
  if (raw == NULL) return 0;
  return strcmp(raw, "1") == 0 || strcmp(raw, "true") == 0 || strcmp(raw, "TRUE") == 0 ||
         strcmp(raw, "yes") == 0 || strcmp(raw, "YES") == 0;
}

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *message) {
  return enif_make_tuple2(env, atom_error, enif_make_string(env, message, ERL_NIF_LATIN1));
}

static ERL_NIF_TERM make_error_from_cstr(ErlNifEnv *env, char *err) {
  ERL_NIF_TERM result = make_error(env, err == NULL ? "rocksdb error" : err);
  if (err != NULL) {
    rocksdb_free(err);
  }
  return result;
}

static int get_binary_arg(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *bin) {
  return enif_inspect_binary(env, term, bin);
}

static void db_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  db_resource_t *res = (db_resource_t *)obj;
  if (res->db != NULL) {
    rocksdb_close(res->db);
    res->db = NULL;
  }
  if (res->options != NULL) {
    rocksdb_options_destroy(res->options);
    res->options = NULL;
  }
  if (res->path != NULL) {
    enif_free(res->path);
    res->path = NULL;
  }
}

static ERL_NIF_TERM open_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 1) return enif_make_badarg(env);

  unsigned path_len = 0;
  if (!enif_get_list_length(env, argv[0], &path_len) && !enif_is_binary(env, argv[0])) {
    return enif_make_badarg(env);
  }

  char path[4096];
  if (enif_get_string(env, argv[0], path, sizeof(path), ERL_NIF_UTF8) <= 0) {
    ErlNifBinary path_bin;
    if (!enif_inspect_binary(env, argv[0], &path_bin) || path_bin.size >= sizeof(path)) {
      return enif_make_badarg(env);
    }
    memcpy(path, path_bin.data, path_bin.size);
    path[path_bin.size] = 0;
  }

  db_resource_t *res = (db_resource_t *)enif_alloc_resource(DB_RES, sizeof(db_resource_t));
  memset(res, 0, sizeof(db_resource_t));
  res->options = rocksdb_options_create();
  rocksdb_options_set_create_if_missing(res->options, 1);
  rocksdb_options_set_compression(res->options, rocksdb_no_compression);
  rocksdb_options_set_write_buffer_size(res->options, env_long("ROCKSDB_WRITE_BUFFER_BYTES", 128L * 1024L * 1024L));
  rocksdb_options_set_max_write_buffer_number(res->options, (int)env_long("ROCKSDB_MAX_WRITE_BUFFERS", 4));
  rocksdb_options_set_max_background_jobs(res->options, (int)env_long("ROCKSDB_MAX_BACKGROUND_JOBS", 4));
  rocksdb_cache_t *block_cache = rocksdb_cache_create_lru(env_long("ROCKSDB_BLOCK_CACHE_BYTES", 128L * 1024L * 1024L));
  rocksdb_filterpolicy_t *filter_policy = rocksdb_filterpolicy_create_bloom(10);
  rocksdb_block_based_table_options_t *table_options = rocksdb_block_based_options_create();
  rocksdb_block_based_options_set_block_cache(table_options, block_cache);
  rocksdb_block_based_options_set_filter_policy(table_options, filter_policy);
  rocksdb_block_based_options_set_cache_index_and_filter_blocks(table_options, 1);
  rocksdb_block_based_options_set_pin_l0_filter_and_index_blocks_in_cache(table_options, 1);
  rocksdb_options_set_block_based_table_factory(res->options, table_options);
  res->path = (char *)enif_alloc(strlen(path) + 1);
  strcpy(res->path, path);

  char *err = NULL;
  res->db = rocksdb_open(res->options, path, &err);
  if (err != NULL) {
    ERL_NIF_TERM error = make_error_from_cstr(env, err);
    enif_release_resource(res);
    return error;
  }

  ERL_NIF_TERM term = enif_make_resource(env, res);
  enif_release_resource(res);
  return enif_make_tuple2(env, atom_ok, term);
}

static ERL_NIF_TERM close_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 1) return enif_make_badarg(env);
  db_resource_t *res;
  if (!enif_get_resource(env, argv[0], DB_RES, (void **)&res)) return enif_make_badarg(env);
  if (res->db != NULL) {
    rocksdb_close(res->db);
    res->db = NULL;
  }
  return atom_ok;
}

static ERL_NIF_TERM get_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 2) return enif_make_badarg(env);
  db_resource_t *res;
  ErlNifBinary key;
  if (!enif_get_resource(env, argv[0], DB_RES, (void **)&res) || !get_binary_arg(env, argv[1], &key)) {
    return enif_make_badarg(env);
  }
  if (res->db == NULL) return make_error(env, "rocksdb handle closed");

  rocksdb_readoptions_t *read_opts = rocksdb_readoptions_create();
  char *err = NULL;
  size_t value_len = 0;
  char *value = rocksdb_get(res->db, read_opts, (const char *)key.data, key.size, &value_len, &err);
  rocksdb_readoptions_destroy(read_opts);

  if (err != NULL) return make_error_from_cstr(env, err);
  if (value == NULL) return atom_nil;

  ERL_NIF_TERM bin;
  unsigned char *out = enif_make_new_binary(env, value_len, &bin);
  memcpy(out, value, value_len);
  rocksdb_free(value);
  return enif_make_tuple2(env, atom_ok, bin);
}

static ERL_NIF_TERM put_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 3) return enif_make_badarg(env);
  db_resource_t *res;
  ErlNifBinary key, value;
  if (!enif_get_resource(env, argv[0], DB_RES, (void **)&res) ||
      !get_binary_arg(env, argv[1], &key) ||
      !get_binary_arg(env, argv[2], &value)) {
    return enif_make_badarg(env);
  }
  if (res->db == NULL) return make_error(env, "rocksdb handle closed");

  rocksdb_writeoptions_t *write_opts = rocksdb_writeoptions_create();
  rocksdb_writeoptions_set_sync(write_opts, 1);
  if (env_flag("ROCKSDB_DISABLE_WAL")) {
    rocksdb_writeoptions_disable_WAL(write_opts, 1);
  }
  char *err = NULL;
  rocksdb_put(res->db, write_opts, (const char *)key.data, key.size, (const char *)value.data, value.size, &err);
  rocksdb_writeoptions_destroy(write_opts);
  if (err != NULL) return make_error_from_cstr(env, err);
  return atom_ok;
}

static ERL_NIF_TERM delete_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 2) return enif_make_badarg(env);
  db_resource_t *res;
  ErlNifBinary key;
  if (!enif_get_resource(env, argv[0], DB_RES, (void **)&res) || !get_binary_arg(env, argv[1], &key)) {
    return enif_make_badarg(env);
  }
  if (res->db == NULL) return make_error(env, "rocksdb handle closed");

  rocksdb_writeoptions_t *write_opts = rocksdb_writeoptions_create();
  rocksdb_writeoptions_set_sync(write_opts, 1);
  if (env_flag("ROCKSDB_DISABLE_WAL")) {
    rocksdb_writeoptions_disable_WAL(write_opts, 1);
  }
  char *err = NULL;
  rocksdb_delete(res->db, write_opts, (const char *)key.data, key.size, &err);
  rocksdb_writeoptions_destroy(write_opts);
  if (err != NULL) return make_error_from_cstr(env, err);
  return atom_ok;
}

static ERL_NIF_TERM write_batch_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 2) return enif_make_badarg(env);
  db_resource_t *res;
  if (!enif_get_resource(env, argv[0], DB_RES, (void **)&res)) return enif_make_badarg(env);
  if (res->db == NULL) return make_error(env, "rocksdb handle closed");

  rocksdb_writebatch_t *batch = rocksdb_writebatch_create();
  ERL_NIF_TERM list = argv[1];
  ERL_NIF_TERM head, tail;
  while (enif_get_list_cell(env, list, &head, &tail)) {
    const ERL_NIF_TERM *tuple;
    int arity = 0;
    if (!enif_get_tuple(env, head, &arity, &tuple) || (arity != 2 && arity != 3)) {
      rocksdb_writebatch_destroy(batch);
      return enif_make_badarg(env);
    }

    if (arity == 3 && enif_is_identical(tuple[0], atom_put)) {
      ErlNifBinary key, value;
      if (!get_binary_arg(env, tuple[1], &key) || !get_binary_arg(env, tuple[2], &value)) {
        rocksdb_writebatch_destroy(batch);
        return enif_make_badarg(env);
      }
      rocksdb_writebatch_put(batch, (const char *)key.data, key.size, (const char *)value.data, value.size);
    } else if (arity == 2 && enif_is_identical(tuple[0], atom_delete)) {
      ErlNifBinary key;
      if (!get_binary_arg(env, tuple[1], &key)) {
        rocksdb_writebatch_destroy(batch);
        return enif_make_badarg(env);
      }
      rocksdb_writebatch_delete(batch, (const char *)key.data, key.size);
    } else {
      rocksdb_writebatch_destroy(batch);
      return enif_make_badarg(env);
    }
    list = tail;
  }
  if (!enif_is_empty_list(env, list)) {
    rocksdb_writebatch_destroy(batch);
    return enif_make_badarg(env);
  }

  rocksdb_writeoptions_t *write_opts = rocksdb_writeoptions_create();
  rocksdb_writeoptions_set_sync(write_opts, 1);
  if (env_flag("ROCKSDB_DISABLE_WAL")) {
    rocksdb_writeoptions_disable_WAL(write_opts, 1);
  }
  char *err = NULL;
  rocksdb_write(res->db, write_opts, batch, &err);
  rocksdb_writeoptions_destroy(write_opts);
  rocksdb_writebatch_destroy(batch);
  if (err != NULL) return make_error_from_cstr(env, err);
  return atom_ok;
}

static ERL_NIF_TERM multi_get_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 2) return enif_make_badarg(env);
  db_resource_t *res;
  if (!enif_get_resource(env, argv[0], DB_RES, (void **)&res)) return enif_make_badarg(env);
  if (res->db == NULL) return make_error(env, "rocksdb handle closed");

  unsigned count = 0;
  if (!enif_get_list_length(env, argv[1], &count)) return enif_make_badarg(env);
  if (count == 0) return enif_make_tuple2(env, atom_ok, enif_make_list(env, 0));

  ErlNifBinary *bins = (ErlNifBinary *)enif_alloc(sizeof(ErlNifBinary) * count);
  const char **keys = (const char **)enif_alloc(sizeof(char *) * count);
  size_t *key_sizes = (size_t *)enif_alloc(sizeof(size_t) * count);
  ERL_NIF_TERM list = argv[1];
  ERL_NIF_TERM head, tail;
  for (unsigned i = 0; i < count; i++) {
    if (!enif_get_list_cell(env, list, &head, &tail) || !get_binary_arg(env, head, &bins[i])) {
      enif_free(bins);
      enif_free(keys);
      enif_free(key_sizes);
      return enif_make_badarg(env);
    }
    keys[i] = (const char *)bins[i].data;
    key_sizes[i] = bins[i].size;
    list = tail;
  }

  rocksdb_readoptions_t *read_opts = rocksdb_readoptions_create();
  char **values = (char **)enif_alloc(sizeof(char *) * count);
  size_t *value_sizes = (size_t *)enif_alloc(sizeof(size_t) * count);
  char **errs = (char **)enif_alloc(sizeof(char *) * count);
  memset(errs, 0, sizeof(char *) * count);
  rocksdb_multi_get(res->db, read_opts, count, keys, key_sizes, values, value_sizes, errs);
  rocksdb_readoptions_destroy(read_opts);

  for (unsigned i = 0; i < count; i++) {
    if (errs[i] != NULL) {
      ERL_NIF_TERM error = make_error_from_cstr(env, errs[i]);
      for (unsigned j = 0; j < count; j++) {
        if (values[j] != NULL) rocksdb_free(values[j]);
      }
      enif_free(values);
      enif_free(value_sizes);
      enif_free(errs);
      enif_free(bins);
      enif_free(keys);
      enif_free(key_sizes);
      return error;
    }
  }

  ERL_NIF_TERM *terms = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * count);
  for (unsigned i = 0; i < count; i++) {
    if (values[i] == NULL) {
      terms[i] = atom_nil;
    } else {
      ERL_NIF_TERM bin;
      unsigned char *out = enif_make_new_binary(env, value_sizes[i], &bin);
      memcpy(out, values[i], value_sizes[i]);
      rocksdb_free(values[i]);
      terms[i] = enif_make_tuple2(env, atom_ok, bin);
    }
  }

  ERL_NIF_TERM result = enif_make_tuple2(env, atom_ok, enif_make_list_from_array(env, terms, count));
  enif_free(terms);
  enif_free(values);
  enif_free(value_sizes);
  enif_free(errs);
  enif_free(bins);
  enif_free(keys);
  enif_free(key_sizes);
  return result;
}

static ERL_NIF_TERM prefix_scan_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 2) return enif_make_badarg(env);
  db_resource_t *res;
  ErlNifBinary prefix;
  if (!enif_get_resource(env, argv[0], DB_RES, (void **)&res) || !get_binary_arg(env, argv[1], &prefix)) {
    return enif_make_badarg(env);
  }
  if (res->db == NULL) return make_error(env, "rocksdb handle closed");

  rocksdb_readoptions_t *read_opts = rocksdb_readoptions_create();
  rocksdb_iterator_t *it = rocksdb_create_iterator(res->db, read_opts);
  rocksdb_iter_seek(it, (const char *)prefix.data, prefix.size);

  ERL_NIF_TERM list = enif_make_list(env, 0);
  while (rocksdb_iter_valid(it)) {
    size_t key_len = 0;
    const char *key = rocksdb_iter_key(it, &key_len);
    if (key_len < prefix.size || memcmp(key, prefix.data, prefix.size) != 0) break;

    size_t value_len = 0;
    const char *value = rocksdb_iter_value(it, &value_len);
    ERL_NIF_TERM key_bin;
    unsigned char *key_out = enif_make_new_binary(env, key_len, &key_bin);
    memcpy(key_out, key, key_len);
    ERL_NIF_TERM value_bin;
    unsigned char *value_out = enif_make_new_binary(env, value_len, &value_bin);
    memcpy(value_out, value, value_len);
    list = enif_make_list_cell(env, enif_make_tuple2(env, key_bin, value_bin), list);
    rocksdb_iter_next(it);
  }

  char *err = NULL;
  rocksdb_iter_get_error(it, &err);
  rocksdb_iter_destroy(it);
  rocksdb_readoptions_destroy(read_opts);
  if (err != NULL) return make_error_from_cstr(env, err);
  return enif_make_tuple2(env, atom_ok, list);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;
  ErlNifResourceFlags flags =
      (ErlNifResourceFlags)(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
  DB_RES = enif_open_resource_type(env, NULL, "exbitnode_rocksdb_resource", db_dtor, flags, NULL);
  if (DB_RES == NULL) return 1;
  atom_ok = enif_make_atom(env, "ok");
  atom_error = enif_make_atom(env, "error");
  atom_nil = enif_make_atom(env, "nil");
  atom_put = enif_make_atom(env, "put");
  atom_delete = enif_make_atom(env, "delete");
  return 0;
}

static ErlNifFunc funcs[] = {
  {"open", 1, open_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"close", 1, close_nif, 0},
  {"get", 2, get_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"put", 3, put_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"delete", 2, delete_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"write_batch", 2, write_batch_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"multi_get", 2, multi_get_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"prefix_scan", 2, prefix_scan_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(exbitnode_native_rocksdb, funcs, load, NULL, NULL, NULL)
