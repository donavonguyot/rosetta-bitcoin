#include "adapter.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
struct rn_arena {uint64_t size;uint8_t data[];};
struct Scan {void *data;uint64_t len,pos,error,items;void *events;uint64_t used;};
struct Write {void *out;uint64_t cap,pos,error;};
extern uint64_t tx_scan(struct Scan*,bool,bool,uint64_t);
extern uint64_t tx_serialize(void*,uint64_t,void*,bool,struct Write*);
extern int tx_digest(void*,uint64_t,void*);
rn_arena *rn_arena_create(const uint8_t *bytes,uint64_t size){if(size>RN_MAX_INPUT||(!bytes&&size))return NULL;rn_arena*a=malloc(sizeof(*a)+size);if(!a)return NULL;a->size=size;if(size)memcpy(a->data,bytes,size);return a;}
const uint8_t *rn_arena_data(const rn_arena*a){return a?a->data:NULL;}
void rn_arena_destroy(rn_arena*a){free(a);}
const char *rn_abi_fingerprint(void){return "rn.encoding.batch.v1-v2/aarch64/u64-status/opaque-arena/2026-09-16";}
static void one(const uint8_t*bytes,uint64_t n,int witness,int exact,rn_result*out){
 memset(out,0,sizeof(*out));if(n>4*1024*1024){out->status=3;return;}
 struct Scan s={(void*)bytes,n,0,0,0,NULL,0};out->status=tx_scan(&s,witness,exact,4096);if(out->status)return;
 uint64_t used=s.used;void*events=calloc(used,32);if(!events){out->status=4;return;}
 s=(struct Scan){(void*)bytes,n,0,0,0,events,0};out->status=tx_scan(&s,witness,exact,4096);
 if(out->status||s.used!=used){out->status=4;free(events);return;}out->consumed=s.pos;
 for(int include=0;include<2;include++){
  struct Write w={NULL,4*1024*1024,0,0};if(tx_serialize(events,used,(void*)bytes,include,&w)){out->status=2;break;}
  uint64_t size=w.pos;uint8_t*data=malloc(size?size:1);if(!data){out->status=4;break;}
  w=(struct Write){data,size,0,0};if(tx_serialize(events,used,(void*)bytes,include,&w)||w.pos!=size||tx_digest(data,size,include?out->wtxid:out->txid)!=1)out->status=4;
  if(include)out->full_size=size;else out->stripped_size=size;free(data);if(out->status)break;
 }free(events);
 if(out->status){uint64_t status=out->status;memset(out,0,sizeof(*out));out->status=status;}
}
int rn_verify_v1(rn_arena*a,const rn_item_v1*items,uint64_t count,rn_result*out){
 if(!a||!items||!out||count>64)return -1;
 uint64_t total=0;for(uint64_t i=0;i<count;i++){
  uintptr_t begin=(uintptr_t)a->data,p=(uintptr_t)items[i].data;
  if(p<begin||p-begin>a->size||items[i].size>a->size-(p-begin)||items[i].size>RN_MAX_INPUT-total||items[i].witness>1||items[i].exact>1)return -1;total+=items[i].size;
 }
 for(uint64_t i=0;i<count;i++)one(items[i].data,items[i].size,items[i].witness,items[i].exact,&out[i]);return 0;
}
int rn_verify_v2(rn_arena*a,const rn_item_v2*items,uint64_t count,rn_result*out,uint64_t*bitmap){
 if(!a||!items||!out||!bitmap||count>64)return -1;rn_item_v1 pointers[64];
 for(uint64_t i=0;i<count;i++){if(items[i].offset>a->size||items[i].size>a->size-items[i].offset)return -1;pointers[i]=(rn_item_v1){a->data+items[i].offset,items[i].size,items[i].witness,items[i].exact};}
 int rc=rn_verify_v1(a,pointers,count,out);*bitmap=0;if(!rc)for(uint64_t i=0;i<count;i++)if(!out[i].status)*bitmap|=UINT64_C(1)<<i;return rc;
}
