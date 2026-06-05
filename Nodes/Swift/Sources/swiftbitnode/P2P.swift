import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct P2PBlock {
    let height: Int
    let hash: String
    let raw: Data
}

final class TCPConnection {
    private let fd: Int32

    init(peer: String) throws {
        let parts = peer.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw SwiftBitnodeError.message("peer must be host:port")
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
#if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
#else
        hints.ai_socktype = SOCK_STREAM
#endif
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(parts[0], parts[1], &hints, &result)
        guard rc == 0, let result else {
            throw SwiftBitnodeError.message("getaddrinfo failed for \(peer)")
        }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        var connected: Int32 = -1
        while let info = cursor {
            let candidate = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if candidate >= 0 {
                if connect(candidate, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    connected = candidate
                    break
                }
                close(candidate)
            }
            cursor = info.pointee.ai_next
        }
        guard connected >= 0 else {
            throw SwiftBitnodeError.message("connect failed for \(peer)")
        }
        fd = connected
    }

    deinit {
        close(fd)
    }

    func readExact(_ count: Int) throws -> Data {
        var out = Data(count: count)
        try out.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var readTotal = 0
            while readTotal < count {
                let n = read(fd, base.advanced(by: readTotal), count - readTotal)
                if n <= 0 {
                    throw SwiftBitnodeError.message("socket read failed")
                }
                readTotal += n
            }
        }
        return out
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n <= 0 {
                    throw SwiftBitnodeError.message("socket write failed")
                }
                written += n
            }
        }
    }
}

struct P2PMessage {
    let command: String
    let payload: Data
}

final class P2PClient {
    private let connection: TCPConnection

    init(peer: String) throws {
        connection = try TCPConnection(peer: peer)
    }

    func handshake() throws {
        try send(command: "version", payload: versionPayload())
        var seenVersion = false
        var seenVerack = false
        while !seenVersion || !seenVerack {
            let message = try readMessage()
            switch message.command {
            case "version":
                seenVersion = true
                try send(command: "verack", payload: Data())
            case "verack":
                seenVerack = true
            case "ping":
                try send(command: "pong", payload: message.payload)
            default:
                break
            }
        }
        try send(command: "sendheaders", payload: Data())
    }

    func headersThrough(target: Int) throws -> [Data] {
        var hashes = [Data(Constants.genesisHash.hexToBytes().reversed())]
        while hashes.count <= target {
            try send(command: "getheaders", payload: getheadersPayload(locator: hashes.last!))
            let message = try readCommand("headers")
            let headers = try parseHeaders(message.payload)
            if headers.isEmpty {
                throw SwiftBitnodeError.message("peer returned no headers at height \(hashes.count - 1)")
            }
            for header in headers where hashes.count <= target {
                let prev = header.subdata(in: 4..<36)
                guard prev == hashes.last! else {
                    throw SwiftBitnodeError.message("header previous hash mismatch at height \(hashes.count)")
                }
                hashes.append(SHA256.doubleHash(header))
            }
        }
        return hashes
    }

    func requestBlock(hash: Data) throws -> Data {
        try send(command: "getdata", payload: getdataPayload(hash: hash))
        while true {
            let message = try readMessage()
            switch message.command {
            case "block":
                guard message.payload.count >= 80 else {
                    throw SwiftBitnodeError.message("short block payload")
                }
                let got = SHA256.doubleHash(message.payload.subdata(in: 0..<80))
                guard got == hash else {
                    continue
                }
                return message.payload
            case "notfound":
                throw SwiftBitnodeError.message("peer returned notfound")
            case "ping":
                try send(command: "pong", payload: message.payload)
            default:
                break
            }
        }
    }

    private func readCommand(_ command: String) throws -> P2PMessage {
        while true {
            let message = try readMessage()
            if message.command == command {
                return message
            }
            if message.command == "ping" {
                try send(command: "pong", payload: message.payload)
            }
        }
    }

