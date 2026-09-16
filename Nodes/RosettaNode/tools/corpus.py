"""Independent synthetic expectations; hidden challenge variants, never packet examples."""
import copy
from chain_checker import serialize,digest

def structure(witness=None):
    return {'version_bits':'2147483651','inputs':[{'previous_txid_digest_order':'93'*32,'previous_index':'513','script':'abcd','sequence':'4294967292','witness':[] if witness is None else witness}],'outputs':[{'amount':'-37','script':'5251'}],'locktime':'17'}
def identity(tx):
    full=serialize(tx,True);stripped=serialize(tx,False)
    result={'status':'ok','full':full.hex(),'stripped':stripped.hex(),'full_size':str(len(full)),'stripped_size':str(len(stripped))}
    for name,data in [('txid',stripped),('wtxid',full)]:
        h=digest(data);result[name+'_digest_order']=h.hex();result[name+'_display_order']=h[::-1].hex()
    return result

def cases():
    rows=[]
    def add(name,family,request,expected):rows.append({'id':name,'family':family,'request':request,'expected':expected})
    def decode(name,raw,status='ok',mode='witness',exact=True,extra=None,expected=None):
        request={'op':'decode_exact' if exact else 'decode_prefix','bytes':raw.hex(),'mode':mode};request.update(extra or {})
        add(name,'profile' if name.startswith(('prefix','trailing','budget','zero','impossible')) else 'encoding',request,expected or {'status':status})
    for tag,witness in [('plain',[]),('empty_item',['']),('witness',['ddee',''])]:
        tx=structure(witness);raw=serialize(tx)
        decode('decode_'+tag,raw,expected={'status':'ok','transaction':tx,'consumed':str(len(raw))})
        for n in range(len(raw)):decode(f'truncate_{tag}_{n}',raw[:n],'malformed_encoding')
        add('identify_'+tag,'structured',{'op':'identify','transaction':tx},identity(tx))
        for include in [False,True]:add('serialize_'+tag+'_'+str(include),'structured',{'op':'serialize','transaction':tx,'include_witness':include},{'status':'ok','bytes':serialize(tx,include).hex()})
    raw=serialize(structure(['']))
    decode('superfluous',raw[:-6]+b'\0'+raw[-4:],'malformed_encoding')
    decode('unknown3',raw[:5]+b'\3'+raw[6:],'malformed_encoding')
    plain=serialize(structure());decode('unknown2',plain[:4]+b'\0\2'+plain[4:],'malformed_encoding')
    decode('noncanonical',plain[:4]+b'\xfd\1\0'+plain[5:],'malformed_encoding')
    decode('impossible_count',b'\2\0\0\0'+b'\xff'*9,'malformed_encoding')
    z=bytes.fromhex('07000000000076543210')
    zero={'version_bits':'7','inputs':[],'outputs':[],'locktime':str(0x10325476)}
    decode('zero_flags',z,expected={'status':'ok','transaction':zero,'consumed':'10'})
    decode('prefix_zero',b'ab'+z+b'tail',exact=False,extra={'offset':'2'},expected={'status':'ok','transaction':zero,'consumed':'10'})
    decode('trailing_zero',z+b'\xff','malformed_encoding')
    decode('budget_complete',raw,'resource_limit',extra={'limits':{'max_items':'2'}})
    decode('budget_truncated',raw[:-1],'malformed_encoding',extra={'limits':{'max_items':'0'}})
    decode('budget_trailing',raw+b'x','malformed_encoding',extra={'limits':{'max_items':'0'}})
    decode('prefix_plain',b'x'+plain+b'y',exact=False,extra={'offset':'1'},expected={'status':'ok','transaction':structure(),'consumed':str(len(plain))})
    for field in ['version','amount','script','witness']:
        tx=structure([''])
        if field=='version':tx['version_bits']='19'
        elif field=='amount':tx['outputs'][0]['amount']='-129'
        elif field=='script':tx['inputs'][0]['script']='00aa'
        else:tx['inputs'][0]['witness']=['aa','00']
        add('modify_'+field,'structured',{'op':'identify','transaction':tx},identity(tx))
    many={'version_bits':'2','inputs':[],'outputs':[{'amount':'0','script':''}]*4097,'locktime':'9'}
    decode('budget_default_complete',serialize(many),'resource_limit',mode='legacy')
    decode('budget_default_truncated',serialize(many)[:-1],'malformed_encoding',mode='legacy')
    for row in rows:
        name=row['id']
        row['semantic_family']=('truncation' if name.startswith('truncate_') else
            'structured_modification' if name.startswith('modify_') else
            'identifiers' if name.startswith('identify_') else
            'structured_serialization' if name.startswith('serialize_') else
            'resource_precedence' if name.startswith('budget_') else
            'prefix_cursor' if name.startswith('prefix_') else
            'exact_trailing' if name.startswith('trailing_') else
            'optional_flags' if name.startswith(('zero_','unknown','superfluous')) else
            'compactsize' if name in ['noncanonical','impossible_count'] else 'field_layout')
    return rows

def matches(actual,expected):
    if expected.get('status')!='ok':return actual==expected
    return isinstance(actual,dict) and all(actual.get(k)==v for k,v in expected.items())

def evaluate(engine,rows=None):
    results={}
    for row in rows or cases():
        actual=engine.request(row['request'])
        results[row['id']]={'pass':matches(actual,row['expected']),'family':row['family']}
    return results
