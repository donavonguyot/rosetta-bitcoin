const std = @import("std");
const crypto = @import("crypto.zig");
const tx = @import("tx.zig");
const chain_params = @import("chain_params.zig");
const consensus_context = @import("consensus_context.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("netdb.h");
    @cInclude("netinet/tcp.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/time.h");
    @cInclude("unistd.h");
});

const FieldHeaders = struct {
    items: []const consensus_context.HeaderFields,
    pub fn header(self: @This(), height: u32) !consensus_context.HeaderFields {
        if (height >= self.items.len) return error.MissingHeader;
        return self.items[height];
    }
};

const PROTOCOL_VERSION: i32 = 70016;
const SERVICES: u64 = 1 | 8;
const TESTNET4_MAGIC = [_]u8{ 0x1c, 0x16, 0x3f, 0x28 };
const MSG_WITNESS_BLOCK: u32 = (1 << 30) | 2;
const GENESIS_HASH = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043";
const MAX_PAYLOAD: usize = 64 * 1024 * 1024;

pub const FetchedBlock = struct {
    height: u32,
    hash: [32]u8,
    raw: []u8,

    pub fn deinit(self: FetchedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};

pub const Client = struct {
    fd: c_int,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, peer: []const u8) !Client {
        const split = std.mem.lastIndexOfScalar(u8, peer, ':') orelse return error.InvalidPeer;
        const host = peer[0..split];
        const port = peer[split + 1 ..];
        if (host.len == 0 or port.len == 0) return error.InvalidPeer;

        const host_z = try allocator.dupeZ(u8, host);
        defer allocator.free(host_z);
        const port_z = try allocator.dupeZ(u8, port);
        defer allocator.free(port_z);

        var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
        hints.ai_family = c.AF_UNSPEC;
        hints.ai_socktype = c.SOCK_STREAM;
        hints.ai_protocol = c.IPPROTO_TCP;
        var result: ?*c.struct_addrinfo = null;
        if (c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &result) != 0) return error.PeerResolveFailed;
        defer c.freeaddrinfo(result);

        var cursor = result;
        while (cursor) |info| : (cursor = info.ai_next) {
            const fd = c.socket(info.ai_family, info.ai_socktype, info.ai_protocol);
            if (fd < 0) continue;
            setSocketOptions(fd);
            if (c.connect(fd, info.ai_addr, info.ai_addrlen) == 0) {
                return .{ .fd = fd, .allocator = allocator };
            }
            _ = c.close(fd);
        }
        return error.PeerConnectFailed;
    }

    pub fn close(self: *Client) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn handshake(self: *Client, start_height: u32) !void {
        const payload = try versionPayload(self.allocator, start_height);
        defer self.allocator.free(payload);
        try self.send("version", payload);
        var seen_version = false;
        var seen_verack = false;
        while (!seen_version or !seen_verack) {
            const msg = try self.readMessage();
            defer msg.deinit(self.allocator);
            if (std.mem.eql(u8, msg.command, "version")) {
                seen_version = true;
                try self.send("verack", &.{});
            } else if (std.mem.eql(u8, msg.command, "verack")) {
                seen_verack = true;
            } else if (std.mem.eql(u8, msg.command, "ping")) {
                try self.send("pong", msg.payload);
            }
        }
        try self.send("sendheaders", &.{});
    }

    pub fn headersThrough(self: *Client, target: u32) ![][32]u8 {
        var hashes = std.ArrayList([32]u8).empty;
        errdefer hashes.deinit(self.allocator);
        var fields = std.ArrayList(consensus_context.HeaderFields).empty;
        defer fields.deinit(self.allocator);
        try hashes.append(self.allocator, try crypto.internalHashFromDisplay(self.allocator, GENESIS_HASH));
        try fields.append(self.allocator, .{ .time = chain_params.genesis_time, .bits = chain_params.genesis_bits });
        while (hashes.items.len <= target) {
            const payload = try getHeadersPayload(self.allocator, hashes.items[hashes.items.len - 1]);
            defer self.allocator.free(payload);
            try self.send("getheaders", payload);
            const msg = try self.readCommand("headers");
            defer msg.deinit(self.allocator);
            const headers = try parseHeaders(self.allocator, msg.payload);
            defer self.allocator.free(headers);
            if (headers.len == 0) return error.EmptyHeadersResponse;
            for (headers) |header| {
                if (hashes.items.len > target) break;
                if (!std.mem.eql(u8, header[4..36], hashes.items[hashes.items.len - 1][0..])) return error.HeaderPrevMismatch;
                const height: u32 = @intCast(fields.items.len);
                const view = consensus_context.fieldsFromHeader(&header);
                const required = try consensus_context.requiredBits(FieldHeaders{ .items = fields.items }, height, view.time);
                if (view.bits != required) return error.NbitsMismatch;
                if (!checkHeaderProofOfWork(header)) return error.HeaderPowInvalid;
                if (consensus_context.timewarpViolation(height, view.time, fields.items[height - 1].time)) return error.Timewarp;
                try fields.append(self.allocator, view);
                try hashes.append(self.allocator, crypto.doubleSha256(header[0..]));
            }
        }
        return hashes.toOwnedSlice(self.allocator);
    }

    pub fn requestBlocks(self: *Client, hashes: []const [32]u8, start_height: u32) ![]FetchedBlock {
        const payload = try getDataPayload(self.allocator, hashes);
        defer self.allocator.free(payload);
        try self.send("getdata", payload);

        var blocks = try self.allocator.alloc(FetchedBlock, hashes.len);
        errdefer self.allocator.free(blocks);
        var filled = try self.allocator.alloc(bool, hashes.len);
        defer self.allocator.free(filled);
        @memset(filled, false);

        var remaining = hashes.len;
        while (remaining > 0) {
            const msg = try self.readMessage();
            defer msg.deinit(self.allocator);
            if (std.mem.eql(u8, msg.command, "ping")) {
                try self.send("pong", msg.payload);
                continue;
            }
            if (std.mem.eql(u8, msg.command, "notfound")) return error.BlockNotFound;
            if (!std.mem.eql(u8, msg.command, "block")) continue;
            if (msg.payload.len < 80) return error.ShortBlockPayload;
            const hash = crypto.doubleSha256(msg.payload[0..80]);
            for (hashes, 0..) |expected, i| {
                if (!filled[i] and std.mem.eql(u8, expected[0..], hash[0..])) {
                    blocks[i] = .{
                        .height = start_height + @as(u32, @intCast(i)),
                        .hash = hash,
                        .raw = try self.allocator.dupe(u8, msg.payload),
                    };
                    filled[i] = true;
                    remaining -= 1;
                    break;
                }
            }
        }
        return blocks;
    }

    fn readCommand(self: *Client, command: []const u8) !Message {
        while (true) {
            const msg = try self.readMessage();
            if (std.mem.eql(u8, msg.command, command)) return msg;
            if (std.mem.eql(u8, msg.command, "ping")) {
                try self.send("pong", msg.payload);
            }
            msg.deinit(self.allocator);
        }
    }

    fn readMessage(self: *Client) !Message {
        var header: [24]u8 = undefined;
        try self.readExact(&header);
        if (!std.mem.eql(u8, header[0..4], TESTNET4_MAGIC[0..])) return error.UnexpectedNetworkMagic;
        const command_len = std.mem.indexOfScalar(u8, header[4..16], 0) orelse 12;
        const command = try self.allocator.dupe(u8, header[4 .. 4 + command_len]);
        errdefer self.allocator.free(command);
        const length = std.mem.readInt(u32, header[16..20], .little);
        if (length > MAX_PAYLOAD) return error.PayloadTooLarge;
        const payload = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(payload);
        try self.readExact(payload);
        const checksum = crypto.doubleSha256(payload)[0..4];
        if (!std.mem.eql(u8, checksum, header[20..24])) return error.MessageChecksumMismatch;
        return .{ .command = command, .payload = payload };
    }

    fn send(self: *Client, command: []const u8, payload: []const u8) !void {
        if (command.len > 12) return error.CommandTooLong;
        var header = [_]u8{0} ** 24;
        @memcpy(header[0..4], TESTNET4_MAGIC[0..]);
        @memcpy(header[4 .. 4 + command.len], command);
        std.mem.writeInt(u32, header[16..20], @intCast(payload.len), .little);
        const checksum = crypto.doubleSha256(payload);
        @memcpy(header[20..24], checksum[0..4]);
        try self.writeAll(&header);
        try self.writeAll(payload);
    }

    fn readExact(self: *Client, out: []u8) !void {
        var offset: usize = 0;
        while (offset < out.len) {
            const n = c.recv(self.fd, out[offset..].ptr, out.len - offset, 0);
            if (n == 0) return error.PeerDisconnected;
            if (n < 0) return error.SocketReadFailed;
            offset += @intCast(n);
        }
    }

    fn writeAll(self: *Client, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = c.send(self.fd, bytes[offset..].ptr, bytes.len - offset, 0);
            if (n <= 0) return error.SocketWriteFailed;
            offset += @intCast(n);
        }
    }
};

