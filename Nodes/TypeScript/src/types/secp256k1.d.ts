declare module "secp256k1" {
  export function publicKeyVerify(publicKey: Uint8Array): boolean;
  export function signatureImport(signature: Uint8Array): Uint8Array;
  export function signatureNormalize(signature: Uint8Array): Uint8Array;
  export function ecdsaVerify(signature: Uint8Array, message: Uint8Array, publicKey: Uint8Array): boolean;
}
