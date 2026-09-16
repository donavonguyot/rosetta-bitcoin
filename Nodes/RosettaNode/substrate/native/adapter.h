#ifndef RN_ADAPTER_H
#define RN_ADAPTER_H
#include <stdint.h>
#include <stddef.h>
#define RN_MAX_BATCH 64
#define RN_MAX_INPUT (16u*1024u*1024u)
typedef struct rn_arena rn_arena;
typedef struct {const uint8_t *data;uint64_t size;uint32_t witness;uint32_t exact;} rn_item_v1;
typedef struct {uint64_t offset,size;uint32_t witness,exact;} rn_item_v2;
typedef struct {uint64_t status,consumed,full_size,stripped_size;uint8_t txid[32],wtxid[32];} rn_result;
/* Arena ownership belongs to the caller; release only after all verify calls return.
   Results are caller-owned. Pointers in v1 must refer to the arena's immutable input. */
rn_arena *rn_arena_create(const uint8_t *bytes,uint64_t size);
const uint8_t *rn_arena_data(const rn_arena *arena);
void rn_arena_destroy(rn_arena *arena);
int rn_verify_v1(rn_arena *arena,const rn_item_v1 *items,uint64_t count,rn_result *out);
int rn_verify_v2(rn_arena *arena,const rn_item_v2 *items,uint64_t count,rn_result *out,uint64_t *ok_bitmap);
const char *rn_abi_fingerprint(void);
#endif
