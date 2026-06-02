from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

VerifiedBy = Literal["code", "test", "live", "manual"]

# Each capability is binary: implemented=0 or implemented=1.
# A checkpoint is passed when every required capability in that checkpoint is 1.


@dataclass(frozen=True)
class WireCapability:
    id: str
    checkpoint: str
    category: str
    name: str
    description: str
    required: bool
    implemented: bool = False


@dataclass(frozen=True)
class WireCheckpoint:
    id: str
    title: str
    description: str
    phase: str  # maps to project_phases


# ---------------------------------------------------------------------------
# Checkpoint definitions (measurement gates)
# ---------------------------------------------------------------------------

CHECKPOINTS: tuple[WireCheckpoint, ...] = (
    WireCheckpoint(
        id="cp0_framing",
        title="Message framing",
        description="Binary container format: magic, command, length, checksum.",
        phase="phase0",
    ),
    WireCheckpoint(
        id="cp1_handshake",
        title="Connection handshake",
        description="version/verack exchange with correct services and user agent.",
        phase="phase0",
    ),
    WireCheckpoint(
        id="cp2_discovery",
        title="Peer discovery",
        description="Find and connect to testnet4 peers.",
        phase="phase0",
    ),
    WireCheckpoint(
        id="cp3_headers",
        title="Header sync",
        description="Download, parse, and persist the header chain.",
        phase="phase1",
    ),
    WireCheckpoint(
        id="cp4_blocks",
        title="Block download",
        description="Request and receive full blocks over the wire.",
        phase="phase2",
    ),
    WireCheckpoint(
        id="cp5_tx_relay",
        title="Transaction relay",
        description="Receive, validate policy, and rebroadcast transactions.",
        phase="phase4",
    ),
    WireCheckpoint(
        id="cp6_serving",
        title="Inbound serving",
        description="Respond to peer requests as a network participant.",
        phase="phase4",
    ),
    WireCheckpoint(
        id="cp7_keepalive",
        title="Connection keepalive",
        description="ping/pong and connection health.",
        phase="phase0",
    ),
    WireCheckpoint(
        id="cp8_extensions",
        title="Protocol extensions",
        description="Optional modern protocol messages (sendheaders, compact blocks, etc.).",
        phase="phase5",
    ),
)

CHECKPOINTS_BY_ID = {cp.id: cp for cp in CHECKPOINTS}


# ---------------------------------------------------------------------------
# Capability registry — edit `implemented` as code lands; DB mirrors this.
# ---------------------------------------------------------------------------

