package com.jbitnode.p2p;

import com.jbitnode.chain.ChainParams;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.messages.GetHeadersMessage;
import com.jbitnode.messages.HandshakeMessages;
import com.jbitnode.messages.HeadersMessage;
import com.jbitnode.messages.InventoryMessages;
import com.jbitnode.messages.InventoryMessages.GetDataMessage;
import com.jbitnode.messages.InventoryMessages.InventoryVector;
import com.jbitnode.messages.InventoryMessages.InvMessage;
import com.jbitnode.messages.InventoryMessages.NotFoundMessage;
import com.jbitnode.messages.BlockMessage;
import com.jbitnode.messages.NetworkAddress;
import com.jbitnode.messages.VersionMessage;
import com.jbitnode.util.Hex;
import com.jbitnode.wire.MessageStream;
import com.jbitnode.wire.NetworkMessage;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.List;

/**
 * TCP P2P connection with the workspace simple-handshake posture.
 *
 * <p>Initial sync sends version/verack/sendheaders only: deferred advanced negotiation keeps
 * relay-oriented messages out of the bootstrap path until the node can honestly represent its
 * validated chainstate. See Nodes/Shared/CODE_DOCUMENTATION.md.
 */
public final class PeerConnection implements AutoCloseable {

  private final String host;
  private final int port;
  private final ChainParams chain;
  private final ProjectTracker tracker;
  private final int startHeight;

  private Socket socket;
  private MessageStream stream;
  private VersionMessage remoteVersion;
  private long peerId;

  public PeerConnection(
      String host, int port, ChainParams chain, ProjectTracker tracker, int startHeight) {
    this.host = host;
    this.port = port;
    this.chain = chain;
    this.tracker = tracker;
    this.startHeight = startHeight;
  }

  public String host() {
    return host;
  }

  public int port() {
    return port;
  }

  public VersionMessage remoteVersion() {
    return remoteVersion;
  }

  public void connect() throws IOException, SQLException {
    socket = new Socket();
    socket.setTcpNoDelay(true);
    socket.connect(new InetSocketAddress(host, port), 30_000);
    socket.setSoTimeout(0);
    stream = new MessageStream(socket.getInputStream(), socket.getOutputStream(), chain.magic());
    handshakeAsInitiator();
    VersionMessage remote = remoteVersion;
    peerId =
        tracker.recordPeerConnected(
            host,
            port,
            "outbound",
            remote != null ? remote.services() : 0,
            remote != null ? remote.version() : 0,
            remote != null ? remote.userAgent() : "",
            remote != null ? remote.startHeight() : 0);
    markHandshakeCapabilities();
  }

  public HeadersMessage.Message requestHeaders(List<byte[]> locator) throws IOException {
    GetHeadersMessage.Message request =
        new GetHeadersMessage.Message(chain.protocolVersion(), locator, new byte[32]);
    stream.send(GetHeadersMessage.COMMAND, GetHeadersMessage.serialize(request));
    try {
      tracker.markWireCapability(
          "headers.getheaders.send", true, "live", "sent getheaders to " + host + ":" + port);
    } catch (SQLException e) {
      throw new IOException("Failed to mark wire capability", e);
    }
    NetworkMessage response = stream.readUntilCommand(HeadersMessage.COMMAND, 120_000);
    try {
      tracker.markWireCapability(
          "headers.headers.recv", true, "live", "received headers from " + host + ":" + port);
    } catch (SQLException e) {
      throw new IOException("Failed to mark wire capability", e);
    }
    return HeadersMessage.deserialize(response.payload());
  }

  public byte[] requestBlock(byte[] blockHashInternal) throws IOException {
    return requestBlock(blockHashInternal, 120_000);
  }

  byte[] requestBlock(byte[] blockHashInternal, long timeoutMs) throws IOException {
    for (int invType :
        new int[] {
          InventoryMessages.MSG_WITNESS_BLOCK, InventoryMessages.MSG_BLOCK
        }) {
      byte[] payload = requestBlockOnce(blockHashInternal, invType, timeoutMs);
      if (payload != null) {
        return payload;
      }
    }
    return null;
  }

  public void markBlockDownloadCapabilities() throws SQLException {
    tracker.markWireCapability(
        "blocks.getdata.send", true, "live", "sent getdata to " + host + ":" + port);
    tracker.markWireCapability(
        "blocks.block.recv", true, "live", "received block from " + host + ":" + port);
  }

