"""Construct the planned width/comb roster, then measure without concurrent builds."""
import subprocess
import sys
from common import HERE, ROOT, WORK, exclusive, save


def main():
    names=['baseline','shared-z']
    with exclusive():
        for width in (8,10,12,13,14,15,16):
            for variable in range(3,8):
                subprocess.run([sys.executable,str(HERE/'tables.py'),'--width',str(width),'--variable-width',str(variable)],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
                names.append(f'shared-z-g{width}-p{variable}')
        for teeth in (4,6,8):
            subprocess.run([sys.executable,str(HERE/'comb.py'),'--teeth',str(teeth)],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
            names.append('comb-'+str(teeth))
        save(WORK/'sweep-roster.json',{'names':names,'status':'constructed'})
    subprocess.run([sys.executable,str(HERE/'bench.py'),*names],cwd=ROOT,check=True)
    save(WORK/'sweep-roster.json',{'names':names,'status':'measured'})

if __name__=='__main__':main()