CAPABILITIES: tuple[WireCapability, ...] = (
    # --- cp0_framing ---
    WireCapability(
        id="frame.build",
        checkpoint="cp0_framing",
        category="framing",
        name="Build P2P message frame",
        description="Serialize 24-byte header + payload with correct checksum.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="frame.parse",
        checkpoint="cp0_framing",
        category="framing",
        name="Parse P2P message header",
        description="Read magic, command, length, checksum from 24-byte header.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="frame.checksum",
        checkpoint="cp0_framing",
        category="framing",
        name="Verify payload checksum",
        description="Reject messages where checksum != first 4 bytes of double-SHA256(payload).",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="frame.magic",
        checkpoint="cp0_framing",
        category="framing",
        name="Network magic validation",
        description="Reject messages with wrong chain magic bytes.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="transport.outbound",
        checkpoint="cp0_framing",
        category="transport",
        name="Outbound TCP connection",
        description="Connect to peer host:port over asyncio TCP.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="transport.inbound",
        checkpoint="cp0_framing",
        category="transport",
        name="Inbound TCP listener",
        description="Accept incoming P2P connections on chain port.",
        required=False,
        implemented=False,
    ),
    # --- cp1_handshake ---
    WireCapability(
        id="handshake.version.send",
        checkpoint="cp1_handshake",
        category="handshake",
        name="Send version",
        description="Send version message with protocol version, services, addrs, nonce, user agent.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="handshake.version.recv",
        checkpoint="cp1_handshake",
        category="handshake",
        name="Receive and parse version",
        description="Deserialize peer version including start_height and relay flag.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="handshake.verack.send",
        checkpoint="cp1_handshake",
        category="handshake",
        name="Send verack",
        description="Send verack after receiving peer version.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="handshake.verack.recv",
        checkpoint="cp1_handshake",
        category="handshake",
        name="Receive verack",
        description="Wait for peer verack to complete handshake.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="handshake.services",
        checkpoint="cp1_handshake",
        category="handshake",
        name="Advertise NODE_NETWORK | NODE_WITNESS",
        description="Set services flags required for full-node participation.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="handshake.sendheaders",
        checkpoint="cp1_handshake",
        category="handshake",
        name="Send sendheaders (BIP130)",
        description="Announce preference for headers-first block propagation.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="handshake.sendcmpct",
        checkpoint="cp1_handshake",
        category="handshake",
        name="Send sendcmpct (BIP152)",
        description="Negotiate compact block relay mode.",
        required=False,
        implemented=False,
    ),
    WireCapability(
        id="handshake.wtxidrelay",
        checkpoint="cp1_handshake",
        category="handshake",
        name="Send wtxidrelay (BIP339)",
        description="Announce witness tx relay support.",
        required=False,
        implemented=False,
    ),
    # --- cp2_discovery ---
    WireCapability(
        id="discovery.dns",
        checkpoint="cp2_discovery",
        category="discovery",
        name="DNS seed resolution",
        description="Resolve testnet4 DNS seeds to peer IP addresses.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="discovery.manual_peers",
        checkpoint="cp2_discovery",
        category="discovery",
        name="Manual peer list",
        description="Connect via --peers / PEERS env (host:port list).",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="discovery.getaddr",
        checkpoint="cp2_discovery",
        category="discovery",
        name="Send getaddr",
        description="Request peer address gossip from connected peers.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="discovery.addr.recv",
        checkpoint="cp2_discovery",
        category="discovery",
        name="Receive and parse addr",
        description="Deserialize addr message and store peer addresses.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="discovery.addr.relay",
        checkpoint="cp2_discovery",
        category="discovery",
        name="Relay addr to peers",
        description="Forward known addresses to other connected peers.",
        required=False,
        implemented=False,
    ),
    WireCapability(
        id="discovery.multi_peer",
        checkpoint="cp2_discovery",
        category="discovery",
        name="Multiple simultaneous outbound peers",
        description="Maintain a pool of 3+ outbound connections.",
        required=True,
        implemented=True,
    ),
    # --- cp3_headers ---
    WireCapability(
        id="headers.getheaders.send",
        checkpoint="cp3_headers",
        category="headers",
        name="Send getheaders",
        description="Request headers using block locator hashes.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.headers.recv",
        checkpoint="cp3_headers",
        category="headers",
        name="Receive and parse headers",
        description="Deserialize headers message (80-byte header + varint tx count).",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.locator",
        checkpoint="cp3_headers",
        category="headers",
        name="Block locator construction",
        description="Build exponential block locator from stored header chain.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.persist",
        checkpoint="cp3_headers",
        category="headers",
        name="Persist headers to SQLite",
        description="Store height, hash, prev_hash, timestamp for each header.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.genesis",
        checkpoint="cp3_headers",
        category="headers",
        name="Genesis header seeded",
        description="Height 0 genesis block stored as chain anchor.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.pow",
        checkpoint="cp3_headers",
        category="headers",
        name="Proof-of-work validation",
        description="Reject headers that do not meet nBits target.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.chain_link",
        checkpoint="cp3_headers",
        category="headers",
        name="Chain link validation",
        description="Reject headers whose prev_hash does not match stored tip.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.sync_to_tip",
        checkpoint="cp3_headers",
        category="headers",
        name="Sync header chain to network tip",
        description="Repeated getheaders until empty response or tip matches peer height.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.resume",
        checkpoint="cp3_headers",
        category="headers",
        name="Resume header sync from SQLite",
        description="On restart, continue from stored best_height without re-fetching.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="headers.inv_trigger",
        checkpoint="cp3_headers",
        category="headers",
        name="inv(MSG_BLOCK) triggers getheaders",
        description="On block inv, update locator and fetch new headers.",
        required=True,
        implemented=True,
    ),
    # --- cp4_blocks ---
    WireCapability(
        id="blocks.inv.recv",
        checkpoint="cp4_blocks",
        category="blocks",
        name="Receive and parse inv",
        description="Deserialize inv vectors (type + hash).",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="blocks.getdata.send",
        checkpoint="cp4_blocks",
        category="blocks",
        name="Send getdata for blocks",
        description="Request MSG_WITNESS_BLOCK via getdata.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="blocks.block.recv",
        checkpoint="cp4_blocks",
        category="blocks",
        name="Receive block message",
        description="Read raw block payload from P2P wire.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="blocks.block.store",
        checkpoint="cp4_blocks",
        category="blocks",
        name="Store raw block bytes",
        description="Write block to blocks/*.dat flat files.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="blocks.notfound",
        checkpoint="cp4_blocks",
        category="blocks",
        name="Handle notfound",
        description="Request block from alternate peer on notfound.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="blocks.parallel",
        checkpoint="cp4_blocks",
        category="blocks",
        name="Parallel block download",
        description="Fetch blocks from multiple peers concurrently.",
        required=False,
        implemented=False,
    ),
    # --- cp5_tx_relay ---
    WireCapability(
        id="tx.inv.recv",
        checkpoint="cp5_tx_relay",
        category="transactions",
        name="Receive inv(MSG_WITNESS_TX)",
        description="Parse transaction inventory announcements.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="tx.getdata.send",
        checkpoint="cp5_tx_relay",
        category="transactions",
        name="Send getdata for transactions",
        description="Request tx bytes from peer.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="tx.tx.recv",
        checkpoint="cp5_tx_relay",
        category="transactions",
        name="Receive tx message",
        description="Deserialize transaction from wire payload.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="tx.mempool",
        checkpoint="cp5_tx_relay",
        category="transactions",
        name="Send mempool (BIP35)",
        description="Request peer mempool tx inv after connection.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="tx.inv.send",
        checkpoint="cp5_tx_relay",
        category="transactions",
        name="Announce transactions via inv",
        description="Relay accepted mempool txs to peers.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="tx.feefilter",
        checkpoint="cp5_tx_relay",
        category="transactions",
        name="Send feefilter (BIP133)",
        description="Advertise minimum fee rate for inv relay.",
        required=False,
        implemented=True,
    ),
    # --- cp6_serving ---
    WireCapability(
        id="serve.getheaders",
        checkpoint="cp6_serving",
        category="serving",
        name="Respond to getheaders",
        description="Serve known headers to requesting peers.",
        required=True,
        implemented=False,
    ),
    WireCapability(
        id="serve.getdata.blocks",
        checkpoint="cp6_serving",
        category="serving",
        name="Respond to getdata (blocks)",
        description="Serve stored blocks to requesting peers.",
        required=True,
        implemented=False,
    ),
    WireCapability(
        id="serve.getdata.txs",
        checkpoint="cp6_serving",
        category="serving",
        name="Respond to getdata (transactions)",
        description="Serve mempool transactions to requesting peers.",
        required=True,
        implemented=False,
    ),
    WireCapability(
        id="serve.inv.blocks",
        checkpoint="cp6_serving",
        category="serving",
        name="Announce new blocks via inv",
        description="Broadcast block inv when tip advances.",
        required=True,
        implemented=False,
    ),
    # --- cp7_keepalive ---
    WireCapability(
        id="keepalive.ping.recv",
        checkpoint="cp7_keepalive",
        category="keepalive",
        name="Respond to ping with pong",
        description="Reply to peer ping with matching nonce.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="keepalive.ping.send",
        checkpoint="cp7_keepalive",
        category="keepalive",
        name="Send periodic ping",
        description="Probe idle connections with ping messages.",
        required=True,
        implemented=True,
    ),
    WireCapability(
        id="keepalive.timeout",
        checkpoint="cp7_keepalive",
        category="keepalive",
        name="Disconnect stale peers",
        description="Drop peers with no messages within timeout window.",
        required=True,
        implemented=True,
    ),
    # --- cp8_extensions ---
    WireCapability(
        id="ext.cmpctblock",
        checkpoint="cp8_extensions",
        category="extensions",
        name="Receive cmpctblock (BIP152)",
        description="Parse compact block messages.",
        required=False,
        implemented=True,
    ),
    WireCapability(
        id="ext.getblocktxn",
        checkpoint="cp8_extensions",
        category="extensions",
        name="Send getblocktxn (BIP152)",
        description="Request missing transactions for compact block.",
        required=False,
        implemented=False,
    ),
    WireCapability(
        id="ext.reject",
        checkpoint="cp8_extensions",
        category="extensions",
        name="Send/receive reject",
        description="Protocol-level reject messages for invalid payloads (inbound parse path implemented).",
        required=False,
        implemented=True,
    ),
    WireCapability(
        id="ext.bip324",
        checkpoint="cp8_extensions",
        category="extensions",
        name="BIP324 v2 encrypted transport",
        description="Encrypted P2P v2 transport instead of cleartext v1.",
        required=False,
        implemented=False,
    ),
)