const Message = struct {
    command: []u8,
    payload: []u8,

    fn deinit(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        allocator.free(self.payload);
    }
};

fn setSocketOptions(fd: c_int) void {
    var no_delay: c_int = 1;
    _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &no_delay, @sizeOf(c_int));
    var read_timeout = c.struct_timeval{ .tv_sec = 120, .tv_usec = 0 };
    var write_timeout = c.struct_timeval{ .tv_sec = 30, .tv_usec = 0 };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &read_timeout, @sizeOf(c.struct_timeval));
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &write_timeout, @sizeOf(c.struct_timeval));
}

fn versionPayload(allocator: std.mem.Allocator, start_height: u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendI32Le(allocator, &out, PROTOCOL_VERSION);
    try appendU64Le(allocator, &out, SERVICES);
    try appendI64Le(allocator, &out, 0);
    try appendNetAddress(allocator, &out);
    try appendNetAddress(allocator, &out);
    try appendU64Le(allocator, &out, 0x7a69676269746e30);
    const agent = "/zigbitnode:0.1.0/";
    try tx.writeCompactSize(allocator, &out, agent.len);
    try out.appendSlice(allocator, agent);
    try appendI32Le(allocator, &out, @intCast(start_height));
    try out.append(allocator, 0);
    return out.toOwnedSlice(allocator);
}

