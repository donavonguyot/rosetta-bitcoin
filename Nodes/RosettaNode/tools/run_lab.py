#!/usr/bin/env python3
"""Use the recorded local image, with no network and no unrelated workspace mount."""
import json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
lock=json.loads((ROOT/'toolchain.json').read_text())
image=lock['image_id']
if subprocess.run(['docker','image','inspect',image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
    sys.exit('Pinned image missing. Build Dockerfile, inspect identities, and explicitly update toolchain.json; no automatic substitution.')
raise SystemExit(subprocess.call(['docker','run','--rm','--network','none','--cpus','4','--memory','4g','-v',f'{ROOT}:/work',image,*sys.argv[1:]]))
