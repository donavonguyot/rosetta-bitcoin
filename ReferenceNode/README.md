# ReferenceNode

Local Bitcoin Core testnet4 reference peer for the `~/Nodes` workspace.

This node is a repeatability substrate, not a validation oracle. Port
implementations may download headers and blocks from it, but each port must
still independently validate every stored connected block.

## Start

```bash
cd ~/Nodes/ReferenceNode
docker compose up -d
```

The first run starts from an empty datadir and must sync from public testnet4.
Later runs reuse the external runtime state directory:

```text
/Users/donavonguyot/NodeData/bitcoin-core-testnet4
```

`~/Nodes/ReferenceNode` tracks only the reproducible recipe. Core chainstate is
mutable runtime state and intentionally lives outside `~/Nodes`.

## Ports

Local P2P endpoint for ports:

```text
127.0.0.1:48333
```

Local RPC endpoint for status/fixture extraction:

```text
127.0.0.1:48332
```

RPC credentials are local development only:

```text
rpcuser=rosetta
rpcpassword=rosetta-dev-only
```

## Status

```bash
docker compose exec bitcoin-core-testnet4 \
  bitcoin-cli -conf=/config/bitcoin.conf getblockchaininfo
```

## Boundary

Use this local Core node for deterministic development and multi-port block
serving. Public peer sync remains a required network reality gate before any
node can claim testnet4 participation.

Do not treat the Core datadir as source provenance. It is a local byte-serving
substrate; follower ports still validate independently.
