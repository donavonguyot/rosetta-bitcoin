#include "adapter.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char**argv){if(argc!=2)return 2;size_t size=strlen(argv[1])/2;unsigned char*b=malloc(size?size:1);for(size_t i=0;i<size;i++){unsigned int v;if(sscanf(argv[1]+2*i,"%2x",&v)!=1)return 2;b[i]=v;}rn_arena*a=rn_arena_create(b,size);free(b);if(!a)return 3;rn_item_v1 item={rn_arena_data(a),size,1,1};rn_result r;
#ifdef USE_AFTER_FREE
 rn_arena_destroy(a);
#endif
 int rc=rn_verify_v1(a,&item,1,&r);printf("%d %llu %llu %llu %llu ",rc,(unsigned long long)r.status,(unsigned long long)r.consumed,(unsigned long long)r.full_size,(unsigned long long)r.stripped_size);for(int i=0;i<32;i++)printf("%02x",r.txid[i]);putchar(' ');for(int i=0;i<32;i++)printf("%02x",r.wtxid[i]);putchar('\n');
#ifndef USE_AFTER_FREE
 rn_arena_destroy(a);
#endif
 return rc?1:0;}
