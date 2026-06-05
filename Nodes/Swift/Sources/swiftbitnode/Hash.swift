import Foundation

enum Hash {
    static func hash160(_ data: Data) -> Data {
        RIPEMD160.hash(SHA256.hash(data))
    }

    static func sha1(_ data: Data) -> Data {
        SHA1.hash(data)
    }
}

enum SHA1 {
    static func hash(_ data: Data) -> Data {
        var message = Data(data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0x00)
        }
        message.append(bitLength.bigEndianData)
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xefcdab89
        var h2: UInt32 = 0x98badcfe
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xc3d2e1f0
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            let chunk = message.subdata(in: chunkStart..<(chunkStart + 64))
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let start = i * 4
                w[i] = UInt32(chunk[start]) << 24 | UInt32(chunk[start + 1]) << 16 | UInt32(chunk[start + 2]) << 8 | UInt32(chunk[start + 3])
            }
            for i in 16..<80 {
                w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0...19: f = (b & c) | ((~b) & d); k = 0x5a827999
                case 20...39: f = b ^ c ^ d; k = 0x6ed9eba1
                case 40...59: f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc
                default: f = b ^ c ^ d; k = 0xca62c1d6
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotateLeft(b, 30); b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        var out = Data()
        for h in [h0, h1, h2, h3, h4] {
            out.append(h.bigEndianData)
        }
        return out
    }

    private static func rotateLeft(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value << bits) | (value >> (32 - bits))
    }
}

enum RIPEMD160 {
    static func hash(_ data: Data) -> Data {
        var message = Data(data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0x00)
        }
        message.append(bitLength.littleEndianData)

        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xefcdab89
        var h2: UInt32 = 0x98badcfe
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xc3d2e1f0

        let r1: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8, 3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12, 1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2, 4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13]
        let r2: [Int] = [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, 6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2, 15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13, 8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14, 12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11]
        let s1: [UInt32] = [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8, 7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12, 11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5, 11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12, 9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6]
        let s2: [UInt32] = [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6, 9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11, 9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5, 15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8, 8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11]

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            let chunk = message.subdata(in: chunkStart..<(chunkStart + 64))
            var x = [UInt32]()
            for i in 0..<16 {
                let start = i * 4
                x.append(UInt32(chunk[start]) | UInt32(chunk[start + 1]) << 8 | UInt32(chunk[start + 2]) << 16 | UInt32(chunk[start + 3]) << 24)
            }
            var al = h0, bl = h1, cl = h2, dl = h3, el = h4
            var ar = h0, br = h1, cr = h2, dr = h3, er = h4
            for j in 0..<80 {
                let tl = rotateLeft(al &+ f(j, bl, cl, dl) &+ x[r1[j]] &+ kl(j), s1[j]) &+ el
                al = el; el = dl; dl = rotateLeft(cl, 10); cl = bl; bl = tl
                let tr = rotateLeft(ar &+ f(79 - j, br, cr, dr) &+ x[r2[j]] &+ kr(j), s2[j]) &+ er
                ar = er; er = dr; dr = rotateLeft(cr, 10); cr = br; br = tr
            }
            let t = h1 &+ cl &+ dr
            h1 = h2 &+ dl &+ er
            h2 = h3 &+ el &+ ar
            h3 = h4 &+ al &+ br
            h4 = h0 &+ bl &+ cr
            h0 = t
        }
        var out = Data()
        for h in [h0, h1, h2, h3, h4] {
            out.append(h.littleEndianData)
        }
        return out
    }

    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0...15: return x ^ y ^ z
        case 16...31: return (x & y) | (~x & z)
        case 32...47: return (x | ~y) ^ z
        case 48...63: return (x & z) | (y & ~z)
        default: return x ^ (y | ~z)
        }
    }

    private static func kl(_ j: Int) -> UInt32 {
        switch j {
        case 0...15: return 0x00000000
        case 16...31: return 0x5a827999
        case 32...47: return 0x6ed9eba1
        case 48...63: return 0x8f1bbcdc
        default: return 0xa953fd4e
        }
    }

    private static func kr(_ j: Int) -> UInt32 {
        switch j {
        case 0...15: return 0x50a28be6
        case 16...31: return 0x5c4dd124
        case 32...47: return 0x6d703ef3
        case 48...63: return 0x7a6d76e9
        default: return 0x00000000
        }
    }

    private static func rotateLeft(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value << bits) | (value >> (32 - bits))
    }
}

extension UInt32 {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}

extension UInt64 {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
