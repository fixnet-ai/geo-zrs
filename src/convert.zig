//! convert.zig — geo-zrs 自包含转换工具（上游 dat → KZF1 容器 full/base）。
//!
//! geo-zrs 是 zrs 格式的家：本工具与格式实现同仓（公开仓、零生态私有依赖），
//! GitHub Action 只 checkout 本仓即可构建运行——无任何跨仓凭据。
//!
//! 用法（工作目录 = 本仓根，或经 --src/--out 指定）：
//!   zrs-convert [--src <dir>] [--out <dir>] [--ads-override <ads-lite.txt>]
//! 缺省 src=update.sh 的工作目录（geoip.dat + geosite.dat），out=dist。
//! ads 覆盖：category-ads-all 一律用轻量集文本（exact/suffix/keyword 三段式）
//! 替换上游 dat 重版（~19.4 万条；Q9 轻量裁定）。

const std = @import("std");
const zrs = @import("zrs.zig");
const dat = @import("dat.zig");

pub const log_level = std.log.Level.info;

const DAT_MAX: usize = 64 * 1024 * 1024;
const ADS_TAG = "category-ads-all";
const BASE_TAGS = "cn,category-ads-all,google,github,gfw";

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    var src_dir: []const u8 = "work";
    var out_dir: []const u8 = "dist";
    var ads_path: []const u8 = "ads-lite.txt";
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
        defer it.deinit();
        _ = it.next();
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, "--src")) {
                src_dir = try alloc.dupe(u8, it.next() orelse return error.MissingArg);
            } else if (std.mem.eql(u8, a, "--out")) {
                out_dir = try alloc.dupe(u8, it.next() orelse return error.MissingArg);
            } else if (std.mem.eql(u8, a, "--ads-override")) {
                ads_path = try alloc.dupe(u8, it.next() orelse return error.MissingArg);
            }
        }
    }

    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    const ads = loadAdsLite(io, alloc, ads_path) catch |err| blk: {
        std.log.warn("[convert] ads 覆盖源读取失败（{s}）：{s} —— category-ads-all 将缺失", .{ ads_path, @errorName(err) });
        break :blk AdsLite{};
    };

    // 同批两产物：full（全量）+ base（裁剪，含 ads 轻量版）。
    try convertOne(io, alloc, src_dir, out_dir, "geo-full.zrs", null, ads);
    try convertOne(io, alloc, src_dir, out_dir, "geo-base.zrs", BASE_TAGS, ads);
}

/// 三段式轻量集（[exact]/[suffix]/[keyword] 段头 + 行清单；# 注释与空行跳过）。
const AdsLite = struct {
    exact: []const []const u8 = &.{},
    suffix: []const []const u8 = &.{},
    keyword: []const []const u8 = &.{},
    regex: []const []const u8 = &.{},
};

fn loadAdsLite(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !AdsLite {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try std.Io.Dir.readFileAlloc(.cwd(), io, path, a, .unlimited);

    var exact: std.ArrayList([]const u8) = .empty;
    var suffix: std.ArrayList([]const u8) = .empty;
    var keyword: std.ArrayList([]const u8) = .empty;
    var regex: std.ArrayList([]const u8) = .empty;
    var cur: ?*std.ArrayList([]const u8) = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[exact]")) {
            cur = &exact;
        } else if (std.mem.eql(u8, line, "[suffix]")) {
            cur = &suffix;
        } else if (std.mem.eql(u8, line, "[keyword]")) {
            cur = &keyword;
        } else if (std.mem.eql(u8, line, "[regex]")) {
            cur = &regex;
        } else if (cur) |list| {
            try list.append(a, line);
        } else {
            return error.InvalidAdsLite; // 段头前出现条目
        }
    }
    // 深拷贝（字符串本体随 arena 会释放——sort 比较期悬垂 segfault 实锚）
    const e = try alloc.alloc([]const u8, exact.items.len);
    for (exact.items, 0..) |s, i| e[i] = try alloc.dupe(u8, s);
    const s2 = try alloc.alloc([]const u8, suffix.items.len);
    for (suffix.items, 0..) |x, i| s2[i] = try alloc.dupe(u8, x);
    const k = try alloc.alloc([]const u8, keyword.items.len);
    for (keyword.items, 0..) |x, i| k[i] = try alloc.dupe(u8, x);
    const r = try alloc.alloc([]const u8, regex.items.len);
    for (regex.items, 0..) |x, i| r[i] = try alloc.dupe(u8, x);
    return .{ .exact = e, .suffix = s2, .keyword = k, .regex = r };
}

