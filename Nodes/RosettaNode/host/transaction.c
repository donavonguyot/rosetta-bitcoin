#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
struct Scan {void *data; uint64_t len,pos,error,items; void *events; uint64_t used;};
struct Write {void *out; uint64_t cap,pos,error;};
extern uint64_t tx_scan(struct Scan *,bool,bool,uint64_t);
extern uint64_t tx_serialize(void *,uint64_t,void *,bool,struct Write *);
extern int tx_digest(void *,uint64_t,void *);
static void *unhex(const char *hex,size_t *n) {
    size_t length=strlen(hex);if(length%2||length>16*1024*1024)return NULL;
    *n=length/2;unsigned char *b=malloc(*n?*n:1);if(!b)return NULL;
    for(size_t i=0;i<*n;i++){
        unsigned int byte;char pair[3]={hex[i*2],hex[i*2+1],0};
        if(strspn(pair,"0123456789abcdefABCDEF")!=2||sscanf(pair,"%2x",&byte)!=1){free(b);return NULL;}b[i]=(unsigned char)byte;
    }return b;
}
static void hexout(void *p,size_t n){unsigned char *b=p;for(size_t i=0;i<n;i++)printf("%02x",b[i]);}
int main(int argc,char **argv){
    if(argc<3)return 2;size_t n=0;void *data=unhex(argv[2],&n);if(!data)return 2;
    if(!strcmp(argv[1],"scan")&&argc==6){
        if(n>4*1024*1024){free(data);return 2;}
        struct Scan s={data,n,0,0,0,NULL,0};bool witness=atoi(argv[3])!=0,exact=atoi(argv[4])!=0;uint64_t budget=strtoull(argv[5],NULL,10);
        uint64_t status=tx_scan(&s,witness,exact,budget);
        if(status){printf("%llu\n",(unsigned long long)status);free(data);return 0;}
        size_t count=(size_t)s.used;void *events=calloc(count,32);if(!events){free(data);return 3;}
        s=(struct Scan){data,n,0,0,0,events,0};status=tx_scan(&s,witness,exact,budget);
        printf("%llu %llu %llu ",(unsigned long long)status,(unsigned long long)s.pos,(unsigned long long)s.items);hexout(events,count*32);puts("");free(events);
    }else if(!strcmp(argv[1],"serialize")&&argc==5){
        size_t length=0;void *events=unhex(argv[3],&length);if(!events||length%32){free(events);free(data);return 2;}
        bool include=atoi(argv[4])!=0;struct Write w={NULL,4*1024*1024,0,0};uint64_t status=tx_serialize(events,length/32,data,include,&w);
        if(status){printf("%llu\n",(unsigned long long)status);free(events);free(data);return 0;}
        size_t size=(size_t)w.pos;void *out=malloc(size?size:1);if(!out){free(events);free(data);return 3;}
        w=(struct Write){out,size,0,0};status=tx_serialize(events,length/32,data,include,&w);printf("%llu ",(unsigned long long)status);hexout(out,size);
        unsigned char digest[32]={0};int hashed=tx_digest(out,size,digest);printf(" %d ",hashed);hexout(digest,32);puts("");free(out);free(events);
    }else{free(data);return 2;}free(data);return 0;
}
