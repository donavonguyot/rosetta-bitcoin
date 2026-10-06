const std = @import("std");
const types = @import("types.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/time.h");
    @cInclude("time.h");
});

const PortInfo = types.PortInfo;

pub fn nowMs() i64 {
    var tv: c.struct_timeval = undefined;
    if (c.gettimeofday(&tv, null) != 0) return 0;
    return @as(i64, @intCast(tv.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.tv_usec)), 1000);
}

pub fn rejectUnapprovedRuntimeDbArtifacts(path: []const u8) !void {
    const datadir = std.fs.path.dirname(path) orelse path;
    const datadir_z = try std.heap.c_allocator.dupeZ(u8, datadir);
    defer std.heap.c_allocator.free(datadir_z);
    const dir = c.opendir(datadir_z.ptr) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.ascii.endsWithIgnoreCase(name, ".db") or
            std.ascii.endsWithIgnoreCase(name, ".sqlite") or
            std.ascii.endsWithIgnoreCase(name, ".sqlite3"))
        {
            return error.ForbiddenRuntimeDbArtifact;
        }
    }
}

pub const DatadirLock = struct {
    fd: std.c.fd_t,

    pub fn acquire(allocator: std.mem.Allocator, datadir: []const u8) !DatadirLock {
        const path = try std.fs.path.join(allocator, &.{ datadir, PortInfo.lock_file });
        defer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = std.c.open(path_z, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
        }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.DatadirLock;
        if (std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
            _ = std.c.close(fd);
            return error.DatadirBusy;
        }
        return .{ .fd = fd };
    }

    pub fn release(self: DatadirLock) void {
        _ = std.c.flock(self.fd, std.posix.LOCK.UN);
        _ = std.c.close(self.fd);
    }
};
