# Blocker Diagnostics Contract

One-off scripts are allowed for discovery only. Any recurring blocker workflow
must move into a port CLI or a shared Shared diagnostic that emits stable JSON.

## Required Diagnostic JSON

```json
{
  "implementation": "CSharpNode",
  "chain": "testnet4",
  "height": 22830,
  "block_hash": "",
  "txid": "",
  "input_index": 0,
  "spent_script_pubkey": "",
  "template": "p2tr",
  "witness_item_count": 0,
  "taproot_spend_type": "script_path",
  "tapscript_length": 0,
  "control_block_length": 0,
  "leaf_version": "",
  "missing_rule": "p2tr_script_path",
  "raw_json_version": 1
}
```

## Port CLI Shape

Recommended command shape:

```bash
<port-status-command> blocker-inspect --height 22830 --txid <txid> --input 0
```

The command may read the port's block store and chainstate in read-only mode.
It must not mutate the datadir or connect blocks.

## First Required Target

CSharpNode must replace the temporary Python scanner used for block `22830` with
a first-class diagnostic that reports:

- witness item count
- key-path vs script-path classification
- tapscript and control-block lengths
- leaf version
- txid/input/scriptPubKey
- missing rule

After that diagnostic exists, tapscript implementation can use the diagnostic
output and fixture bytes as the local C# regression path.
