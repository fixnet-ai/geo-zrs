//! memprobe.zig — zrs 容器装载的内存形态探针（mmap vs 全量读入的运行时实证）。
//!
//! 用真实 geo-full.zrs（~15MB）分阶段推进并打 MARK（每阶段留采样窗），外部
//! 脚本并行采 ps rss + Darwin footprint（phys_footprint = iOS jetsam 同口径，
//! clean file-backed 页不计入）：
//!   MARK mapped   —— mmap 建立后（未触达：RSS 增量应 ≈0，惰性映射）
//!   MARK header   —— Container.open + 两 matcher init（只碰头页/索引头部）
//!   MARK few      —— 点查 5 域（少量缺页）
//!   MARK all-tags —— 全部 1563 tag 存在性扫描（触达索引区）
//!   MARK sweep    —— 每 tag 点查一域（深度触达数据区；RSS 可接近文件大小，
//!                    但 footprint 应始终近零——clean 页可回收、不进 jetsam 账）
//! 对照判据：若实现是全量读入，MARK mapped 处 RSS 即 +15MB。
//!
//! 构建期工具：同步 IO/extern libc mmap 允许（非引擎运行时）。

const std = @import("std");
const zrs = @import("zrs.zig");

const PROT_READ: c_int = 0x1;
const MAP_PRIVATE: c_int = 0x02;

extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

fn mark(name: []const u8) void {
    std.debug.print("MARK {s}\n", .{name});
}

pub fn main(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, std.heap.page_allocator);
    defer it.deinit();
    _ = it.next();
    const path = it.next() orelse {
        std.debug.print("usage: memprobe <geo-full.zrs>\n", .{});
        return error.MissingPath;
    };
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);

    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    const f = try std.Io.Dir.cwd().openFile(io, path_z, .{});
    const st = try f.stat(io);
    const size: usize = @intCast(st.size);
    const fd: c_int = @intCast(f.handle);
    std.debug.print("file={s} size={d}KB\n", .{ path, size / 1024 });

    const mem_p = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0) orelse return error.MmapFailed;
    const mem: []const u8 = @as([*]const u8, @ptrCast(mem_p))[0..size];
    mark("mapped");
    _ = usleep(3_000_000);

    const c = try zrs.Container.open(mem);
    const dm = try c.domainMatcher();
    const im = try c.ipMatcher();
    mark("header");
    std.debug.print("container ok (domain={d}B ip={d}B)\n", .{ c.domain_mem.len, c.ip_mem.len });
    _ = usleep(3_000_000);

    // 少量点查
    const few = [_][2][]const u8{
        .{ "cn", "www.baidu.com" },
        .{ "google", "google.com" },
        .{ "github", "github.com" },
        .{ "gfw", "twitter.com" },
        .{ "category-ads-all", "doubleclick.net" },
    };
    for (few) |q| {
        std.debug.print("  match {s}:{s} = {}\n", .{ q[0], q[1], dm.match(q[0], q[1]) });
        _ = im.contains(q[0], .{ .v4 = .{ 114, 114, 114, 114 } });
    }
    mark("few");
    _ = usleep(3_000_000);

    // 全 tag 存在性扫（触达 tag 索引区）
    const probe_tags = [_][]const u8{
        "cn", "google", "github", "gfw", "category-ads-all", "netflix", "telegram",
        "twitter", "facebook", "amazon", "microsoft", "apple", "cloudflare", "disney",
        "bilibili", "zhihu", "category-porn", "geolocation-!cn",
        "category-ip-geo-detect", "tld-!cn", "category-games-!cn", "cloudflare", "telegram",
    };
    for (probe_tags) |t| {
        std.debug.print("  hasTag {s} = {}\n", .{ t, dm.hasTag(t) });
    }
    mark("all-tags");
    _ = usleep(3_000_000);

    // 深度扫：probe 域名跨 tag 段反复点查（触达数据区大页）
    const sweep_domains = [_][]const u8{
        "a.b.c.baidu.com", "www.googlevideo.com", "api.github.com", "x.com",
        "ads.doubleclick.net", "www.netflix.com", "t.me", "www.facebook.com",
        "www.amazon.com", "www.microsoft.com", "www.icloud.com", "www.cloudflare.com",
        "www.disneyplus.com", "www.bilibili.com", "www.zhihu.com",
    };
    for (sweep_domains) |d| {
        for (probe_tags) |t| _ = dm.match(t, d);
    }
    mark("sweep");
    _ = usleep(3_000_000);

    _ = munmap(mem_p, size);
    std.debug.print("done\n", .{});
}