fn appendNetAddress(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try appendU64Le(allocator, out, SERVICES);
    try out.appendNTimes(allocator, 0, 16);
    try out.appendSlice(allocator, &.{ 0, 0 });
}

fn getHeadersPayload(allocator: std.mem.Allocator, locator: [32]u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendI32Le(allocator, &out, PROTOCOL_VERSION);
    try tx.writeCompactSize(allocator, &out, 1);
    try out.appendSlice(allocator, locator[0..]);
    try out.appendNTimes(allocator, 0, 32);
    return out.toOwnedSlice(allocator);
}

fn getDataPayload(allocator: std.mem.Allocator, hashes: []const [32]u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try tx.writeCompactSize(allocator, &out, hashes.len);
    for (hashes) |hash| {
        try appendU32Le(allocator, &out, MSG_WITNESS_BLOCK);
        try out.appendSlice(allocator, hash[0..]);
    }
    return out.toOwnedSlice(allocator);
}

fn parseHeaders(allocator: std.mem.Allocator, payload: []const u8) ![][80]u8 {
    const count_result = try tx.readCompactSize(payload, 0);
    var offset = count_result.offset;
    const count: usize = @intCast(count_result.value);
    const headers = try allocator.alloc([80]u8, count);
    errdefer allocator.free(headers);
    for (headers) |*header| {
        if (offset + 80 > payload.len) return error.TruncatedHeadersPayload;
        @memcpy(header, payload[offset .. offset + 80]);
        offset += 80;
        const tx_count = try tx.readCompactSize(payload, offset);
        if (tx_count.value != 0) return error.HeadersTxCountNonZero;
        offset = tx_count.offset;
    }
    if (offset != payload.len) return error.HeadersTrailingBytes;
    return headers;
}

fn checkHeaderProofOfWork(header: [80]u8) bool {
    const hash = crypto.doubleSha256(header[0..]);
    const bits = std.mem.readInt(u32, header[72..76], .little);
    return checkProofOfWork(hash, bits);
}

fn checkProofOfWork(hash_internal: [32]u8, bits: u32) bool {
    const target = compactTargetLe(bits) catch return false;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        if (hash_internal[i] < target[i]) return true;
        if (hash_internal[i] > target[i]) return false;
    }
    return true;
}

fn compactTargetLe(bits: u32) ![32]u8 {
    const exponent: usize = @intCast(bits >> 24);
    const mantissa = bits & 0x007f_ffff;
    if ((bits & 0x0080_0000) != 0 or mantissa == 0) return error.InvalidCompactTarget;
    var target = [_]u8{0} ** 32;
    const mantissa_bytes = [_]u8{
        @intCast((mantissa >> 16) & 0xff),
        @intCast((mantissa >> 8) & 0xff),
        @intCast(mantissa & 0xff),
    };
    if (exponent <= 3) {
        var value = mantissa >> @intCast(8 * (3 - exponent));
        var index: usize = 0;
        while (value > 0 and index < 32) : (index += 1) {
            target[index] = @intCast(value & 0xff);
            value >>= 8;
        }
    } else {
        const start = exponent - 3;
        if (start + 3 > 32) return error.TargetOverflow;
        target[start] = mantissa_bytes[2];
        target[start + 1] = mantissa_bytes[1];
        target[start + 2] = mantissa_bytes[0];
    }
    return target;
}

fn appendU32Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendI32Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @bitCast(value), .little);
    try out.appendSlice(allocator, &buf);
}

fn appendU64Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendI64Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(value), .little);
    try out.appendSlice(allocator, &buf);
}

test "getdata payload uses witness block inventory" {
    const allocator = std.testing.allocator;
    const hash = [_]u8{0xab} ** 32;
    const payload = try getDataPayload(allocator, &.{hash});
    defer allocator.free(payload);
    try std.testing.expectEqual(@as(u8, 1), payload[0]);
    try std.testing.expectEqual(@as(u32, MSG_WITNESS_BLOCK), std.mem.readInt(u32, payload[1..5], .little));
    try std.testing.expectEqualSlices(u8, hash[0..], payload[5..37]);
}
