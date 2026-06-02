package com.jbitnode.p2p;

import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.util.Hex;
import com.jbitnode.messages.GetHeadersMessage;
import com.jbitnode.messages.HandshakeMessages;
import com.jbitnode.messages.HeadersMessage;
import com.jbitnode.messages.InventoryMessages.GetDataMessage;
import com.jbitnode.messages.InventoryMessages.InvMessage;
import com.jbitnode.messages.InventoryMessages.NotFoundMessage;
import com.jbitnode.messages.BlockMessage;
import com.jbitnode.messages.NetworkAddress;
import com.jbitnode.messages.VersionMessage;
import com.jbitnode.wire.MessageStream;
import com.jbitnode.wire.NetworkMessage;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/** Minimal Bitcoin P2P peer for unit/integration tests. */
public final class MockBitcoinPeer implements AutoCloseable {

  private final ServerSocket server;
  private final Future<?> task;

  private MockBitcoinPeer(ServerSocket server, Future<?> task) {
    this.server = server;
    this.task = task;
  }

  public static MockBitcoinPeer start(int startHeight, List<byte[]> headerResponses)
      throws IOException {
    return start(startHeight, headerResponses, Map.of());
  }

  public static MockBitcoinPeer start(
      int startHeight, List<byte[]> headerResponses, Map<String, byte[]> blocksByHashHex)
      throws IOException {
    ServerSocket server = new ServerSocket(0);
    Future<?> task =
        Executors.newSingleThreadExecutor()
            .submit(
                () -> {
                  try (Socket socket = server.accept()) {
                    serve(socket, startHeight, headerResponses, blocksByHashHex);
                  } catch (IOException ignored) {
                    // test peer shutdown
                  }
                });
    return new MockBitcoinPeer(server, task);
  }

  public int port() {
    return server.getLocalPort();
  }

  @Override
  public void close() throws IOException {
    server.close();
    task.cancel(true);
  }

  private static void serve(
      Socket socket,
      int startHeight,
      List<byte[]> headerResponses,
      Map<String, byte[]> blocksByHashHex)
      throws IOException {
    InputStream input = socket.getInputStream();
    OutputStream output = socket.getOutputStream();
    MessageStream stream =
        new MessageStream(input, output, ChainRegistry.TESTNET4.magic());
    NetworkAddress addr =
        new NetworkAddress(
            HandshakeMessages.NODE_NETWORK | HandshakeMessages.NODE_WITNESS, "127.0.0.1", 48_333);

    NetworkMessage versionMsg = stream.readUntilCommand(HandshakeMessages.VERSION_COMMAND, 5000);
    HandshakeMessages.deserializeVersion(versionMsg.payload());
    VersionMessage reply =
        HandshakeMessages.buildVersionMessage(
            70_016,
            HandshakeMessages.NODE_NETWORK | HandshakeMessages.NODE_WITNESS,
            addr,
            addr,
            "/mockcore:29.0.0/",
            startHeight,
            true);
    stream.send(HandshakeMessages.VERSION_COMMAND, HandshakeMessages.serializeVersion(reply));
    stream.readUntilCommand(HandshakeMessages.VERACK_COMMAND, 5000);
    stream.send(HandshakeMessages.VERACK_COMMAND, HandshakeMessages.serializeVerAck());
    stream.readUntilCommand(HandshakeMessages.SENDHEADERS_COMMAND, 5000);

    Map<String, byte[]> blocks = new HashMap<>(blocksByHashHex);
    int headerIndex = 0;
    long deadline = System.currentTimeMillis() + 30_000;
    while (System.currentTimeMillis() < deadline) {
      NetworkMessage message = stream.readMessage(1000);
      if (GetHeadersMessage.COMMAND.equals(message.command()) && headerIndex < headerResponses.size()) {
        stream.send(HeadersMessage.COMMAND, headerResponses.get(headerIndex));
        headerIndex += 1;
        continue;
      }
      if (GetDataMessage.COMMAND.equals(message.command())) {
        InvMessage getdata = GetDataMessage.deserialize(message.payload());
        if (getdata.inventory().isEmpty()) {
          continue;
        }
        byte[] hash = getdata.inventory().getFirst().hash();
        String hashHex = Hex.encode(Hex.reverse(hash));
        byte[] blockPayload = blocks.get(hashHex);
        if (blockPayload == null) {
          stream.send(NotFoundMessage.COMMAND, NotFoundMessage.serialize(getdata));
        } else {
          stream.send(BlockMessage.COMMAND, BlockMessage.serialize(blockPayload));
        }
      }
    }
  }
}
