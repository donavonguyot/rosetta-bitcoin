#define _GNU_SOURCE
#include <rocksdb/c.h>
#include "adapter.h"
#include <openssl/sha.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>

/* Diagnostic-only interposer. Never linked into candidate production code. */
static pthread_mutex_t mu=PTHREAD_MUTEX_INITIALIZER;
static struct {const void *ptr; int sync,disable;} opts[1024];
static _Thread_local char transition[128];
static _Thread_local unsigned long callid;
static unsigned long serial;
static void event(const char *phase,const char *path,unsigned long inode,int sync,int wal){
 const char *log=getenv("RN_TRACE"); if(!log)return;
 char out[4096]; struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
 int n=snprintf(out,sizeof out,"{\"phase\":\"%s\",\"transition\":\"%s\",\"call\":%lu,\"tid\":%ld,\"ns\":%llu,\"path\":\"%s\",\"inode\":%lu,\"sync\":%d,\"wal\":%d}\n",phase,transition,callid,syscall(SYS_gettid),(unsigned long long)t.tv_sec*1000000000+t.tv_nsec,path?path:"",inode,sync,wal);
 int fd=open(log,O_WRONLY|O_CREAT|O_APPEND,0600); if(fd>=0){syscall(SYS_write,fd,out,n);close(fd);}
 const char *stop=getenv("RN_BARRIER"),*match=getenv("RN_TRANSITION"),*release=getenv("RN_RELEASE");
 char per_job[1024];const char*directory=getenv("RN_RELEASE_DIR");
 if(directory){char token[128];snprintf(token,sizeof token,"%s",transition);for(char*p=token;*p;p++)if(*p=='/')*p='_';snprintf(per_job,sizeof per_job,"%s/%s",directory,token);release=per_job;}
 if(stop&&release&&!strcmp(stop,phase)&&(!match||!strcmp(match,"*")||!strcmp(match,transition))) {
  event("barrier_held",path,inode,sync,wal);
  while(access(release,F_OK))usleep(1000);
 }
}
static int slot(const void*p){for(int i=0;i<1024;i++)if(opts[i].ptr==p)return i;return -1;}
rocksdb_writeoptions_t *rocksdb_writeoptions_create(void){
 rocksdb_writeoptions_t *(*real)(void)=dlsym(RTLD_NEXT,"rocksdb_writeoptions_create");
 rocksdb_writeoptions_t*p=real();pthread_mutex_lock(&mu);for(int i=0;i<1024;i++)if(!opts[i].ptr){opts[i].ptr=p;opts[i].sync=0;opts[i].disable=0;break;}pthread_mutex_unlock(&mu);return p;
}
void rocksdb_writeoptions_destroy(rocksdb_writeoptions_t*p){
 void(*real)(rocksdb_writeoptions_t*)=dlsym(RTLD_NEXT,"rocksdb_writeoptions_destroy");pthread_mutex_lock(&mu);int i=slot(p);if(i>=0)opts[i].ptr=0;pthread_mutex_unlock(&mu);real(p);
}
void rocksdb_writeoptions_set_sync(rocksdb_writeoptions_t*p,unsigned char value){
 void(*real)(rocksdb_writeoptions_t*,unsigned char)=dlsym(RTLD_NEXT,"rocksdb_writeoptions_set_sync");pthread_mutex_lock(&mu);int i=slot(p);if(i>=0)opts[i].sync=value;pthread_mutex_unlock(&mu);real(p,value);
}
void rocksdb_writeoptions_disable_WAL(rocksdb_writeoptions_t*p,int value){
 void(*real)(rocksdb_writeoptions_t*,int)=dlsym(RTLD_NEXT,"rocksdb_writeoptions_disable_WAL");pthread_mutex_lock(&mu);int i=slot(p);if(i>=0)opts[i].disable=value;pthread_mutex_unlock(&mu);real(p,value);
}
static void putkey(void*ignored,const char*k,size_t n,const char*v,size_t vn){(void)ignored;(void)v;(void)vn;if(n>2&&(!memcmp(k,"p/",2)||!memcmp(k,"r/",2)||!memcmp(k,"c/",2))){size_t size=n<127?n:127;memcpy(transition,k,size);transition[size]=0;event("write_member",0,0,0,0);}}
static void delkey(void*a,const char*k,size_t n){(void)a;(void)k;(void)n;}
void rocksdb_write(rocksdb_t*db,const rocksdb_writeoptions_t*wo,rocksdb_writebatch_t*b,char**err){
 void(*real)(rocksdb_t*,const rocksdb_writeoptions_t*,rocksdb_writebatch_t*,char**)=dlsym(RTLD_NEXT,"rocksdb_write");
 Dl_info identity={0};if(dladdr((void*)real,&identity)&&identity.dli_fname)event("rocksdb_loaded",identity.dli_fname,0,0,0);
 transition[0]=0;pthread_mutex_lock(&mu);callid=++serial;pthread_mutex_unlock(&mu);event("call_entry",0,0,0,0);rocksdb_writebatch_iterate(b,0,putkey,delkey);
 pthread_mutex_lock(&mu);int i=slot(wo),sync=i<0?-1:opts[i].sync,wal=i<0?-1:!opts[i].disable;pthread_mutex_unlock(&mu);
 event("write_enter",0,0,sync,wal);const char*fail=getenv("RN_FAIL_TRANSITION");if(fail&&(!strcmp(fail,"*")||!strcmp(fail,transition))){*err=strdup("injected C write failure");event("write_error",0,0,sync,wal);transition[0]=0;callid=0;return;}real(db,wo,b,err);event(*err?"write_error":"native_success",0,0,sync,wal);transition[0]=0;callid=0;
}
void rocksdb_put(rocksdb_t*db,const rocksdb_writeoptions_t*wo,const char*k,size_t n,const char*v,size_t vn,char**err){
 void(*real)(rocksdb_t*,const rocksdb_writeoptions_t*,const char*,size_t,const char*,size_t,char**)=dlsym(RTLD_NEXT,"rocksdb_put");event("forbidden_standalone_put",0,0,0,0);real(db,wo,k,n,v,vn,err);
}
static int syncfd(int fd,const char*symbol){
 int(*real)(int)=dlsym(RTLD_NEXT,symbol);char link[64],path[1024]={0};snprintf(link,sizeof link,"/proc/self/fd/%d",fd);ssize_t n=readlink(link,path,sizeof(path)-1);if(n<0)path[0]=0;
 struct stat s={0};fstat(fd,&s);size_t len=strlen(path);int wal=len>4&&!strcmp(path+len-4,".log");
 event(wal?"wal_sync_enter":"other_sync_enter",path,s.st_ino,1,wal);int rc=real(fd);event(wal?"wal_sync_exit":"other_sync_exit",path,s.st_ino,rc==0,wal);return rc;
}
int fsync(int fd){return syncfd(fd,"fsync");}
int fdatasync(int fd){return syncfd(fd,"fdatasync");}


