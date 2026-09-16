"""Evaluator-owned Unix transport proxy with observable response loss.

The candidate never receives fault-control messages. A dropped response becomes
an evaluator transport envelope, not a candidate protocol response. This permits
bounded deterministic retries without pretending the lost ack was delivered.
"""
import json,socket,threading,time
from pathlib import Path
class Proxy:
    def __init__(self,front,backend,drop_ids=()):
        self.path=Path(front);self.backend=str(backend);self.drop=set(drop_ids);self.events=[];self.lock=threading.Lock();self.connections=[];self.closed=False
        self.listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.listener.bind(str(front));self.listener.listen(8);self.listener.settimeout(.1)
        self.thread=threading.Thread(target=self.accept,daemon=True);self.thread.start()
    def accept(self):
        while not self.closed:
            try:client,_=self.listener.accept()
            except socket.timeout:continue
            except OSError:return
            backend=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);backend.connect(self.backend)
            self.connections.extend([client,backend]);pending={};lock=threading.Lock()
            def requests(client=client,backend=backend,pending=pending,lock=lock):
                try:
                    with client.makefile('rb') as stream:
                        while line:=stream.readline(40*1024*1024+1):
                            if len(line)>40*1024*1024:break
                            q=json.loads(line)
                            with lock:pending[q.get('request')]=q
                            backend.sendall(line)
                except (OSError,ValueError):pass
                finally:
                    try:backend.shutdown(socket.SHUT_WR)
                    except OSError:pass
            def responses(client=client,backend=backend,pending=pending,lock=lock):
                try:
                    with backend.makefile('rb') as stream:
                        while line:=stream.readline(40*1024*1024+1):
                            r=json.loads(line)
                            with lock:q=pending.pop(r.get('request'),{}) if 'event' not in r else {}
                            with self.lock:
                                drop=q.get('op')=='submit' and q.get('id') in self.drop and r.get('status') in ['accepted','existing']
                                if drop:
                                    self.drop.remove(q['id']);self.events.append({'kind':'ack_dropped','id':q['id'],'request':q['request'],'ns':time.monotonic_ns()})
                            if drop:line=json.dumps({'request':q['request'],'transport_outcome':'response_lost'}).encode()+b'\n'
                            client.sendall(line)
                except (OSError,ValueError):pass
                finally:
                    try:client.shutdown(socket.SHUT_WR)
                    except OSError:pass
            threading.Thread(target=requests,daemon=True).start();threading.Thread(target=responses,daemon=True).start()
    def close(self):
        self.closed=True;self.listener.close()
        for s in self.connections:
            try:s.shutdown(socket.SHUT_RDWR)
            except OSError:pass
            s.close()
        self.thread.join(timeout=2)
        self.path.unlink(missing_ok=True)
