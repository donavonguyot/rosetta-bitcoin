"""Independent durable-state model; contains no candidate scheduler or DB writer."""
import hashlib,json

def request_digest(items):
    h=hashlib.sha256()
    for item in items:
        raw=bytes.fromhex(item['hex']);h.update(bytes([item['mode']=='witness',item['operation']=='exact']));h.update(len(raw).to_bytes(8,'little'));h.update(raw)
    return h.hexdigest()

def check(rows,acknowledged=None,cancelled=()):
    try:
        if rows.get('meta/version')!='1':return 'unsupported_schema'
        sequence=int(rows.get('meta/sequence','0'));cp=int(rows.get('meta/checkpoint','0'))
        if not 0<=cp<=sequence<=len(rows):return 'checkpoint_out_of_range'
        pending={k:json.loads(v) for k,v in rows.items() if k.startswith('p/')};receipts={k:json.loads(v) for k,v in rows.items() if k.startswith('r/')}
        if set(pending)!={f'p/{n:020}' for n in range(cp+1,sequence+1)}:return 'pending_sequence_mismatch'
        if set(receipts)!={f'r/{n:020}' for n in range(1,cp+1)}:return 'receipt_checkpoint_mismatch'
        indexes={};total=0;alljobs={}
        for k,j in [*pending.items(),*receipts.items()]:
            seq=int(k[2:]);identifier=j['id']
            if identifier in alljobs:return 'duplicate_id'
            alljobs[identifier]=j;indexes['id/'+identifier]=str(seq)
            if j['sequence']!=str(seq):return 'record_sequence_mismatch'
            if k.startswith('p/'):
                size=sum(len(bytes.fromhex(i['hex'])) for i in j['items'])
                if int(j['bytes'])!=size:return 'payload_bytes_mismatch'
                if j['digest']!=request_digest(j['items']):return 'payload_digest_mismatch'
                if j['priority'] not in ['normal','high']:return 'invalid_priority'
                total+=size
            elif j['state'] not in ['complete','cancelled']:return 'invalid_receipt_state'
        if {k:v for k,v in rows.items() if k.startswith('id/')}!=indexes:return 'id_sequence_mismatch'
        if len(pending)!=int(rows.get('meta/jobs','0')) or len(pending)>1024:return 'outstanding_jobs_mismatch'
        if total!=int(rows.get('meta/bytes','0')) or total>64*1024*1024:return 'outstanding_bytes_mismatch'
        for k,v in rows.items():
            if k.startswith('c/') and (v!='1' or 'p/'+k[2:] not in pending):return 'invalid_cancel_intent'
            if k.startswith('meta/') and k not in ['meta/version','meta/sequence','meta/checkpoint','meta/jobs','meta/bytes']:return 'unknown_metadata_key'
            if not k.startswith(('meta/','p/','r/','id/','c/')):return 'unknown_disk_key'
        for identifier,expected in (acknowledged or {}).items():
            if identifier not in alljobs:return 'acknowledged_job_missing'
            j=alljobs[identifier]
            if j['digest']!=request_digest(expected['items']):return 'acknowledged_payload_changed'
            if j.get('state')=='complete' and 'results' in expected and j['results']!=expected['results']:return 'receipt_results_mismatch'
        for identifier in cancelled:
            if identifier not in alljobs:return 'cancelled_job_missing'
            j=alljobs[identifier]
            if j.get('state')=='complete':return 'accepted_cancellation_ignored'
            if 'state' not in j and rows.get('c/'+f"{int(j['sequence']):020}")!='1':return 'accepted_cancellation_lost'
        return None
    except (KeyError,TypeError,ValueError,OverflowError):return 'malformed_disk_record'
