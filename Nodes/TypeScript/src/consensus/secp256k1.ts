import { createHash } from "node:crypto";

/** secp256k1 curve parameters (mirrors pybitnode/consensus/secp256k1.py). */
export const P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2Fn;
export const N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141n;
export const A = 0n;
export const B = 7n;
export const Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798n;
export const Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8n;

type Point = readonly [bigint, bigint];
type NullablePoint = Point | null;

export class Secp256k1Error extends Error {
  constructor(message: string) {
    super(message);
    this.name = "Secp256k1Error";
  }
}

function mod(value: bigint, modulus: bigint): bigint {
  const result = value % modulus;
  return result >= 0n ? result : result + modulus;
}

function modPow(base: bigint, exponent: bigint, modulus: bigint): bigint {
  let result = 1n;
  let b = mod(base, modulus);
  let exp = exponent;
  while (exp > 0n) {
    if (exp & 1n) {
      result = mod(result * b, modulus);
    }
    b = mod(b * b, modulus);
    exp >>= 1n;
  }
  return result;
}

function modinv(value: bigint, modulus: bigint): bigint {
  return modPow(mod(value, modulus), modulus - 2n, modulus);
}

function decompressPubkey(data: Buffer): Point {
  if (data.length === 33 && (data[0] === 2 || data[0] === 3)) {
    const x = BigInt(`0x${data.subarray(1).toString("hex")}`);
    const ySquared = mod(modPow(x, 3n, P) + B, P);
    let y = modPow(ySquared, (P + 1n) / 4n, P);
    if ((y % 2n === 0n) !== (data[0] === 2)) {
      y = P - y;
    }
    return [x, y];
  }
  if (data.length === 65 && data[0] === 4) {
    const x = BigInt(`0x${data.subarray(1, 33).toString("hex")}`);
    const y = BigInt(`0x${data.subarray(33, 65).toString("hex")}`);
    return [x, y];
  }
  throw new Secp256k1Error("invalid public key encoding");
}

function pointAdd(p1: NullablePoint, p2: NullablePoint): NullablePoint {
  if (p1 === null) return p2;
  if (p2 === null) return p1;
  const [x1, y1] = p1;
  const [x2, y2] = p2;
  if (x1 === x2 && mod(y1 + y2, P) === 0n) {
    return null;
  }
  let slope: bigint;
  if (p1[0] === p2[0] && p1[1] === p2[1]) {
    slope = mod((3n * x1 * x1 + A) * modinv(2n * y1, P), P);
  } else {
    slope = mod((y2 - y1) * modinv(x2 - x1, P), P);
  }
  const x3 = mod(slope * slope - x1 - x2, P);
  const y3 = mod(slope * (x1 - x3) - y1, P);
  return [x3, y3];
}

export function scalarMult(k: bigint, point: Point): NullablePoint {
  let result: NullablePoint = null;
  let addend: NullablePoint = point;
  let scalar = k;
  while (scalar > 0n) {
    if (scalar & 1n) {
      result = pointAdd(result, addend);
    }
    addend = pointAdd(addend, addend);
    scalar >>= 1n;
  }
  return result;
}

function parseDerSignature(data: Buffer): [bigint, bigint] {
  if (data.length < 8 || data[0] !== 0x30) {
    throw new Secp256k1Error("invalid DER signature");
  }
  if (data[1]! + 2 !== data.length) {
    throw new Secp256k1Error("invalid DER signature length");
  }
  if (data[2] !== 0x02) {
    throw new Secp256k1Error("invalid DER signature r marker");
  }
  const rLen = data[3]!;
  const r = BigInt(`0x${data.subarray(4, 4 + rLen).toString("hex")}`);
  let offset = 4 + rLen;
  if (data[offset] !== 0x02) {
    throw new Secp256k1Error("invalid DER signature s marker");
  }
  const sLen = data[offset + 1]!;
  const s = BigInt(`0x${data.subarray(offset + 2, offset + 2 + sLen).toString("hex")}`);
  if (r <= 0n || s <= 0n || r >= N || s >= N) {
    throw new Secp256k1Error("signature r/s out of range");
  }
  return [r, s];
}

