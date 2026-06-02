package com.jbitnode.messages;

import com.jbitnode.wire.WireSerialize;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Arrays;

/** Version/verack/sendheaders handshake message serialization. */
public final class HandshakeMessages {

  public static final String VERSION_COMMAND = "version";
  public static final String VERACK_COMMAND = "verack";
  public static final String SENDHEADERS_COMMAND = "sendheaders";

  public static final long NODE_NETWORK = 1L << 0;
  public static final long NODE_WITNESS = 1L << 3;

  private static final SecureRandom RANDOM = new SecureRandom();

  private HandshakeMessages() {}

  public static byte[] serializeNetworkAddress(NetworkAddress address, boolean withTimestamp) {
    int size = (withTimestamp ? 8 : 0) + 8 + 16 + 2;
    byte[] out = new byte[size];
    int offset = 0;
    if (withTimestamp) {
      System.arraycopy(
          WireSerialize.packInt64Le(System.currentTimeMillis() / 1000), 0, out, offset, 8);
      offset += 8;
    }
    System.arraycopy(WireSerialize.packUint64Le(address.services()), 0, out, offset, 8);
    offset += 8;
    System.arraycopy(ipToBytes(address.ip()), 0, out, offset, 16);
    offset += 16;
    System.arraycopy(WireSerialize.packUint16Be(address.port()), 0, out, offset, 2);
    return out;
  }

  public static NetworkAddressWithOffset deserializeNetworkAddress(
      byte[] data, int offset, boolean withTimestamp) {
    int required = (withTimestamp ? 8 : 0) + 8 + 16 + 2;
    if (offset + required > data.length) {
      throw new IllegalArgumentException("truncated network address");
    }
    if (withTimestamp) {
      offset += 8;
    }
    long services = WireSerialize.unpackUint64Le(data, offset);
    offset += 8;
    byte[] ipBytes = Arrays.copyOfRange(data, offset, offset + 16);
    offset += 16;
    int port = WireSerialize.unpackUint16Be(data, offset);
    offset += 2;
    return new NetworkAddressWithOffset(new NetworkAddress(services, bytesToIp(ipBytes), port), offset);
  }

  public static byte[] serializeVersion(VersionMessage message) {
    byte[] ua = message.userAgent().getBytes(StandardCharsets.US_ASCII);
    byte[] out =
        new byte[4 + 8 + 8 + 26 + 26 + 8 + 1 + ua.length + 4 + 1];
    int offset = 0;
    System.arraycopy(WireSerialize.packInt32Le(message.version()), 0, out, offset, 4);
    offset += 4;
    System.arraycopy(WireSerialize.packUint64Le(message.services()), 0, out, offset, 8);
    offset += 8;
    System.arraycopy(WireSerialize.packInt64Le(message.timestamp()), 0, out, offset, 8);
    offset += 8;
    byte[] recv = serializeNetworkAddress(message.addrRecv(), false);
    System.arraycopy(recv, 0, out, offset, recv.length);
    offset += recv.length;
    byte[] from = serializeNetworkAddress(message.addrFrom(), false);
    System.arraycopy(from, 0, out, offset, from.length);
    offset += from.length;
    System.arraycopy(WireSerialize.packUint64Le(message.nonce()), 0, out, offset, 8);
    offset += 8;
    out[offset++] = (byte) ua.length;
    System.arraycopy(ua, 0, out, offset, ua.length);
    offset += ua.length;
    System.arraycopy(WireSerialize.packInt32Le(message.startHeight()), 0, out, offset, 4);
    offset += 4;
    out[offset] = (byte) (message.relay() ? 1 : 0);
    return out;
  }