static _Thread_local unsigned depth;
static void adapter_enter(const uint8_t*data,uint64_t size,const char*abi){
 unsigned char digest[32];SHA256(data,size,digest);strcpy(transition,"a/");for(int i=0;i<32;i++)sprintf(transition+2+i*2,"%02x",digest[i]);event("adapter_enter",abi,0,0,0);
}
int rn_verify_v1(rn_arena*a,const rn_item_v1*items,uint64_t count,rn_result*out){
 int(*real)(rn_arena*,const rn_item_v1*,uint64_t,rn_result*)=dlsym(RTLD_NEXT,"rn_verify_v1");int outer=depth++==0;if(outer&&count)adapter_enter(items[0].data,items[0].size,"v1");int rc=real(a,items,count,out);if(outer){event("adapter_exit",0,0,0,0);transition[0]=0;}depth--;return rc;
}
int rn_verify_v2(rn_arena*a,const rn_item_v2*items,uint64_t count,rn_result*out,uint64_t*bitmap){
 int(*real)(rn_arena*,const rn_item_v2*,uint64_t,rn_result*,uint64_t*)=dlsym(RTLD_NEXT,"rn_verify_v2");const uint8_t*(*data)(const rn_arena*)=dlsym(RTLD_NEXT,"rn_arena_data");int outer=depth++==0;if(outer&&count)adapter_enter(data(a)+items[0].offset,items[0].size,"v2");int rc=real(a,items,count,out,bitmap);if(outer){event("adapter_exit",0,0,0,0);transition[0]=0;}depth--;return rc;
}

rocksdb_t*rocksdb_open(const rocksdb_options_t*o,const char*name,char**err){
 rocksdb_t*(*real)(const rocksdb_options_t*,const char*,char**)=dlsym(RTLD_NEXT,"rocksdb_open");
 event("option_write_buffer",name,rocksdb_options_get_write_buffer_size((rocksdb_options_t*)o),0,0);
 event("option_write_buffers",name,rocksdb_options_get_max_write_buffer_number((rocksdb_options_t*)o),0,0);
 event("option_background_jobs",name,rocksdb_options_get_max_background_jobs((rocksdb_options_t*)o),0,0);
 event("option_compression",name,rocksdb_options_get_compression((rocksdb_options_t*)o),0,0);
 return real(o,name,err);
}
rocksdb_cache_t*rocksdb_cache_create_lru(size_t capacity){
 rocksdb_cache_t*(*real)(size_t)=dlsym(RTLD_NEXT,"rocksdb_cache_create_lru");event("cache_capacity",0,capacity,0,0);return real(capacity);
}
void rocksdb_close(rocksdb_t*db){
 void(*real)(rocksdb_t*)=dlsym(RTLD_NEXT,"rocksdb_close");const char*path=getenv("RN_STATS");
 if(path){char*stats=rocksdb_property_value(db,"rocksdb.stats");if(stats){int fd=open(path,O_WRONLY|O_CREAT|O_APPEND,0600);if(fd>=0){syscall(SYS_write,fd,stats,strlen(stats));close(fd);}rocksdb_free(stats);}}
 real(db);
}

rn_arena*rn_arena_create(const uint8_t*bytes,uint64_t size){
 rn_arena*(*real)(const uint8_t*,uint64_t)=dlsym(RTLD_NEXT,"rn_arena_create");
 if(getenv("RN_FAIL_ARENA")){event("arena_allocation_failed",0,0,0,0);return NULL;}return real(bytes,size);
}