export function liftXOnlyPubkey(xCoord: bigint): NullablePoint {
  if (xCoord >= P) {
    return null;
  }
  const ySquared = mod(modPow(xCoord, 3n, P) + B, P);
  let y = modPow(ySquared, (P + 1n) / 4n, P);
  if (modPow(y, 2n, P) !== ySquared) {
    return null;
  }
  if (y & 1n) {
    y = P - y;
  }
  return [xCoord, y];
}

function hasEvenY(point: Point): boolean {
  return point[1] % 2n === 0n;
}

function bitcoinTaggedHash(tag: string, msg: Buffer): Buffer {
  const tagDigest = createHash("sha256").update(tag, "utf8").digest();
  return createHash("sha256").update(Buffer.concat([tagDigest, tagDigest, msg])).digest();
}

export function taprootTweakPubkeyXonly(
  internalXonly: Buffer,
  merkleRoot: Buffer,
): [parity: number, outputXonly: Buffer] {
  if (internalXonly.length !== 32) {
    throw new Secp256k1Error("internal key must be 32 bytes");
  }
  const tweak = bitcoinTaggedHash("TapTweak", Buffer.concat([internalXonly, merkleRoot]));
  const t = BigInt(`0x${tweak.toString("hex")}`);
  if (t >= N) {
    throw new Secp256k1Error("TapTweak out of range");
  }
  const xInt = BigInt(`0x${internalXonly.toString("hex")}`);
  const pPt = liftXOnlyPubkey(xInt);
  if (pPt === null) {
    throw new Secp256k1Error("invalid internal x-only key");
  }
  const gPoint: Point = [Gx, Gy];
  const qPt = pointAdd(pPt, scalarMult(t, gPoint));
  if (qPt === null) {
    throw new Secp256k1Error("taproot tweak failed");
  }
  const [xq, yq] = qPt;
  const parity = yq % 2n === 0n ? 0 : 1;
  return [parity, bigintTo32Bytes(xq)];
}

export function verifySchnorrSignature(
  pubkeyXonly: Buffer,
  messageHash: Buffer,
  signature: Buffer,
): boolean {
  if (pubkeyXonly.length !== 32 || messageHash.length !== 32 || signature.length !== 64) {
    return false;
  }
  try {
    const xPub = BigInt(`0x${pubkeyXonly.toString("hex")}`);
    const pubkeyPoint = liftXOnlyPubkey(xPub);
    if (pubkeyPoint === null) {
      return false;
    }
    const rx = BigInt(`0x${signature.subarray(0, 32).toString("hex")}`);
    const s = BigInt(`0x${signature.subarray(32).toString("hex")}`);
    if (rx >= P || s >= N) {
      return false;
    }
    const e = mod(
      BigInt(
        `0x${bitcoinTaggedHash("BIP0340/challenge", Buffer.concat([signature.subarray(0, 32), pubkeyXonly, messageHash])).toString("hex")}`,
      ),
      N,
    );
    const gPoint: Point = [Gx, Gy];
    const lhs = scalarMult(s, gPoint);
    const rhsAdj = scalarMult(mod(N - e, N), pubkeyPoint);
    const rPt = pointAdd(lhs, rhsAdj);
    if (rPt === null) {
      return false;
    }
    const [xr, yr] = rPt;
    return hasEvenY([xr, yr]) && mod(xr, P) === mod(rx, P);
  } catch {
    return false;
  }
}

