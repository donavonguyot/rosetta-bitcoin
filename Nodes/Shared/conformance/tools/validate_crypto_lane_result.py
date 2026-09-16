#!/usr/bin/env python3
"""Validate experimental evidence without changing Project or node state."""
import json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[4]/'Project/scripts'))
from crypto_lanes import validate
if __name__=='__main__':
 errors=validate(json.loads(Path(sys.argv[1]).read_text()));print(json.dumps({'result':'failed' if errors else 'passed','errors':errors}));raise SystemExit(bool(errors))
