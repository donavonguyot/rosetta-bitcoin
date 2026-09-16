"""Cold-cache compilation and static binary observations for final controls."""
import time,shutil,re
from common import WORK,FROZEN,docker,save,exclusive,digest
from assembly import audit


def main():
    result={}
    with exclusive():
        for name in ('baseline','candidate'):
            cache=WORK/('compile-cache-'+name)
            if cache.exists():shutil.rmtree(cache)
            package=FROZEN if name=='baseline' else WORK/name
            start=time.monotonic()
            docker(['zig','build-exe','--global-cache-dir','/work/'+cache.name,'-O','ReleaseSafe','--dep','secp256k1','-Mroot=/work/bench.zig','-O','ReleaseSafe','-Msecp256k1=/work/'+str(package.relative_to(WORK))+'/src/root.zig','-femit-bin=/work/cost-'+name,'-femit-asm=/work/cost-'+name+'.s'])
            elapsed=time.monotonic()-start;asm=(WORK/('cost-'+name+'.s')).read_text()
            stack=[int(m[1])<<int(m[2] or 0) for m in re.finditer(r'sub\s+sp, sp, #(\d+)(?:, lsl #(\d+))?',asm)]
            result[name]=dict(cold_compile_seconds=elapsed,includes_docker_start=True,binary_bytes=(WORK/('cost-'+name)).stat().st_size,binary_sha256=digest(WORK/('cost-'+name)),assembly_sha256=digest(WORK/('cost-'+name+'.s')),assembly_audit=audit(asm,r'(verifyEcdsa|verifySchnorr|operation|joint|generatorMultiply|Point\.(double|mixed|plus|affine))'),largest_stack_decrement=max(stack,default=0),stack_scope='static instruction, not maximum live call stack',packed_table_bytes=sum(p.stat().st_size for p in (package/'src').glob('*.bin')))
            assert result[name]['assembly_audit']['passed'],result[name]
    save(WORK/'compile-cost.json',result)

if __name__=='__main__':main()