export function signBip340Schnorr(secretKey: bigint, message: Buffer): Buffer {
  const d0 = mod(secretKey, N);
  if (d0 <= 0n || d0 >= N) {
    throw new Secp256k1Error("invalid secret key");
  }
  const gPoint: Point = [Gx, Gy];
  let pPoint = scalarMult(d0, gPoint);
  if (pPoint === null) {
    throw new Secp256k1Error("invalid public point");
  }
  let d = d0;
  if (!hasEvenY(pPoint)) {
    d = N - d;
    pPoint = scalarMult(d, gPoint);
    if (pPoint === null) {
      throw new Secp256k1Error("invalid public point");
    }
  }
  const pkXBytes = bigintTo32Bytes(pPoint[0]);
  const dBytes = bigintTo32Bytes(d);

  const auxRand = createHash("sha256")
    .update(Buffer.concat([Buffer.from("pbn(aux)"), dBytes, message]))
    .digest();
  const auxHash = bitcoinTaggedHash("BIP0340/aux", auxRand);
  const t = Buffer.alloc(32);
  for (let index = 0; index < 32; index++) {
    t[index] = dBytes[index]! ^ auxHash[index]!;
  }
  const k0 = mod(
    BigInt(
      `0x${bitcoinTaggedHash("BIP0340/nonce", Buffer.concat([t, pkXBytes, message])).toString("hex")}`,
    ),
    N,
  );
  if (k0 === 0n) {
    throw new Secp256k1Error("signing failure (retry)");
  }
  const rPoint = scalarMult(k0, gPoint);
  if (rPoint === null) {
    throw new Secp256k1Error("signing failure (retry)");
  }
  const k = hasEvenY(rPoint) ? k0 : N - k0;
  const rBytes = bigintTo32Bytes(rPoint[0]);
  const e = mod(
    BigInt(
      `0x${bitcoinTaggedHash("BIP0340/challenge", Buffer.concat([rBytes, pkXBytes, message])).toString("hex")}`,
    ),
    N,
  );
  const sig = Buffer.concat([rBytes, bigintTo32Bytes(mod(k + e * d, N))]);
  if (!verifySchnorrSignature(pkXBytes, message, sig)) {
    throw new Secp256k1Error("internal Schnorr signing failed sanity check");
  }
  return sig;
}

export function verifyDerSignature(
  pubkey: Buffer,
  messageHash: Buffer,
  signature: Buffer,
): boolean {
  if (messageHash.length !== 32) {
    throw new Secp256k1Error("message hash must be 32 bytes");
  }
  try {
    const [r, s] = parseDerSignature(signature);
    const [qx, qy] = decompressPubkey(pubkey);
    const z = BigInt(`0x${messageHash.toString("hex")}`);
    const w = modinv(s, N);
    const u1 = mod(z * w, N);
    const u2 = mod(r * w, N);
    const gPoint: Point = [Gx, Gy];
    const qPoint: Point = [qx, qy];
    const point = pointAdd(scalarMult(u1, gPoint), scalarMult(u2, qPoint));
    if (point === null) {
      return false;
    }
    const [x] = point;
    return mod(x, N) === r;
  } catch (error) {
    if (error instanceof Secp256k1Error) {
      return false;
    }
    throw error;
  }
}

function bigintTo32Bytes(value: bigint): Buffer {
  return Buffer.from(value.toString(16).padStart(64, "0"), "hex");
}

function stripLeadingZeros(bytes: Buffer): Buffer {
  let start = 0;
  while (start < bytes.length - 1 && bytes[start] === 0) {
    start += 1;
  }
  return bytes.subarray(start);
}

export function signDer(privateKey: bigint, messageHash: Buffer): Buffer {
  if (!(privateKey > 0n && privateKey < N)) {
    throw new Secp256k1Error("invalid private key");
  }
  if (messageHash.length !== 32) {
    throw new Secp256k1Error("message hash must be 32 bytes");
  }
  const z = BigInt(`0x${messageHash.toString("hex")}`);
  const gPoint: Point = [Gx, Gy];
  for (let nonce = 1; nonce < 1000; nonce++) {
    const k = BigInt(nonce);
    const point = scalarMult(k, gPoint);
    if (point === null) {
      continue;
    }
    const r = mod(point[0], N);
    if (r === 0n) {
      continue;
    }
    let s = mod(modinv(k, N) * (z + r * privateKey), N);
    if (s === 0n) {
      continue;
    }
    if (s > N / 2n) {
      s = N - s;
    }
    const rBytes = stripLeadingZeros(bigintTo32Bytes(r));
    const sBytes = stripLeadingZeros(bigintTo32Bytes(s));
    return Buffer.concat([
      Buffer.from([0x30, 4 + rBytes.length + sBytes.length, 0x02, rBytes.length]),
      rBytes,
      Buffer.from([0x02, sBytes.length]),
      sBytes,
    ]);
  }
  throw new Secp256k1Error("failed to sign message");
}
