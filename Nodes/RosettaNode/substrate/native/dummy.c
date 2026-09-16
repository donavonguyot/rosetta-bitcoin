#define _GNU_SOURCE
#include "adapter.h"
#include <rocksdb/c.h>
#include <json-c/json.h>
#include <openssl/sha.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Evaluator control host, excluded from every candidate reuse bundle. */
#define MAX_JOBS 1024
#define MAX_PAYLOAD (64u*1024u*1024u)
#define MAX_LINE (40u*1024u*1024u)
typedef struct Job {char *id,*digest;uint64_t seq,bytes;int priority,started,done,cancel,notify_fd;json_object*payload,*result;struct Job*next;} Job;
static rocksdb_t*db;static rocksdb_writeoptions_t*wo;static rocksdb_readoptions_t*ro;
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;static pthread_cond_t wake=PTHREAD_COND_INITIALIZER;
static uint64_t sequence,checkpoint,outstanding,bytes;static Job*jobs;static int stopping,fatal,cycle,clients,listener;
static const char*S(json_object*j,const char*k){json_object*v=NULL;return json_object_object_get_ex(j,k,&v)?json_object_get_string(v):NULL;}
static uint64_t U(json_object*j,const char*k){const char*s=S(j,k);return s?strtoull(s,NULL,10):0;}
static void field(json_object*j,const char*k,const char*v){json_object_object_add(j,k,json_object_new_string(v));}
static void number(json_object*j,const char*k,uint64_t n){char b[32];snprintf(b,sizeof b,"%llu",(unsigned long long)n);field(j,k,b);}
static char*encode(json_object*j){return strdup(json_object_to_json_string_ext(j,JSON_C_TO_STRING_PLAIN));}
static void bput(rocksdb_writebatch_t*b,const char*k,const char*v){rocksdb_writebatch_put(b,k,strlen(k),v,strlen(v));}
static void bnum(rocksdb_writebatch_t*b,const char*k,uint64_t n){char v[32];snprintf(v,sizeof v,"%llu",(unsigned long long)n);bput(b,k,v);}
static void key(char*out,char kind,uint64_t seq){snprintf(out,64,"%c/%020llu",kind,(unsigned long long)seq);}
static char*get(const char*k){char*err=NULL;size_t n=0;char*v=rocksdb_get(db,ro,k,strlen(k),&n,&err);if(err){fprintf(stderr,"read: %s\n",err);exit(4);}if(!v)return NULL;char*out=strndup(v,n);rocksdb_free(v);return out;}
static int writebatch(rocksdb_writebatch_t*b){char*err=NULL;rocksdb_write(db,wo,b,&err);rocksdb_writebatch_destroy(b);if(err){fprintf(stderr,"write: %s\n",err);rocksdb_free(err);fatal=stopping=1;shutdown(listener,SHUT_RDWR);pthread_cond_broadcast(&wake);return 0;}return 1;}
static json_object*pending(Job*j){json_object*p=json_object_new_object();field(p,"id",j->id);field(p,"digest",j->digest);number(p,"sequence",j->seq);number(p,"bytes",j->bytes);field(p,"priority",j->priority?"high":"normal");json_object_object_add(p,"items",json_object_get(j->payload));return p;}
static void freejob(Job*j){if(j->notify_fd>=0)close(j->notify_fd);free(j->id);free(j->digest);json_object_put(j->payload);if(j->result)json_object_put(j->result);free(j);}
static Job*find(uint64_t seq){for(Job*j=jobs;j;j=j->next)if(j->seq==seq)return j;return NULL;}
static void hex(const unsigned char*in,size_t n,char*out){for(size_t i=0;i<n;i++)sprintf(out+2*i,"%02x",in[i]);out[2*n]=0;}
static int nibble(char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;return -1;}
static json_object*evaluate(json_object*items){
 size_t count=json_object_array_length(items),total=0;for(size_t i=0;i<count;i++)total+=strlen(S(json_object_array_get_idx(items,i),"hex"))/2;
 unsigned char*buffer=malloc(total?total:1);rn_item_v2 desc[64];size_t offset=0;
 if(!buffer)return NULL;
 for(size_t i=0;i<count;i++){json_object*t=json_object_array_get_idx(items,i);const char*s=S(t,"hex");size_t n=strlen(s)/2;for(size_t k=0;k<n;k++)buffer[offset+k]=(nibble(s[k*2])<<4)|nibble(s[k*2+1]);desc[i]=(rn_item_v2){offset,n,!strcmp(S(t,"mode"),"witness"),!strcmp(S(t,"operation"),"exact")};offset+=n;}
 rn_arena*a=rn_arena_create(buffer,total);free(buffer);if(!a)return NULL;rn_result results[64];int rc;
#ifdef ARENA_EARLY_FREE
 rn_arena_destroy(a);
#endif
#ifdef ABI_V2
 uint64_t bitmap=0;rc=rn_verify_v2(a,desc,count,results,&bitmap);
#else
 rn_item_v1 ptr[64];for(size_t i=0;i<count;i++)ptr[i]=(rn_item_v1){rn_arena_data(a)+desc[i].offset,desc[i].size,desc[i].witness,desc[i].exact};rc=rn_verify_v1(a,ptr,count,results);
#endif
#ifndef ARENA_EARLY_FREE
 rn_arena_destroy(a);
#endif
 if(rc)return NULL;json_object*out=json_object_new_array();
 for(size_t i=0;i<count;i++){rn_result*r=&results[i];json_object*o=json_object_new_object();number(o,"status",r->status);number(o,"consumed",r->consumed);number(o,"full_size",r->full_size);number(o,"stripped_size",r->stripped_size);char h[65];hex(r->txid,32,h);field(o,"txid_digest_order",h);hex(r->wtxid,32,h);field(o,"wtxid_digest_order",h);json_object_array_add(out,o);}return out;
}
static Job*dispatch(void){Job*normal=NULL,*high=NULL;for(Job*j=jobs;j;j=j->next)if(!j->started){if(j->priority){if(!high||j->seq<high->seq)high=j;}else if(!normal||j->seq<normal->seq)normal=j;}
#ifdef STARVE_NORMAL
 return high?high:normal;
#else
 if(high&&normal){Job*j=cycle==3?normal:high;cycle=(cycle+1)%4;return j;}return high?high:normal;
#endif
}
static void*worker(void*ignored){(void)ignored;pthread_mutex_lock(&mutex);for(;;){if(fatal)break;Job*j=dispatch();if(!j){if(stopping&&!outstanding)break;pthread_cond_wait(&wake,&mutex);continue;}j->started=1;pthread_mutex_unlock(&mutex);json_object*result=evaluate(j->payload);pthread_mutex_lock(&mutex);if(!result){fatal=stopping=1;shutdown(listener,SHUT_RDWR);pthread_cond_broadcast(&wake);break;}j->result=result;j->done=1;
 while((j=find(checkpoint+1))&&j->done){
  json_object*r=json_object_new_object();field(r,"id",j->id);field(r,"digest",j->digest);number(r,"sequence",j->seq);field(r,"state",j->cancel?"cancelled":"complete");json_object_object_add(r,"results",j->cancel?json_object_new_array():json_object_get(j->result));char*encoded=encode(r);json_object_put(r);
  rocksdb_writebatch_t*b=rocksdb_writebatch_create();char k[64];key(k,'r',j->seq);bput(b,k,encoded);
#ifdef TORN_TERMINAL
  if(!writebatch(b))break;b=rocksdb_writebatch_create();
#endif
  key(k,'p',j->seq);rocksdb_writebatch_delete(b,k,strlen(k));key(k,'c',j->seq);rocksdb_writebatch_delete(b,k,strlen(k));bnum(b,"meta/checkpoint",j->seq);bnum(b,"meta/jobs",outstanding-1);bnum(b,"meta/bytes",bytes-j->bytes);
  if(!writebatch(b)){free(encoded);break;}
  if(j->notify_fd>=0){json_object*notification=json_object_new_object();field(notification,"event","terminal");field(notification,"id",j->id);json_object_object_add(notification,"job",json_tokener_parse(encoded));char*wire=encode(notification);json_object_put(notification);size_t n=strlen(wire);char*line=malloc(n+2);if(line){memcpy(line,wire,n);line[n]='\n';size_t sent=0;while(sent<n+1){ssize_t rc=send(j->notify_fd,line+sent,n+1-sent,MSG_NOSIGNAL);if(rc<=0)break;sent+=rc;}free(line);}free(wire);}free(encoded);checkpoint=j->seq;outstanding--;bytes-=j->bytes;Job**link=&jobs;while(*link!=j)link=&(*link)->next;*link=j->next;freejob(j);pthread_cond_broadcast(&wake);
 }if(fatal)break;
 }pthread_mutex_unlock(&mutex);return NULL;}
