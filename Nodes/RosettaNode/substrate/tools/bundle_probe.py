#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import hashlib,json,shutil,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
IMAGE='sha256:cc9b0ebe055af2cf067e3ca206f6d236682c87c48debb5f205d0657dbcc0476e'
def main():
    base=(_rb_paths()['substrate'])/('bundles-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir()
    (base/'go/storage').mkdir(parents=True);shutil.copyfile(ROOT/'bundles/go/storage.go',base/'go/storage/storage.go')
    (base/'go/go.mod').write_text('module bundle\ngo 1.27.1\n')
    (base/'go/main.go').write_text('''package main
import("bundle/storage";"fmt")
func main(){d,e:=storage.Open("/tmp/go-db");if e!=nil{panic(e)};other,e:=storage.Open("/tmp/go-db");if e==nil{other.Close();panic("second writer")};b:=storage.NewBatch();b.Put("key", "value");if e=d.Write(b);e!=nil{panic(e)};b.Close();v,ok,e:=d.Get("key");if e!=nil||!ok||v!="value"{panic("read")};d.Close();d,e=storage.Open("/tmp/go-db");if e!=nil{panic(e)};v,ok,e=d.Get("key");if e!=nil||!ok||v!="value"{panic("recovery")};d.Close();fmt.Println("qualified")}
''')
    (base/'rust').mkdir();shutil.copyfile(ROOT/'bundles/rust/storage.rs',base/'rust/storage.rs')
    (base/'rust/main.rs').write_text('''mod storage;use storage::{DB,Batch};fn main(){let d=DB::open("/tmp/rust-db").unwrap();assert!(DB::open("/tmp/rust-db").is_err());let mut b=Batch::new();b.put(b"key",b"value");d.write(&b).unwrap();assert_eq!(d.get(b"key").unwrap().unwrap(),b"value");drop(d);let d=DB::open("/tmp/rust-db").unwrap();assert_eq!(d.get(b"key").unwrap().unwrap(),b"value");println!("qualified");}
''')
    (base/'zig').mkdir();shutil.copyfile(ROOT/'bundles/zig/storage.zig',base/'zig/storage.zig')
    (base/'zig/main.zig').write_text('''const std=@import("std");const s=@import("storage.zig");pub fn main() !void {var d=try s.DB.open("/tmp/zig-db");if(s.DB.open("/tmp/zig-db")) |v| {var other=v;other.close();return error.SecondWriter;} else |_| {}var b=s.Batch.init();defer b.deinit();b.put("key","value");try d.commit(&b);const v=(try d.get(std.heap.page_allocator,"key")).?;defer std.heap.page_allocator.free(v);try std.testing.expectEqualStrings("value",v);d.close();d=try s.DB.open("/tmp/zig-db");defer d.close();const v2=(try d.get(std.heap.page_allocator,"key")).?;defer std.heap.page_allocator.free(v2);try std.testing.expectEqualStrings("value",v2);}
''')
    commands={'go':'cd go && go build -o check . && ./check','rust':'cd rust && rustc --edition=2024 main.rs -o check && ./check','zig':'cd zig && zig build-exe main.zig -lc -lrocksdb -I/usr/include -L/usr/lib/aarch64-linux-gnu -femit-bin=check && ./check'}
    results=[]
    for lang,command in commands.items():
        start=time.monotonic();p=subprocess.run(['docker','run','--rm','--network','none','--cpus','4','--memory','4g','--label','rosettanode.substrate=preparation','-v',str(base)+':/workspace',IMAGE,'sh','-c',command],capture_output=True,text=True)
        (base/(lang+'.log')).write_text(p.stdout+p.stderr);results.append({'language':lang,'passed':p.returncode==0,'elapsed_build_and_test_seconds':time.monotonic()-start,'source_sha256':hashlib.sha256((ROOT/f'bundles/{lang}'/Path('storage.go' if lang=='go' else 'storage.rs' if lang=='rust' else 'storage.zig')).read_bytes()).hexdigest()})
    result={'schema':'rosettanode.substrate.bundle_probe.v1','status':'passed' if all(r['passed'] for r in results) else 'failed','results':results,'capabilities':['dynamic C API open','synchronous WriteBatch','read','close/reopen','exclusive datadir lock'],'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/bundle-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
