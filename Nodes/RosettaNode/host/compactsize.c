#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <inttypes.h>
extern int cs_decode(const uint8_t *, uint64_t, uint64_t *, uint64_t *);
extern int cs_encode(uint64_t, uint8_t *, uint64_t, uint64_t *);
static int nibble(char c) {
  if(c>='0'&&c<='9') return c-'0';
  if(c>='a'&&c<='f') return c-'a'+10;
  if(c>='A'&&c<='F') return c-'A'+10;
  return -1;
}
int main(int argc,char **argv) {
  if(argc<3) return 64;
  uint64_t value=123456789, used=987654321;
  int status;
  if(!strcmp(argv[1],"decode")) {
    size_t chars=strlen(argv[2]); if(chars%2||chars>8192) return 64;
    size_t len=chars/2; uint8_t *data=malloc(len?len:1); if(!data) return 70;
    for(size_t i=0;i<len;i++){int a=nibble(argv[2][i*2]), b=nibble(argv[2][i*2+1]);if(a<0||b<0){free(data);return 64;}data[i]=(a<<4)|b;}
    status=cs_decode(data,len,&value,&used); free(data);
    printf("{\"status\":%d,\"value\":\"%" PRIu64 "\",\"consumed\":\"%" PRIu64 "\"}\n",status,value,used);
  } else if(!strcmp(argv[1],"encode")) {
    char *end;errno=0;value=strtoull(argv[2],&end,10);if(errno||*end||argv[2][0]=='-'||!argv[2][0])return 64;
    uint8_t data[9];memset(data,0xa5,sizeof data);uint64_t cap=9;
    if(argc>3){cap=strtoull(argv[3],&end,10);if(*end||cap>9)return 64;}
    status=cs_encode(value,data,cap,&used);
    printf("{\"status\":%d,\"consumed\":\"%" PRIu64 "\",\"bytes\":\"",status,used);
    for(size_t i=0;i<(status?9:used);i++)printf("%02x",data[i]);puts("\"}");
  } else return 64;
  return 0;
}
