//! tagsdump.zig — 枚举 geo-full.zrs 里全部 IP tag（取证：非国家码标签清单）。
//! 只读容器 + 走目录段（布局镜像 zrs.zig 的 findTag 读法；校验仍经真解析器
//! Container.open / ZrsIpMatcher.init——非法格式直接拒收，不做 bytescan 猜测）。
const std = @import("std");
const zrs = @import("zrs.zig");

// zrs.zig 私有常量的镜像（格式真源在同仓 zrs.zig；此处仅读侧枚举用）。
const IP_HEADER_SIZE: usize = 24;
const OFF_ENTRY_COUNT: usize = 8;
const OFF_INDEX_OFF: usize = 12;
const OFF_DATA_OFF: usize = 16;

inline fn readU32L(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .little);
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var path: []const u8 = "dist/geo-full.zrs";
    var query_ip: ?[]const u8 = null;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
        defer it.deinit();
        _ = it.next();
        if (it.next()) |p| path = p;
        if (it.next()) |q| query_ip = q;
    }

    const mem = try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .unlimited);
    const c = try zrs.Container.open(mem); // 真解析器校验（KZF1 布局/截断拒收）
    const im = try c.ipMatcher(); // ZRS2 头校验
    const m = im.mem;

    const n = readU32L(m[OFF_ENTRY_COUNT..]);
    const idx_off = readU32L(m[OFF_INDEX_OFF..]);
    const data_off = readU32L(m[OFF_DATA_OFF..]);
    if (idx_off + 4 * @as(usize, n) > m.len or data_off > m.len) return error.InvalidFormat;

    const tags_base = idx_off + 4 * @as(usize, n);
    var non_country: usize = 0;
    var country: usize = 0;
    std.debug.print("entry_count={d}\n", .{n});
    var tags_buf: std.ArrayList([]const u8) = .empty;
    for (0..n) |i| {
        const rel = readU32L(m[idx_off + 4 * i ..]);
        const p = tags_base + rel;
        if (p >= m.len) return error.InvalidFormat;
        const tl = m[p];
        if (p + 1 + tl + 16 > m.len) return error.InvalidFormat;
        const tag = m[p + 1 ..][0..tl];
        const f = p + 1 + tl;
        const v4n = readU32L(m[f..]);
        const v6n = readU32L(m[f + 8 ..]);
        const is_country = tl == 2 and std.ascii.isAlphabetic(tag[0]) and std.ascii.isAlphabetic(tag[1]);
        try tags_buf.append(alloc, tag);
        if (is_country) {
            country += 1;
        } else {
            non_country += 1;
            std.debug.print("NON-COUNTRY tag={s} v4={d} v6={d}\n", .{ tag, v4n, v6n });
        }
    }
    std.debug.print("summary: country={d} non_country={d}\n", .{ country, non_country });

    // 可选：查一个 IP 命中哪些 tag（组织 tag 与国家码是否重叠的实证）。
    if (query_ip) |qs| {
        var parts = std.mem.splitScalar(u8, qs, '.');
        var b: [4]u8 = undefined;
        var i: usize = 0;
        while (parts.next()) |seg| : (i += 1) {
            if (i >= 4) return error.BadIp;
            b[i] = std.fmt.parseInt(u8, seg, 10) catch return error.BadIp;
        }
        if (i != 4) return error.BadIp;
        const ip: zrs.IpAddr = .{ .v4 = b };
        for (tags_buf.items) |t| {
            if (im.contains(t, ip)) std.debug.print("HIT {s} <- {s}\n", .{ t, qs });
        }
    }
}