  public static VersionMessage deserializeVersion(byte[] payload) {
    int offset = 0;
    int version = WireSerialize.unpackInt32Le(payload, offset);
    offset += 4;
    long services = WireSerialize.unpackUint64Le(payload, offset);
    offset += 8;
    long timestamp = WireSerialize.unpackInt64Le(payload, offset);
    offset += 8;
    NetworkAddressWithOffset recv = deserializeNetworkAddress(payload, offset, false);
    offset = recv.nextOffset();
    NetworkAddressWithOffset from = deserializeNetworkAddress(payload, offset, false);
    offset = from.nextOffset();
    long nonce = WireSerialize.unpackUint64Le(payload, offset);
    offset += 8;
    int uaLen = payload[offset++] & 0xff;
    String userAgent = new String(payload, offset, uaLen, StandardCharsets.US_ASCII);
    offset += uaLen;
    int startHeight = WireSerialize.unpackInt32Le(payload, offset);
    offset += 4;
    boolean relay = offset >= payload.length || payload[offset] != 0;
    return new VersionMessage(
        version,
        services,
        timestamp,
        recv.address(),
        from.address(),
        nonce,
        userAgent,
        startHeight,
        relay);
  }

  public static VersionMessage buildVersionMessage(
      int protocolVersion,
      long services,
      NetworkAddress addrRecv,
      NetworkAddress addrFrom,
      String userAgent,
      int startHeight,
      boolean relay) {
    byte[] nonceBytes = new byte[8];
    RANDOM.nextBytes(nonceBytes);
    long nonce = WireSerialize.unpackUint64Le(nonceBytes, 0);
    return new VersionMessage(
        protocolVersion,
        services,
        System.currentTimeMillis() / 1000,
        addrRecv,
        addrFrom,
        nonce,
        userAgent,
        startHeight,
        relay);
  }

  public static byte[] serializeVerAck() {
    return new byte[0];
  }

  public static byte[] serializeSendHeaders() {
    return new byte[0];
  }

  static byte[] ipToBytes(String ip) {
    if (ip.contains(":")) {
      byte[] buf = new byte[16];
      String[] groups = ip.split(":");
      int offset = 0;
      int emptyIndex = -1;
      for (int i = 0; i < groups.length; i++) {
        if (groups[i].isEmpty()) {
          emptyIndex = i;
          break;
        }
        int value = Integer.parseInt(groups[i], 16);
        buf[offset++] = (byte) ((value >> 8) & 0xff);
        buf[offset++] = (byte) (value & 0xff);
      }
      if (emptyIndex >= 0) {
        int tailStart = emptyIndex + 1;
        int tailGroups = groups.length - tailStart;
        int zeros = 16 - offset - tailGroups * 2;
        offset += zeros;
        for (int i = tailStart; i < groups.length; i++) {
          if (groups[i].isEmpty()) {
            continue;
          }
          int value = Integer.parseInt(groups[i], 16);
          buf[offset++] = (byte) ((value >> 8) & 0xff);
          buf[offset++] = (byte) (value & 0xff);
        }
      }
      return buf;
    }
    String[] parts = ip.split("\\.");
    if (parts.length != 4) {
      throw new IllegalArgumentException("Invalid IPv4 address " + ip);
    }
    byte[] mapped = new byte[16];
    Arrays.fill(mapped, 0, 10, (byte) 0xff);
    mapped[10] = (byte) 0xff;
    mapped[11] = (byte) 0xff;
    for (int i = 0; i < 4; i++) {
      mapped[12 + i] = (byte) Integer.parseInt(parts[i]);
    }
    return mapped;
  }

  static String bytesToIp(byte[] raw) {
    boolean ipv4Mapped = true;
    for (int i = 0; i < 12; i++) {
      if (i < 10 && raw[i] != (byte) 0xff) {
        ipv4Mapped = false;
        break;
      }
      if (i >= 10 && i <= 11 && raw[i] != (byte) 0xff) {
        ipv4Mapped = false;
        break;
      }
    }
    if (raw.length == 16 && ipv4Mapped) {
      return (raw[12] & 0xff)
          + "."
          + (raw[13] & 0xff)
          + "."
          + (raw[14] & 0xff)
          + "."
          + (raw[15] & 0xff);
    }
    StringBuilder sb = new StringBuilder();
    for (int offset = 0; offset < 16; offset += 2) {
      if (offset > 0) {
        sb.append(':');
      }
      sb.append(Integer.toHexString(((raw[offset] & 0xff) << 8) | (raw[offset + 1] & 0xff)));
    }
    return sb.toString();
  }

  public record NetworkAddressWithOffset(NetworkAddress address, int nextOffset) {}
}
