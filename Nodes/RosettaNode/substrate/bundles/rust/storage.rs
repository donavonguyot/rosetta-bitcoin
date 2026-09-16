//! Dynamic C API infrastructure; no service or journal policy.
use std::ffi::{c_char,c_int,c_void,CStr,CString};
type Ptr=*mut c_void;
#[link(name="rocksdb")]
unsafe extern "C" {
 fn rocksdb_options_create()->Ptr; fn rocksdb_options_destroy(p:Ptr);
 fn rocksdb_options_set_create_if_missing(p:Ptr,v:u8); fn rocksdb_options_set_compression(p:Ptr,v:c_int);
 fn rocksdb_options_set_write_buffer_size(p:Ptr,v:usize); fn rocksdb_options_set_max_write_buffer_number(p:Ptr,v:c_int); fn rocksdb_options_set_max_background_jobs(p:Ptr,v:c_int);
 fn rocksdb_cache_create_lru(n:usize)->Ptr; fn rocksdb_cache_destroy(p:Ptr);
 fn rocksdb_block_based_options_create()->Ptr;fn rocksdb_block_based_options_destroy(p:Ptr);fn rocksdb_block_based_options_set_block_cache(p:Ptr,c:Ptr);fn rocksdb_options_set_block_based_table_factory(p:Ptr,t:Ptr);
 fn rocksdb_open(o:Ptr,path:*const c_char,e:*mut *mut c_char)->Ptr; fn rocksdb_close(d:Ptr);
 fn rocksdb_writeoptions_create()->Ptr;fn rocksdb_writeoptions_destroy(p:Ptr);fn rocksdb_writeoptions_set_sync(p:Ptr,v:u8);fn rocksdb_writeoptions_disable_WAL(p:Ptr,v:c_int);
 fn rocksdb_readoptions_create()->Ptr;fn rocksdb_readoptions_destroy(p:Ptr);
 fn rocksdb_writebatch_create()->Ptr;fn rocksdb_writebatch_destroy(p:Ptr);fn rocksdb_writebatch_put(b:Ptr,k:*const c_char,kn:usize,v:*const c_char,vn:usize);fn rocksdb_writebatch_delete(b:Ptr,k:*const c_char,kn:usize);
 fn rocksdb_write(d:Ptr,o:Ptr,b:Ptr,e:*mut *mut c_char);fn rocksdb_get(d:Ptr,o:Ptr,k:*const c_char,n:usize,len:*mut usize,e:*mut *mut c_char)->*mut c_char;fn rocksdb_free(p:Ptr);
}
unsafe fn error(p:*mut c_char)->Result<(),String>{if p.is_null(){return Ok(())}let s=unsafe{CStr::from_ptr(p)}.to_string_lossy().into_owned();unsafe{rocksdb_free(p.cast())};Err(s)}
pub struct DB {db:Ptr,o:Ptr,w:Ptr,r:Ptr,cache:Ptr,table:Ptr}
pub struct Batch(Ptr);
impl DB {
 pub fn open(path:&str)->Result<Self,String>{let path=CString::new(path).map_err(|e|e.to_string())?;unsafe{
  let mut s=Self{db:std::ptr::null_mut(),o:rocksdb_options_create(),w:rocksdb_writeoptions_create(),r:rocksdb_readoptions_create(),cache:rocksdb_cache_create_lru(128<<20),table:rocksdb_block_based_options_create()};
  rocksdb_options_set_create_if_missing(s.o,1);rocksdb_options_set_compression(s.o,0);rocksdb_options_set_write_buffer_size(s.o,64<<20);rocksdb_options_set_max_write_buffer_number(s.o,2);rocksdb_options_set_max_background_jobs(s.o,2);rocksdb_block_based_options_set_block_cache(s.table,s.cache);rocksdb_options_set_block_based_table_factory(s.o,s.table);rocksdb_writeoptions_set_sync(s.w,1);rocksdb_writeoptions_disable_WAL(s.w,0);
  let mut e=std::ptr::null_mut();s.db=rocksdb_open(s.o,path.as_ptr(),&mut e);error(e)?;Ok(s)
 }}
 pub fn write(&self,b:&Batch)->Result<(),String>{unsafe{let mut e=std::ptr::null_mut();rocksdb_write(self.db,self.w,b.0,&mut e);error(e)}}
 pub fn get(&self,key:&[u8])->Result<Option<Vec<u8>>,String>{unsafe{let mut e=std::ptr::null_mut();let mut n=0;let p=rocksdb_get(self.db,self.r,key.as_ptr().cast(),key.len(),&mut n,&mut e);error(e)?;if p.is_null(){return Ok(None)}let value=std::slice::from_raw_parts(p.cast::<u8>(),n).to_vec();rocksdb_free(p.cast());Ok(Some(value))}}
}
impl Drop for DB{fn drop(&mut self){unsafe{if !self.db.is_null(){rocksdb_close(self.db)}rocksdb_writeoptions_destroy(self.w);rocksdb_readoptions_destroy(self.r);rocksdb_options_destroy(self.o);rocksdb_block_based_options_destroy(self.table);rocksdb_cache_destroy(self.cache)}}}
impl Batch{
 pub fn new()->Self{Self(unsafe{rocksdb_writebatch_create()})}
 pub fn put(&mut self,key:&[u8],value:&[u8]){unsafe{rocksdb_writebatch_put(self.0,key.as_ptr().cast(),key.len(),value.as_ptr().cast(),value.len())}}
 pub fn delete(&mut self,key:&[u8]){unsafe{rocksdb_writebatch_delete(self.0,key.as_ptr().cast(),key.len())}}
}
impl Drop for Batch{fn drop(&mut self){unsafe{rocksdb_writebatch_destroy(self.0)}}}
// Raw pointers deliberately do not carry a Send/Sync assertion. Candidates must
// choose and justify the ownership/concurrency discipline of their service.