    private func readMessage() throws -> P2PMessage {
        let header = try connection.readExact(24)
        guard header.subdata(in: 0..<4) == Constants.testnet4Magic else {
            throw SwiftBitnodeError.message("unexpected network magic")
        }
        let commandBytes = header.subdata(in: 4..<16)
        let command = String(bytes: commandBytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        var reader = ByteReader(header.subdata(in: 16..<24))
        let length = Int(try reader.uint32LE())
        let checksum = try reader.read(4)
        let payload = try connection.readExact(length)
        guard SHA256.doubleHash(payload).prefix(4) == checksum else {
            throw SwiftBitnodeError.message("checksum mismatch for \(command)")
        }
        return P2PMessage(command: command, payload: payload)
    }

    private func send(command: String, payload: Data) throws {
        var frame = Data()
        frame.append(Constants.testnet4Magic)
        var commandBytes = Data(repeating: 0, count: 12)
        let encoded = Data(command.utf8.prefix(12))
        commandBytes.replaceSubrange(0..<encoded.count, with: encoded)
        frame.append(commandBytes)
        frame.append(UInt32(payload.count).littleEndianData)
        frame.append(SHA256.doubleHash(payload).prefix(4))
        frame.append(payload)
        try connection.writeAll(frame)
    }
}

enum P2PFetcher {
    static func fetch(peer: String, target: Int, handle: (P2PBlock) throws -> Bool) throws -> Int {
        let client = try P2PClient(peer: peer)
        try client.handshake()
        let hashes = try client.headersThrough(target: target)
        var fetched = 0
        for height in 0...target {
            let raw = try client.requestBlock(hash: hashes[height])
            let hash = SHA256.doubleHash(raw.subdata(in: 0..<80)).reversedHex
            fetched += 1
            let shouldContinue = try handle(P2PBlock(height: height, hash: hash, raw: raw))
            if !shouldContinue {
                break
            }
        }
        return fetched
    }
}

private func versionPayload() -> Data {
    var out = Data()
    out.append(Int32(70016).littleEndianData)
    out.append(UInt64(1 | 8).littleEndianData)
    out.append(Int64(Date().timeIntervalSince1970).littleEndianData)
    appendNetAddr(&out)
    appendNetAddr(&out)
    out.append(UInt64(Date().timeIntervalSince1970 * 1_000_000).littleEndianData)
    appendVarBytes(&out, Data("/swiftbitnode:0.1.0/".utf8))
    out.append(Int32(0).littleEndianData)
    out.append(UInt8(0))
    return out
}

private func appendNetAddr(_ out: inout Data) {
    out.append(UInt64(1 | 8).littleEndianData)
    out.append(Data(repeating: 0, count: 16))
    out.append(UInt16(0).bigEndianData)
}

private func getheadersPayload(locator: Data) -> Data {
    var out = Data()
    out.append(Int32(70016).littleEndianData)
    appendCompactSize(&out, 1)
    out.append(locator)
    out.append(Data(repeating: 0, count: 32))
    return out
}

private func getdataPayload(hash: Data) -> Data {
    var out = Data()
    appendCompactSize(&out, 1)
    out.append(UInt32((1 << 30) | 2).littleEndianData)
    out.append(hash)
    return out
}

private func parseHeaders(_ payload: Data) throws -> [Data] {
    var reader = ByteReader(payload)
    let count = Int(try reader.compactSize())
    var headers: [Data] = []
    for _ in 0..<count {
        headers.append(try reader.read(80))
        let txnCount = try reader.compactSize()
        guard txnCount == 0 else {
            throw SwiftBitnodeError.message("headers payload has non-zero txn count")
        }
    }
    return headers
}

private func appendVarBytes(_ out: inout Data, _ value: Data) {
    appendCompactSize(&out, UInt64(value.count))
    out.append(value)
}

private func appendCompactSize(_ out: inout Data, _ value: UInt64) {
    if value < 0xfd {
        out.append(UInt8(value))
    } else if value <= 0xffff {
        out.append(UInt8(0xfd))
        out.append(UInt16(value).littleEndianData)
    } else if value <= 0xffff_ffff {
        out.append(UInt8(0xfe))
        out.append(UInt32(value).littleEndianData)
    } else {
        out.append(UInt8(0xff))
        out.append(value.littleEndianData)
    }
}

extension UInt16 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}

extension UInt32 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

extension UInt64 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

extension Int32 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

extension Int64 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}