CAPABILITIES_BY_ID = {cap.id: cap for cap in CAPABILITIES}


def capabilities_for_checkpoint(checkpoint_id: str) -> tuple[WireCapability, ...]:
    return tuple(cap for cap in CAPABILITIES if cap.checkpoint == checkpoint_id)


def checkpoint_status(capabilities: dict[str, int]) -> dict[str, dict]:
    """Return pass/fail for each checkpoint based on binary capability map."""
    result: dict[str, dict] = {}
    for cp in CHECKPOINTS:
        caps = capabilities_for_checkpoint(cp.id)
        required = [c for c in caps if c.required]
        required_done = sum(1 for c in required if capabilities.get(c.id, 0) == 1)
        optional = [c for c in caps if not c.required]
        optional_done = sum(1 for c in optional if capabilities.get(c.id, 0) == 1)
        result[cp.id] = {
            "checkpoint": cp.id,
            "title": cp.title,
            "phase": cp.phase,
            "required_total": len(required),
            "required_done": required_done,
            "required_pass": required_done == len(required) if required else True,
            "optional_total": len(optional),
            "optional_done": optional_done,
            "capabilities_total": len(caps),
            "capabilities_done": sum(1 for c in caps if capabilities.get(c.id, 0) == 1),
        }
    return result


def full_node_wire_progress(capabilities: dict[str, int]) -> dict:
    """Aggregate progress toward full-node wire participation."""
    required = [c for c in CAPABILITIES if c.required]
    required_done = sum(1 for c in required if capabilities.get(c.id, 0) == 1)
    checkpoints = checkpoint_status(capabilities)
    checkpoints_passed = sum(1 for cp in checkpoints.values() if cp["required_pass"])
    return {
        "required_total": len(required),
        "required_done": required_done,
        "required_percent": round(100 * required_done / len(required), 1) if required else 100.0,
        "checkpoints_total": len(CHECKPOINTS),
        "checkpoints_passed": checkpoints_passed,
        "checkpoints_percent": round(100 * checkpoints_passed / len(CHECKPOINTS), 1),
        "full_node_wire_ready": required_done == len(required),
    }