  // Tracker-free so it is safe to drive from the background block-prefetch thread; the connect
  // loop records blocks.getdata.send / blocks.block.recv (markBlockDownloadCapabilities) and the
  // blocks.notfound capability on the main thread, keeping all operational-store writes single
  // threaded. Returns null on notfound, hash mismatch, or timeout (caller treats as unavailable).
  private byte[] requestBlockOnce(byte[] blockHashInternal, int invType, long timeoutMs)
      throws IOException {
    InventoryVector inv = new InventoryVector(invType, blockHashInternal);
    InvMessage getdata = new InvMessage(List.of(inv));
    stream.send(GetDataMessage.COMMAND, GetDataMessage.serialize(getdata));

    long deadline = System.currentTimeMillis() + timeoutMs;
    while (System.currentTimeMillis() < deadline) {
      long remaining = deadline - System.currentTimeMillis();
      NetworkMessage message = stream.readUntilAnyCommand(
          List.of(BlockMessage.COMMAND, NotFoundMessage.COMMAND), remaining);
      if (BlockMessage.COMMAND.equals(message.command())) {
        byte[] payload = BlockMessage.deserialize(message.payload());
        byte[] receivedHash = BlockMessage.blockHashFromPayload(payload);
        if (!Arrays.equals(receivedHash, blockHashInternal)) {
          return null;
        }
        return payload;
      }
      InvMessage notfound = NotFoundMessage.deserialize(message.payload());
      if (InventoryMessages.inventoryContainsHash(notfound, blockHashInternal)) {
        return null;
      }
    }
    return null;
  }

  private void handshakeAsInitiator() throws IOException {
    NetworkAddress addr =
        new NetworkAddress(
            HandshakeMessages.NODE_NETWORK | HandshakeMessages.NODE_WITNESS, "0.0.0.0", 0);
    // Honest start_height: this value comes from validated runtime truth, not the header tip.
    // Peers may disconnect nodes that claim chain progress they cannot validate or serve.
    VersionMessage version =
        HandshakeMessages.buildVersionMessage(
            chain.protocolVersion(),
            HandshakeMessages.NODE_NETWORK | HandshakeMessages.NODE_WITNESS,
            addr,
            addr,
            chain.userAgent(),
            startHeight,
            true);
    stream.send(HandshakeMessages.VERSION_COMMAND, HandshakeMessages.serializeVersion(version));
    NetworkMessage remote =
        stream.readUntilCommand(HandshakeMessages.VERSION_COMMAND, 30_000);
    remoteVersion = HandshakeMessages.deserializeVersion(remote.payload());
    stream.send(HandshakeMessages.VERACK_COMMAND, HandshakeMessages.serializeVerAck());
    stream.readUntilCommand(HandshakeMessages.VERACK_COMMAND, 30_000);
    // Deferred advanced negotiation: Java intentionally stops post-verack at sendheaders here.
    // Feefilter, mempool, and compact-block negotiation belong to a later relay-capable mode.
    stream.send(HandshakeMessages.SENDHEADERS_COMMAND, HandshakeMessages.serializeSendHeaders());
  }

  private void markHandshakeCapabilities() throws SQLException {
    tracker.markWireCapability("frame.build", true, "live", "sent framed P2P messages");
    tracker.markWireCapability("frame.parse", true, "live", "parsed framed P2P messages");
    tracker.markWireCapability("handshake.version.send", true, "live", "sent version");
    tracker.markWireCapability("handshake.version.recv", true, "live", "received version");
    tracker.markWireCapability("handshake.verack", true, "live", "completed verack exchange");
    tracker.markWireCapability("handshake.sendheaders", true, "live", "sent sendheaders only post-verack");
    tracker.logEvent(
        "p2p",
        "Handshake complete with " + host + ":" + port,
        "info",
        "{\"userAgent\":\""
            + (remoteVersion != null ? remoteVersion.userAgent() : "?")
            + "\"}");
  }

  @Override
  public void close() throws IOException {
    if (socket != null && !socket.isClosed()) {
      socket.close();
    }
    if (peerId > 0) {
      try {
        tracker.recordPeerDisconnected(peerId);
      } catch (SQLException e) {
        throw new IOException("Failed to record peer disconnect", e);
      }
      peerId = 0;
    }
  }
}
