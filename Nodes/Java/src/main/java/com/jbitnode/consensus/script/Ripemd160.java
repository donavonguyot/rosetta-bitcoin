package com.jbitnode.consensus.script;

import java.util.Arrays;

/** Minimal RIPEMD-160 implementation for Bitcoin HASH160 without external providers. */
final class Ripemd160 {
  private static final int[] RL = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
    3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
    1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
    4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13
  };
  private static final int[] RR = {
    5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
    6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
    15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
    8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
    12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11
  };
  private static final int[] SL = {
    11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
    7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
    11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
    11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
    9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6
  };
  private static final int[] SR = {
    8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
    9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
    9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
    15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
    8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11
  };

  private Ripemd160() {}

  static byte[] hash(byte[] input) {
    int[] h = {
      0x67452301,
      0xefcdab89,
      0x98badcfe,
      0x10325476,
      0xc3d2e1f0
    };
    byte[] padded = pad(input);
    int[] x = new int[16];
    for (int offset = 0; offset < padded.length; offset += 64) {
      for (int word = 0; word < 16; word++) {
        int base = offset + word * 4;
        x[word] =
            (padded[base] & 0xff)
                | ((padded[base + 1] & 0xff) << 8)
                | ((padded[base + 2] & 0xff) << 16)
                | ((padded[base + 3] & 0xff) << 24);
      }
      compress(h, x);
    }
    byte[] out = new byte[20];
    for (int index = 0; index < h.length; index++) {
      writeLittleEndian(out, index * 4, h[index]);
    }
    return out;
  }

  private static byte[] pad(byte[] input) {
    int blocks = ((input.length + 8) >>> 6) + 1;
    byte[] padded = Arrays.copyOf(input, blocks * 64);
    padded[input.length] = (byte) 0x80;
    long bitLength = (long) input.length * 8L;
    for (int index = 0; index < 8; index++) {
      padded[padded.length - 8 + index] = (byte) (bitLength >>> (8 * index));
    }
    return padded;
  }

  private static void compress(int[] h, int[] x) {
    int al = h[0], bl = h[1], cl = h[2], dl = h[3], el = h[4];
    int ar = al, br = bl, cr = cl, dr = dl, er = el;
    for (int round = 0; round < 80; round++) {
      int tl = Integer.rotateLeft(al + f(round, bl, cl, dl) + x[RL[round]] + kl(round), SL[round]) + el;
      al = el;
      el = dl;
      dl = Integer.rotateLeft(cl, 10);
      cl = bl;
      bl = tl;

      int tr = Integer.rotateLeft(ar + f(79 - round, br, cr, dr) + x[RR[round]] + kr(round), SR[round]) + er;
      ar = er;
      er = dr;
      dr = Integer.rotateLeft(cr, 10);
      cr = br;
      br = tr;
    }
    int t = h[1] + cl + dr;
    h[1] = h[2] + dl + er;
    h[2] = h[3] + el + ar;
    h[3] = h[4] + al + br;
    h[4] = h[0] + bl + cr;
    h[0] = t;
  }

  private static int f(int round, int x, int y, int z) {
    if (round < 16) {
      return x ^ y ^ z;
    }
    if (round < 32) {
      return (x & y) | (~x & z);
    }
    if (round < 48) {
      return (x | ~y) ^ z;
    }
    if (round < 64) {
      return (x & z) | (y & ~z);
    }
    return x ^ (y | ~z);
  }

  private static int kl(int round) {
    if (round < 16) {
      return 0x00000000;
    }
    if (round < 32) {
      return 0x5a827999;
    }
    if (round < 48) {
      return 0x6ed9eba1;
    }
    if (round < 64) {
      return 0x8f1bbcdc;
    }
    return 0xa953fd4e;
  }

  private static int kr(int round) {
    if (round < 16) {
      return 0x50a28be6;
    }
    if (round < 32) {
      return 0x5c4dd124;
    }
    if (round < 48) {
      return 0x6d703ef3;
    }
    if (round < 64) {
      return 0x7a6d76e9;
    }
    return 0x00000000;
  }

  private static void writeLittleEndian(byte[] out, int offset, int value) {
    out[offset] = (byte) value;
    out[offset + 1] = (byte) (value >>> 8);
    out[offset + 2] = (byte) (value >>> 16);
    out[offset + 3] = (byte) (value >>> 24);
  }
}
