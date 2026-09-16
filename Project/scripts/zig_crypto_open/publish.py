"""Install only the holdout-selected package, preserving unrelated work."""
import shutil,json,subprocess
from common import WORK,LIB,ROOT,source_digest,save


def main():
    decision=json.loads((WORK/'holdout-decision.json').read_text());source=WORK/'candidate'
    assert decision['candidate_digest']==source_digest(source)
    status=subprocess.check_output(['git','status','--porcelain','--',str(LIB)],cwd=ROOT,text=True)
    if status:raise ValueError('Package has intervening changes; refusing to overwrite them')
    shutil.copytree(source,LIB,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out','__pycache__'))
    assert source_digest(LIB)==source_digest(source)
    config=json.loads((WORK/'candidate-configuration.json').read_text());config['source_digest']=source_digest(source)
    if decision['selected']=='baseline':config.update(selected='baseline',shared_z=False)
    config['holdout_selected']=decision['selected'];save(WORK/'candidate-configuration.json',config)
    print('published',decision['selected'],source_digest(LIB))

if __name__=='__main__':main()