const Collected = struct {
    ip_entries: std.ArrayList(zrs.IpEntry) = .empty,
    dom_entries: std.ArrayList(zrs.DomainEntry) = .empty,
    ip_cidr_count: usize = 0,
    domain_total: usize = 0,
};

fn tagInList(filter: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, filter, ',');
    while (it.next()) |item| {
        if (std.mem.eql(u8, item, tag)) return true;
    }
    return false;
}

fn collect(a: std.mem.Allocator, io: std.Io, src_dir: []const u8, tag_filter: ?[]const u8, ads: AdsLite) !Collected {
    var res: Collected = .{};

    const ip_path = try std.fmt.allocPrint(a, "{s}/geoip.dat", .{src_dir});
    const ip_data = try std.Io.Dir.readFileAlloc(.cwd(), io, ip_path, a, @enumFromInt(DAT_MAX));
    const countries = try dat.parseAllCountries(a, ip_data);
    for (countries) |c| {
        if (tag_filter) |tf| if (!tagInList(tf, c.code)) continue;
        res.ip_cidr_count += c.cidrs.len;
        try res.ip_entries.append(a, .{ .tag = c.code, .cidrs = c.cidrs });
    }

    const site_path = try std.fmt.allocPrint(a, "{s}/geosite.dat", .{src_dir});
    const site_data = try std.Io.Dir.readFileAlloc(.cwd(), io, site_path, a, @enumFromInt(DAT_MAX));
    const sites = try dat.parseAllSites(a, site_data);
    for (sites) |s| {
        // ads 覆盖在案时 dat 重版条目整 tag 跳过（下面由轻量集注入）
        if (std.mem.eql(u8, s.tag, ADS_TAG) and (ads.exact.len > 0 or ads.suffix.len > 0 or ads.keyword.len > 0)) continue;
        if (tag_filter) |tf| if (!tagInList(tf, s.tag)) continue;
        res.domain_total += s.domains.len + s.domain_suffixes.len + s.domain_keywords.len + s.domain_regexes.len;
        try res.dom_entries.append(a, .{
            .tag = s.tag,
            .domains = s.domains,
            .domain_suffixes = s.domain_suffixes,
            .domain_keywords = s.domain_keywords,
            .domain_regexes = s.domain_regexes,
        });
    }

    if (ads.exact.len + ads.suffix.len + ads.keyword.len + ads.regex.len > 0) {
        res.domain_total += ads.exact.len + ads.suffix.len + ads.keyword.len + ads.regex.len;
        try res.dom_entries.append(a, .{
            .tag = ADS_TAG,
            .domains = ads.exact,
            .domain_suffixes = ads.suffix,
            .domain_keywords = ads.keyword,
            .domain_regexes = ads.regex,
        });
        std.log.info("[convert] ads 覆盖生效：exact={d} suffix={d} keyword={d}", .{ ads.exact.len, ads.suffix.len, ads.keyword.len });
    }
    return res;
}

fn convertOne(io: std.Io, alloc: std.mem.Allocator, src_dir: []const u8, out_dir: []const u8, name: []const u8, tag_filter: ?[]const u8, ads: AdsLite) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const c = try collect(a, io, src_dir, tag_filter, ads);
    const bytes = try zrs.serializeContainer(alloc, c.dom_entries.items, c.ip_entries.items);
    defer alloc.free(bytes);

    const out_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ out_dir, name });
    defer alloc.free(out_path);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = out_path, .data = bytes });

    std.log.info("[convert] 容器 {s}: {d} 国家 / {d} CIDR；{d} 站点 / {d} 域名 → {d} KB | filter={s}", .{
        out_path, c.ip_entries.items.len, c.ip_cidr_count,
        c.dom_entries.items.len,       c.domain_total, bytes.len / 1024,
        tag_filter orelse "(full)",
    });
}

// ============================================================
// 测试（纯函数面：三段式解析 + tag 过滤；全链路归 update.sh 实跑）
// ============================================================

const testing = std.testing;

test "convert: loadAdsLite 三段式 + 注释/空行跳过 + 段前条目拒收" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/ads.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel);
    try std.Io.Dir.writeFile(tmp.dir, io, .{ .sub_path = "ads.txt", .data =
        "# comment\n[exact]\na.com\n\nb.net\n[suffix]\n.evil.cn\n[keyword]\ntracker\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const ads = try loadAdsLite(io, arena_state.allocator(), rel);
    try testing.expectEqual(@as(usize, 2), ads.exact.len);
    try testing.expectEqualStrings("a.com", ads.exact[0]);
    try testing.expectEqual(@as(usize, 1), ads.suffix.len);
    try testing.expectEqualStrings(".evil.cn", ads.suffix[0]);
    try testing.expectEqual(@as(usize, 1), ads.keyword.len);
}
