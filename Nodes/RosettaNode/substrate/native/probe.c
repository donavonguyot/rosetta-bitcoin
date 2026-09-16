#include <rocksdb/c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void put(rocksdb_writebatch_t*b,const char*k,const char*v){rocksdb_writebatch_put(b,k,strlen(k),v,strlen(v));}
int main(int argc,char**argv){
 if(argc!=3)return 2;
 rocksdb_options_t*o=rocksdb_options_create();rocksdb_options_set_create_if_missing(o,1);rocksdb_options_set_compression(o,0);
 rocksdb_options_set_write_buffer_size(o,64*1024*1024);rocksdb_options_set_max_write_buffer_number(o,2);rocksdb_options_set_max_background_jobs(o,2);
 char*err=0;rocksdb_t*d=rocksdb_open(o,argv[1],&err);if(err){fprintf(stderr,"%s\n",err);return 3;}
 rocksdb_writeoptions_t*w=rocksdb_writeoptions_create();rocksdb_writeoptions_set_sync(w,1);rocksdb_writeoptions_disable_WAL(w,0);
 rocksdb_writebatch_t*b=rocksdb_writebatch_create();
 if(!strcmp(argv[2],"admit")){
  put(b,"p/1","payload");
#ifdef EARLY_ACK
  puts("ACK 1");fflush(stdout);
#endif
#ifdef TORN_ADMIT
  rocksdb_write(d,w,b,&err);if(err)return 4;rocksdb_writebatch_clear(b);
#endif
  put(b,"m/sequence","1");put(b,"m/version","1");put(b,"m/outstanding","1");
 }else if(!strcmp(argv[2],"terminal")){
  put(b,"r/1","ok");
#ifdef TORN_TERMINAL
  rocksdb_write(d,w,b,&err);if(err)return 4;rocksdb_writebatch_clear(b);
#endif
  rocksdb_writebatch_delete(b,"p/1",3);put(b,"m/checkpoint","1");put(b,"m/outstanding","0");
 }else return 2;
 rocksdb_write(d,w,b,&err);if(err){fprintf(stderr,"%s\n",err);return 4;}
#ifndef EARLY_ACK
 puts("ACK 1");fflush(stdout);
#endif
 rocksdb_writebatch_destroy(b);rocksdb_writeoptions_destroy(w);rocksdb_close(d);rocksdb_options_destroy(o);return 0;
}