static int validid(const char*s){if(!s||!*s||strlen(s)>64)return 0;for(;*s;s++)if(!((*s>='a'&&*s<='z')||(*s>='A'&&*s<='Z')||(*s>='0'&&*s<='9')||*s=='_'||*s=='-'))return 0;return 1;}
static int payload(json_object*req,json_object**items,uint64_t*size,char digest[65]){
 if(!json_object_object_get_ex(req,"items",items)||!json_object_is_type(*items,json_type_array))return 0;size_t count=json_object_array_length(*items);if(!count||count>64)return 0;*size=0;SHA256_CTX hash;SHA256_Init(&hash);
 for(size_t i=0;i<count;i++){json_object*t=json_object_array_get_idx(*items,i);const char*h=S(t,"hex"),*mode=S(t,"mode"),*op=S(t,"operation");if(!h||strlen(h)%2||!mode||!op|| (strcmp(mode,"witness")&&strcmp(mode,"legacy"))||(strcmp(op,"exact")&&strcmp(op,"prefix")))return 0;size_t n=strlen(h)/2;if(n>RN_MAX_INPUT-*size)return 0;*size+=n;for(size_t x=0;x<2*n;x++)if(nibble(h[x])<0)return 0;
  unsigned char flags[2]={!strcmp(mode,"witness"),!strcmp(op,"exact")},len[8];for(int k=0;k<8;k++)len[k]=(n>>(8*k))&255;SHA256_Update(&hash,flags,2);SHA256_Update(&hash,len,8);for(size_t x=0;x<n;x++){unsigned char b=(nibble(h[2*x])<<4)|nibble(h[2*x+1]);SHA256_Update(&hash,&b,1);}
 }unsigned char sum[32];SHA256_Final(sum,&hash);hex(sum,32,digest);return 1;
}
static json_object*response(json_object*q,const char*status){json_object*r=json_object_new_object();field(r,"request",S(q,"request")?S(q,"request"):"");field(r,"status",status);return r;}
static json_object*handle(json_object*q,FILE*f){
 const char*op=S(q,"op"),*id=S(q,"id");if(!op)return response(q,"invalid_request");
 if(!strcmp(op,"shutdown")){stopping=1;pthread_cond_broadcast(&wake);shutdown(listener,SHUT_RDWR);return response(q,"draining");}
 if(!strcmp(op,"evaluate")){json_object*items;uint64_t size;char digest[65];if(!payload(q,&items,&size,digest))return response(q,"invalid_request");json_object*results=evaluate(items);json_object*r=response(q,results?"ok":"execution_failure");if(results)json_object_object_add(r,"results",results);return r;}
 if(!validid(id))return response(q,"invalid_request");char index[80];snprintf(index,sizeof index,"id/%s",id);char*stored=get(index);uint64_t seq=stored?strtoull(stored,NULL,10):0;free(stored);Job*j=seq?find(seq):NULL;char k[64];key(k,'r',seq);char*receipt=seq?get(k):NULL;
 if(!strcmp(op,"submit")){
  json_object*items;uint64_t size;char digest[65];if(!payload(q,&items,&size,digest)){free(receipt);return response(q,"invalid_request");}
  if(seq){const char*old=j?j->digest:NULL;json_object*r=receipt?json_tokener_parse(receipt):NULL;if(r)old=S(r,"digest");int same=old&&!strcmp(old,digest);
#ifdef ID_CONFLICT
   same=1;
#endif
   json_object*out=response(q,same?"existing":"conflict");number(out,"sequence",seq);if(r)json_object_put(r);free(receipt);return out;
  }
  if(stopping)return response(q,"draining");if(outstanding>=MAX_JOBS||size>MAX_PAYLOAD-bytes)return response(q,"backpressure");
  j=calloc(1,sizeof(*j));if(!j)return response(q,"execution_failure");j->notify_fd=dup(fileno(f));j->id=strdup(id);j->digest=strdup(digest);j->seq=sequence+1;j->bytes=size;j->payload=json_object_get(items);
#ifdef ABI_V2
  j->priority=S(q,"priority")&&!strcmp(S(q,"priority"),"high");
#endif
  json_object*p=pending(j);char*encoded=encode(p);json_object_put(p);rocksdb_writebatch_t*b=rocksdb_writebatch_create();key(k,'p',j->seq);bput(b,k,encoded);free(encoded);
#ifdef EARLY_ACK
  json_object*early=response(q,"accepted");number(early,"sequence",j->seq);fprintf(f,"%s\n",json_object_to_json_string_ext(early,JSON_C_TO_STRING_PLAIN));fflush(f);json_object_put(early);
#else
  (void)f;
#endif
#ifdef TORN_ADMIT
  if(!writebatch(b)){freejob(j);return response(q,"execution_failure");}b=rocksdb_writebatch_create();
#endif
  bnum(b,index,j->seq);bnum(b,"meta/sequence",j->seq);bnum(b,"meta/jobs",outstanding+1);bnum(b,"meta/bytes",bytes+size);
  if(!writebatch(b)){freejob(j);return response(q,"execution_failure");}sequence=j->seq;outstanding++;bytes+=size;j->next=jobs;jobs=j;pthread_cond_broadcast(&wake);json_object*r=response(q,"accepted");number(r,"sequence",j->seq);return r;
 }
 if(!seq){free(receipt);return response(q,"not_found");}
 if(!strcmp(op,"status")){json_object*r=response(q,"ok");if(receipt)json_object_object_add(r,"job",json_tokener_parse(receipt));else{json_object*p=pending(j);field(p,"state",j->cancel?"cancel_pending":"pending");json_object_object_add(r,"job",p);}free(receipt);return r;}
 if(!strcmp(op,"cancel")){
  if(receipt){free(receipt);
#ifdef LATE_CANCEL
   return response(q,"ok");
#else
   return response(q,"too_late");
#endif
  }if(j->cancel)return response(q,"ok");rocksdb_writebatch_t*b=rocksdb_writebatch_create();key(k,'c',seq);bput(b,k,"1");if(!writebatch(b))return response(q,"execution_failure");j->cancel=1;return response(q,"ok");
 }free(receipt);return response(q,"invalid_request");
}
static void*client(void*arg){int fd=(int)(intptr_t)arg;FILE*f=fdopen(fd,"r+");char*line=malloc(MAX_LINE+2);if(!line){fclose(f);pthread_mutex_lock(&mutex);clients--;pthread_cond_broadcast(&wake);pthread_mutex_unlock(&mutex);return NULL;}
 for(;;){if(!fgets(line,MAX_LINE+2,f))break;size_t n=strlen(line);if(n>MAX_LINE||!n||line[n-1]!='\n')break;json_object*q=json_tokener_parse(line);if(!q)break;pthread_mutex_lock(&mutex);json_object*r=handle(q,f);fprintf(f,"%s\n",json_object_to_json_string_ext(r,JSON_C_TO_STRING_PLAIN));fflush(f);pthread_mutex_unlock(&mutex);json_object_put(r);json_object_put(q);if(stopping)break;}
 free(line);fclose(f);pthread_mutex_lock(&mutex);clients--;pthread_cond_broadcast(&wake);pthread_mutex_unlock(&mutex);return NULL;
}
static uint64_t meta(const char*k){char*v=get(k);uint64_t n=v?strtoull(v,NULL,10):0;free(v);return n;}
int main(int argc,char**argv){if(argc!=3)return 2;signal(SIGPIPE,SIG_IGN);
 rocksdb_options_t*o=rocksdb_options_create();rocksdb_options_set_create_if_missing(o,1);rocksdb_options_set_compression(o,0);rocksdb_options_set_write_buffer_size(o,64*1024*1024);rocksdb_options_set_max_write_buffer_number(o,2);rocksdb_options_set_max_background_jobs(o,2);rocksdb_cache_t*cache=rocksdb_cache_create_lru(128*1024*1024);rocksdb_block_based_table_options_t*table=rocksdb_block_based_options_create();rocksdb_block_based_options_set_block_cache(table,cache);rocksdb_options_set_block_based_table_factory(o,table);
 char*err=NULL;db=rocksdb_open(o,argv[1],&err);if(err){fprintf(stderr,"%s\n",err);return 3;}wo=rocksdb_writeoptions_create();rocksdb_writeoptions_set_sync(wo,1);rocksdb_writeoptions_disable_WAL(wo,0);ro=rocksdb_readoptions_create();char*version=get("meta/version");if(version&&strcmp(version,"1")){fprintf(stderr,"incompatible schema version\n");return 5;}
 if(!version){rocksdb_writebatch_t*b=rocksdb_writebatch_create();bput(b,"meta/version","1");if(!writebatch(b))return 4;}free(version);sequence=meta("meta/sequence");checkpoint=meta("meta/checkpoint");outstanding=meta("meta/jobs");bytes=meta("meta/bytes");
 for(uint64_t seq=checkpoint+1;seq<=sequence;seq++){char k[64];key(k,'p',seq);char*v=get(k);if(!v)return 6;json_object*p=json_tokener_parse(v);free(v);if(!p)return 6;Job*j=calloc(1,sizeof(*j));j->notify_fd=-1;j->seq=seq;j->id=strdup(S(p,"id"));j->digest=strdup(S(p,"digest"));j->bytes=U(p,"bytes");j->priority=S(p,"priority")&&!strcmp(S(p,"priority"),"high");json_object_object_get_ex(p,"items",&j->payload);json_object_get(j->payload);json_object_put(p);key(k,'c',seq);v=get(k);j->cancel=v!=NULL;free(v);j->next=jobs;jobs=j;}
 listener=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un a={.sun_family=AF_UNIX};if(strlen(argv[2])>=sizeof a.sun_path)return 2;strcpy(a.sun_path,argv[2]);unlink(argv[2]);if(bind(listener,(void*)&a,sizeof a)||listen(listener,8))return 7;
 pthread_t workers[4];for(int i=0;i<4;i++)pthread_create(&workers[i],NULL,worker,NULL);
 for(;;){int fd=accept(listener,NULL,NULL);if(fd<0)break;pthread_mutex_lock(&mutex);if(clients>=8){close(fd);pthread_mutex_unlock(&mutex);continue;}clients++;pthread_mutex_unlock(&mutex);struct timeval timeout={15,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof timeout);pthread_t t;pthread_create(&t,NULL,client,(void*)(intptr_t)fd);pthread_detach(t);}
 pthread_mutex_lock(&mutex);stopping=1;pthread_cond_broadcast(&wake);while(clients)pthread_cond_wait(&wake,&mutex);pthread_mutex_unlock(&mutex);for(int i=0;i<4;i++)pthread_join(workers[i],NULL);close(listener);unlink(argv[2]);rocksdb_close(db);rocksdb_readoptions_destroy(ro);rocksdb_writeoptions_destroy(wo);rocksdb_options_destroy(o);rocksdb_block_based_options_destroy(table);rocksdb_cache_destroy(cache);return fatal?4:0;
}
