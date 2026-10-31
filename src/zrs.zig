//! zrs.zig — GEO 平坦数据库格式（ZRS2 段 + KZF1 复合容器）—— 唯一实现源。
//!
//! 本仓（geo-zrs）是 zrs **格式的家**：格式定义、序列化、点查 matcher 与转换
//! 工具都在这里（公开仓、自包含、零生态私有依赖）。消费方（zigroute 等私有仓）
//! 经 `@import("geozrs").zrs` 引用——依赖方向恒为「私有依赖公开」，公开仓的
//! GitHub Action 无需任何跨仓凭据。
//!
//! 运行时形态：mmap 只读映射文件页直接二分（IP）/ 二分+短回溯（域名），查询路径
//! 零 allocator、零堆展开、clean 页近零驻留。regex 桶经 RegexHook 注入（编译与
//! NFA 匹配留在消费侧——本库不绑任何 regex 实现）。
//!
//! ## 文件布局（全部小端）—— 段格式 ZRS2 与容器格式 KZF1 详见各区注释。

const std = @import("std");

// =============================================================================
// 基础类型（wire 形态；与消费方网络库布局同构，可字段级互转）
// =============================================================================

/// IP CIDR（wire 形态）——与消费方 net 库的 Cidr 布局同构（v4: network+mask_bits）。
pub const Cidr = union(enum) {
    v4: V4,
    v6: V6,

    pub const V4 = extern struct { network: u32, mask_bits: u8 };
    pub const V6 = extern struct { base: [16]u8, mask_bits: u8 };

    /// 测试/工具用文本解析（"192.168.1.0/24"、"2001:db8::/32"）。
    pub fn parse(s: []const u8) !Cidr {
        const slash = std.mem.lastIndexOfScalar(u8, s, '/') orelse return error.InvalidCidr;
        const bits = std.fmt.parseInt(u8, s[slash + 1 ..], 10) catch return error.InvalidCidr;
        const body = s[0..slash];
        if (std.mem.indexOfScalar(u8, body, ':') != null) {
            if (bits > 128) return error.InvalidCidr;
            // :: 缩写展开：左右两组间零填（最多一处；全写形态 = 无缩写直通）
            if (std.mem.count(u8, body, "::") > 1) return error.InvalidCidr; // 多重缩写非法
            const dbl = std.mem.indexOf(u8, body, "::");
            var left: [8][2]u8 = undefined;
            var right: [8][2]u8 = undefined;
            var nl: usize = 0;
            var nr: usize = 0;
            var it = std.mem.splitScalar(u8, body, ':');
            var in_right = dbl == null;
            while (it.next()) |g| {
                if (g.len == 0) {
                    if (!in_right and dbl != null) {
                        in_right = true;
                        continue;
                    }
                    continue; // 尾部空段（:: 结尾形态的 split 余量），忽略
                }
                if (nl + nr >= 8) return error.InvalidCidr;
                const v = std.fmt.parseInt(u16, g, 16) catch return error.InvalidCidr;
                if (in_right) {
                    std.mem.writeInt(u16, right[nr][0..2], v, .big);
                    nr += 1;
                } else {
                    std.mem.writeInt(u16, left[nl][0..2], v, .big);
                    nl += 1;
                }
            }
            if (dbl != null and nl + nr > 8) return error.InvalidCidr;
            if (dbl == null and nl + nr != 8) return error.InvalidCidr;
            var base: [16]u8 = .{0} ** 16;
            for (left[0..nl], 0..) |g, i| {
                base[i * 2] = g[0];
                base[i * 2 + 1] = g[1];
            }
            for (right[0..nr], 0..) |g, i| {
                const off = (8 - nr + i) * 2;
                base[off] = g[0];
                base[off + 1] = g[1];
            }
            return .{ .v6 = .{ .base = base, .mask_bits = bits } };
        }
        if (bits > 32) return error.InvalidCidr;
        var oct: usize = 0;
        var network: u32 = 0;
        var it = std.mem.splitScalar(u8, body, '.');
        while (it.next()) |g| {
            if (oct >= 4) return error.InvalidCidr;
            const v = std.fmt.parseInt(u8, g, 10) catch return error.InvalidCidr;
            network = (network << 8) | v;
            oct += 1;
        }
        if (oct != 4) return error.InvalidCidr;
        return .{ .v4 = .{ .network = network, .mask_bits = bits } };
    }
};

/// IP 地址（点查入参形态）。
pub const IpAddr = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
};

// wire 小端读写（格式自带字节序语义；一体的格式定义，非平台抽象复用）
inline fn writeU32L(buf: []u8, v: u32) void {
    std.mem.writeInt(u32, buf[0..4], v, .little);
}
inline fn readU32L(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .little);
}
inline fn writeU16L(buf: []u8, v: u16) void {
    std.mem.writeInt(u16, buf[0..2], v, .little);
}
inline fn readU16L(buf: []const u8) u16 {
    return std.mem.readInt(u16, buf[0..2], .little);
}

// =============================================================================
// RegexHook（regex 桶匹配注入——编译与 NFA 留在消费侧，本库不绑 regex 实现）
// =============================================================================

/// regex 桶运行时钩子：消费方把预编译引擎包成本结构注入 matcher（缺省 null =
/// regex 桶不参与匹配，exact/suffix/keyword 正常——纯数据零成本承诺边界不变）。
pub const RegexHook = struct {
    ctx: *const anyopaque,
    match_tag_fn: *const fn (ctx: *const anyopaque, tag: []const u8, domain: []const u8) bool,

    pub fn matchTag(self: RegexHook, tag: []const u8, domain: []const u8) bool {
        return self.match_tag_fn(self.ctx, tag, domain);
    }
};

// 格式常量
// =============================================================================

const VERSION: u8 = 2;
const KIND_IP: u8 = 0;
const KIND_DOMAIN: u8 = 1;

const HEADER_SIZE: usize = 24;
const OFF_VERSION: usize = 4;
const OFF_KIND: usize = 5;
const OFF_ENTRY_COUNT: usize = 8;
const OFF_INDEX_OFF: usize = 12;
const OFF_DATA_OFF: usize = 16;
const OFF_DATA_LEN: usize = 20;

/// v4 CIDR 记录字节数（network u32 + mask_bits u8）
const V4_REC_SIZE: usize = 5;
/// v6 CIDR 记录字节数（base [16]u8 + mask_bits u8）
const V6_REC_SIZE: usize = 17;

pub const InvalidFormat = error.InvalidFormat;


// =============================================================================
// 转换工具输入类型
// =============================================================================

/// IP 条目（转换工具输入）：一个 tag（国家代码）对应一组 CIDR
pub const IpEntry = struct {
    tag: []const u8,
    cidrs: []const Cidr,
};

/// Domain 条目（转换工具输入）：一个 tag（站点标签）对应四组域名
pub const DomainEntry = struct {
    tag: []const u8,
    domains: []const []const u8 = &.{}, // exact 精确域名
    domain_suffixes: []const []const u8 = &.{}, // suffix 后缀域名
    domain_keywords: []const []const u8 = &.{}, // keyword 关键字域名
    domain_regexes: []const []const u8 = &.{}, // regex pattern 源文本（geosite v2）
};


// =============================================================================
// 内部紧凑记录（序列化/反序列化中间表示，查询时在栈上零分配构造）
// =============================================================================

const V4Rec = struct { network: u32, mask_bits: u8 };
const V6Rec = struct { base: [16]u8, mask_bits: u8 };


// =============================================================================
// 排序比较器
// =============================================================================

fn lessIpEntry(_: void, a: IpEntry, b: IpEntry) bool {
    return std.mem.order(u8, a.tag, b.tag) == .lt;
}

fn lessDomainEntry(_: void, a: DomainEntry, b: DomainEntry) bool {
    return std.mem.order(u8, a.tag, b.tag) == .lt;
}

fn lessV4(_: void, a: V4Rec, b: V4Rec) bool {
    return a.network < b.network;
}

fn lessV6(_: void, a: V6Rec, b: V6Rec) bool {
    return std.mem.order(u8, a.base[0..], b.base[0..]) == .lt;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}


// =============================================================================
// IP 序列化
// =============================================================================

/// 把一组 IP 条目序列化成 geoip.zrs 字节（返回 alloc 分配的结果，调用者释放）。
/// 中间临时分配走内部 arena，不污染外层 allocator。
pub fn serializeIp(alloc: std.mem.Allocator, entries: []const IpEntry) ![]u8 {
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const t = tmp.allocator();

    const sorted = try t.dupe(IpEntry, entries);
    std.mem.sort(IpEntry, sorted, {}, lessIpEntry);

    var v4_total: usize = 0;
    var v6_total: usize = 0;
    for (sorted) |e| for (e.cidrs) |c| switch (c) {
        .v4 => v4_total += 1,
        .v6 => v6_total += 1,
    };

    const data_len = v4_total * V4_REC_SIZE + v6_total * V6_REC_SIZE;

    var idx_data_len: usize = 0;
    for (sorted) |e| idx_data_len += 1 + e.tag.len + 16;

    const index_off = HEADER_SIZE;
    const tags_base = index_off + 4 * sorted.len;
    const data_off = tags_base + idx_data_len;
    const total = data_off + data_len;

    const buf = try t.alloc(u8, total);
    @memset(buf, 0);

    @memcpy(buf[0..4], "ZRS2");
    buf[OFF_VERSION] = VERSION;
    buf[OFF_KIND] = KIND_IP;
    writeU32L(buf[OFF_ENTRY_COUNT..][0..4], @intCast(sorted.len));
    writeU32L(buf[OFF_INDEX_OFF..][0..4], @intCast(index_off));
    writeU32L(buf[OFF_DATA_OFF..][0..4], @intCast(data_off));
    writeU32L(buf[OFF_DATA_LEN..][0..4], @intCast(data_len));

    var idx_cursor = tags_base;
    var v4_cursor: usize = 0;
    var v6_cursor: usize = v4_total * V4_REC_SIZE;

    for (sorted, 0..) |e, i| {
        writeU32L(buf[index_off + 4 * i ..][0..4], @intCast(idx_cursor - tags_base));

        var v4s: std.ArrayList(V4Rec) = .empty;
        var v6s: std.ArrayList(V6Rec) = .empty;
        for (e.cidrs) |c| switch (c) {
            .v4 => |c4| try v4s.append(t, .{ .network = c4.network, .mask_bits = c4.mask_bits }),
            .v6 => |c6| try v6s.append(t, .{ .base = c6.base, .mask_bits = c6.mask_bits }),
        };
        std.mem.sort(V4Rec, v4s.items, {}, lessV4);
        std.mem.sort(V6Rec, v6s.items, {}, lessV6);

        buf[idx_cursor] = @intCast(e.tag.len);
        idx_cursor += 1;
        @memcpy(buf[idx_cursor..][0..e.tag.len], e.tag);
        idx_cursor += e.tag.len;
        writeU32L(buf[idx_cursor..][0..4], @intCast(v4s.items.len));
        writeU32L(buf[idx_cursor + 4 ..][0..4], @intCast(v4_cursor));
        writeU32L(buf[idx_cursor + 8 ..][0..4], @intCast(v6s.items.len));
        writeU32L(buf[idx_cursor + 12 ..][0..4], @intCast(v6_cursor));
        idx_cursor += 16;

        for (v4s.items) |r| {
            const p = data_off + v4_cursor;
            writeU32L(buf[p..][0..4], r.network);
            buf[p + 4] = r.mask_bits;
            v4_cursor += V4_REC_SIZE;
        }
        for (v6s.items) |r| {
            const p = data_off + v6_cursor;
            @memcpy(buf[p..][0..16], &r.base);
            buf[p + 16] = r.mask_bits;
            v6_cursor += V6_REC_SIZE;
        }
    }

    return alloc.dupe(u8, buf);
}


// =============================================================================
// Domain 序列化
// =============================================================================

/// 把一组 Domain 条目序列化成 geosite.zrs 字节（返回 alloc 分配的结果，调用者释放）。
pub fn serializeDomain(alloc: std.mem.Allocator, entries: []const DomainEntry) ![]u8 {
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const t = tmp.allocator();

    const sorted = try t.dupe(DomainEntry, entries);
    std.mem.sort(DomainEntry, sorted, {}, lessDomainEntry);

    var exact_total: usize = 0;
    var suffix_total: usize = 0;
    var keyword_total: usize = 0;
    var regex_total: usize = 0;
    for (sorted) |e| {
        exact_total += 4 * e.domains.len + sumStrBytes(e.domains);
        suffix_total += 4 * e.domain_suffixes.len + sumStrBytes(e.domain_suffixes);
        keyword_total += 4 * e.domain_keywords.len + sumStrBytes(e.domain_keywords);
        regex_total += 4 * e.domain_regexes.len + sumStrBytes(e.domain_regexes);
    }
    const data_len = exact_total + suffix_total + keyword_total + regex_total;

    var idx_data_len: usize = 0;
    for (sorted) |e| idx_data_len += 1 + e.tag.len + 32;

    const index_off = HEADER_SIZE;
    const tags_base = index_off + 4 * sorted.len;
    const data_off = tags_base + idx_data_len;
    const total = data_off + data_len;

    const buf = try t.alloc(u8, total);
    @memset(buf, 0);

    @memcpy(buf[0..4], "ZRS2");
    buf[OFF_VERSION] = VERSION;
    buf[OFF_KIND] = KIND_DOMAIN;
    writeU32L(buf[OFF_ENTRY_COUNT..][0..4], @intCast(sorted.len));
    writeU32L(buf[OFF_INDEX_OFF..][0..4], @intCast(index_off));
    writeU32L(buf[OFF_DATA_OFF..][0..4], @intCast(data_off));
    writeU32L(buf[OFF_DATA_LEN..][0..4], @intCast(data_len));

    var idx_cursor = tags_base;
    var exact_cursor: usize = 0;
    var suffix_cursor: usize = exact_total;
    var keyword_cursor: usize = exact_total + suffix_total;
    var regex_cursor: usize = exact_total + suffix_total + keyword_total;

    for (sorted, 0..) |e, i| {
        writeU32L(buf[index_off + 4 * i ..][0..4], @intCast(idx_cursor - tags_base));

        // exact 原样排序
        const exact_sorted = try t.dupe([]const u8, e.domains);
        std.mem.sort([]const u8, exact_sorted, {}, lessStr);

        // suffix 反转后排序
        var suffix_rev: std.ArrayList([]const u8) = .empty;
        for (e.domain_suffixes) |s| try suffix_rev.append(t, try reverseAlloc(t, s));
        std.mem.sort([]const u8, suffix_rev.items, {}, lessStr);

        buf[idx_cursor] = @intCast(e.tag.len);
        idx_cursor += 1;
        @memcpy(buf[idx_cursor..][0..e.tag.len], e.tag);
        idx_cursor += e.tag.len;
        writeU32L(buf[idx_cursor..][0..4], @intCast(exact_sorted.len));
        writeU32L(buf[idx_cursor + 4 ..][0..4], @intCast(exact_cursor));
        writeU32L(buf[idx_cursor + 8 ..][0..4], @intCast(suffix_rev.items.len));
        writeU32L(buf[idx_cursor + 12 ..][0..4], @intCast(suffix_cursor));
        writeU32L(buf[idx_cursor + 16 ..][0..4], @intCast(e.domain_keywords.len));
        writeU32L(buf[idx_cursor + 20 ..][0..4], @intCast(keyword_cursor));
        writeU32L(buf[idx_cursor + 24 ..][0..4], @intCast(e.domain_regexes.len));
        writeU32L(buf[idx_cursor + 28 ..][0..4], @intCast(regex_cursor));
        idx_cursor += 32;

        exact_cursor += writeStrArray(buf, data_off + exact_cursor, exact_sorted);
        suffix_cursor += writeStrArray(buf, data_off + suffix_cursor, suffix_rev.items);
        keyword_cursor += writeStrArray(buf, data_off + keyword_cursor, e.domain_keywords);
        regex_cursor += writeStrArray(buf, data_off + regex_cursor, e.domain_regexes);
    }

    return alloc.dupe(u8, buf);
}

fn sumStrBytes(strs: []const []const u8) usize {
    var n: usize = 0;
    for (strs) |s| n += 2 + s.len;
    return n;
}

/// 把字符串数组写到 buf[pos..]（偏移数组 [count]u32 + {len u16 + bytes}），返回写入字节数
fn writeStrArray(buf: []u8, pos: usize, strs: []const []const u8) usize {
    const count = strs.len;
    const data_start = pos + 4 * count;
    var data_cursor = data_start;
    for (strs, 0..) |s, i| {
        writeU32L(buf[pos + 4 * i ..][0..4], @intCast(data_cursor - data_start));
        writeU16L(buf[data_cursor..][0..2], @intCast(s.len));
        @memcpy(buf[data_cursor + 2 ..][0..s.len], s);
        data_cursor += 2 + s.len;
    }
    return data_cursor - pos;
}

/// 反转字符串字节序到新分配的缓冲
fn reverseAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[s.len - 1 - i] = c;
    return out;
}


// =============================================================================
// IP matcher（mmap 文件页直查）
// =============================================================================

/// geoip.zrs 只读 matcher。持有文件页切片（mmap 传入），查询零分配。
pub const ZrsIpMatcher = struct {
    mem: []const u8,

    pub fn init(mem: []const u8) !ZrsIpMatcher {
        if (mem.len < HEADER_SIZE) return InvalidFormat;
        if (!std.mem.eql(u8, mem[0..4], "ZRS2")) return InvalidFormat;
        if (mem[OFF_VERSION] != VERSION) return InvalidFormat;
        if (mem[OFF_KIND] != KIND_IP) return InvalidFormat;
        return .{ .mem = mem };
    }

    inline fn entryCount(self: *const ZrsIpMatcher) u32 {
        return readU32L(self.mem[OFF_ENTRY_COUNT..][0..4]);
    }
    inline fn indexOff(self: *const ZrsIpMatcher) u32 {
        return readU32L(self.mem[OFF_INDEX_OFF..][0..4]);
    }
    inline fn dataOff(self: *const ZrsIpMatcher) u32 {
        return readU32L(self.mem[OFF_DATA_OFF..][0..4]);
    }

    const Tag = struct { v4_count: u32, v4_off: u32, v6_count: u32, v6_off: u32 };

    fn findTag(self: *const ZrsIpMatcher, tag: []const u8) ?Tag {
        const n = self.entryCount();
        const idx_off = self.indexOff();
        const tags_base = idx_off + 4 * @as(u32, n);
        var lo: u32 = 0;
        var hi: u32 = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rel = readU32L(self.mem[idx_off + 4 * mid ..][0..4]);
            const p = tags_base + rel;
            const tl = self.mem[p];
            const t = self.mem[p + 1 ..][0..tl];
            switch (std.mem.order(u8, t, tag)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    const f = p + 1 + tl;
                    return .{
                        .v4_count = readU32L(self.mem[f..][0..4]),
                        .v4_off = readU32L(self.mem[f + 4 ..][0..4]),
                        .v6_count = readU32L(self.mem[f + 8 ..][0..4]),
                        .v6_off = readU32L(self.mem[f + 12 ..][0..4]),
                    };
                },
            }
        }
        return null;
    }

    /// 点查：ip 是否落在 code 的 CIDR 集合内。code 须已小写。
    pub fn contains(self: *const ZrsIpMatcher, code: []const u8, ip: IpAddr) bool {
        const tag = self.findTag(code) orelse return false;
        const d_off = self.dataOff();
        return switch (ip) {
            .v4 => |a4| containsV4(self.mem[d_off + tag.v4_off ..][0 .. tag.v4_count * V4_REC_SIZE], ip4ToU32(a4)),
            .v6 => |a6| containsV6(self.mem[d_off + tag.v6_off ..][0 .. tag.v6_count * V6_REC_SIZE], a6),
        };
    }

    /// 存在性校验：code（国家代码）是否有条目。code 须已小写。
    pub fn hasTag(self: *const ZrsIpMatcher, code: []const u8) bool {
        return self.findTag(code) != null;
    }
};

/// v4 LPM：二分定位最后一个 network <= ip_net，回溯检查包含关系。
fn containsV4(v4: []const u8, ip_net: u32) bool {
    const count = v4.len / V4_REC_SIZE;
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const net = readU32L(v4[mid * V4_REC_SIZE ..][0..4]);
        if (net <= ip_net) lo = mid + 1 else hi = mid;
    }
    var i = lo;
    while (i > 0) {
        i -= 1;
        const p = i * V4_REC_SIZE;
        const net = readU32L(v4[p..][0..4]);
        const mask = v4[p + 4];
        if (v4Contains(net, mask, ip_net)) return true;
    }
    return false;
}

fn v4Contains(network: u32, mask_bits: u8, ip_net: u32) bool {
    if (mask_bits == 0) return true;
    const mask: u32 = if (mask_bits == 32) 0xFFFFFFFF else (@as(u32, 0xFFFFFFFF) << @intCast(32 - mask_bits));
    return (ip_net & mask) == (network & mask);
}

fn containsV6(v6: []const u8, ip: [16]u8) bool {
    const count = v6.len / V6_REC_SIZE;
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const base: [16]u8 = v6[mid * V6_REC_SIZE ..][0..16].*;
        if (std.mem.order(u8, base[0..], ip[0..]) != .gt) lo = mid + 1 else hi = mid;
    }
    var i = lo;
    while (i > 0) {
        i -= 1;
        const p = i * V6_REC_SIZE;
        const base: [16]u8 = v6[p..][0..16].*;
        const mask = v6[p + 16];
        if (v6Contains(base, mask, ip)) return true;
    }
    return false;
}

fn v6Contains(base: [16]u8, mask_bits: u8, ip: [16]u8) bool {
    if (mask_bits == 0) return true;
    var i: usize = 0;
    const full = mask_bits / 8;
    const rem = mask_bits % 8;
    while (i < full) : (i += 1) if (base[i] != ip[i]) return false;
    if (rem == 0) return true;
    const m: u8 = (@as(u8, 0xff) << @intCast(8 - rem)) & 0xff;
    return (base[full] & m) == (ip[full] & m);
}

fn ip4ToU32(ip: [4]u8) u32 {
    return (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | ip[3];
}


// =============================================================================
// Domain matcher（mmap 文件页直查）
// =============================================================================

/// geosite.zrs 只读 matcher。查询零分配。
fn strAt(mem: []const u8, arr_off: u32, count: u32, idx: usize) []const u8 {
    const off = readU32L(mem[arr_off + 4 * idx ..][0..4]);
    const data_start = arr_off + 4 * count;
    const p = data_start + off;
    const len = readU16L(mem[p..][0..2]);
    return mem[p + 2 ..][0..len];
}

fn matchExact(mem: []const u8, arr_off: u32, count: u32, domain: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const s = strAt(mem, arr_off, count, mid);
        switch (std.mem.order(u8, s, domain)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}

/// 反转后缀命中判定（label 边界感知，供 matchSuffix 使用）。
/// 反转数组里存的 suffix 分两种形态：
///   - 原串以 '.' 开头（如 ".google.com"）→ 反转后尾部 '.' 自带边界锚点，
///     反转前缀命中即可（只匹配子域、不含自身），无须再判下一字符；
///   - 裸后缀（如 "com" / "foo.bar"）→ 须在 label 边界截断：仅当
///     rev_domain == s（域名 == 后缀）或 rev_domain[s.len] == '.'（域名以
///     "."+后缀 结尾）才命中，杜绝 "notcom"/"xfoo.bar" 被 "com"/"foo.bar"
///     的反转前缀（"moc"/"rab.oof"）误命中。
fn matchSuffix(mem: []const u8, arr_off: u32, count: u32, rev_domain: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const s = strAt(mem, arr_off, count, mid);
        if (std.mem.order(u8, s, rev_domain) != .gt) lo = mid + 1 else hi = mid;
    }
    var i = lo;
    while (i > 0) {
        i -= 1;
        const s = strAt(mem, arr_off, count, i);
        if (suffixHit(rev_domain, s)) return true;
    }
    return false;
}

fn matchKeyword(mem: []const u8, arr_off: u32, count: u32, domain: []const u8) bool {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const s = strAt(mem, arr_off, count, i);
        if (std.mem.indexOf(u8, domain, s) != null) return true;
    }
    return false;
}

fn suffixHit(rev_domain: []const u8, s: []const u8) bool {
    if (!std.mem.startsWith(u8, rev_domain, s)) return false;
    if (s.len == 0) return false; // 空后缀不作命中（同时避免 s[s.len-1] 越界）
    if (s[s.len - 1] == '.') return true; // 自带 '.' 边界锚点
    if (rev_domain.len == s.len) return true; // 域名 == 后缀
    return rev_domain[s.len] == '.';
}

fn reverseInBuf(buf: []u8, s: []const u8) []u8 {
    for (s, 0..) |c, i| buf[s.len - 1 - i] = c;
    return buf[0..s.len];
}

pub const ZrsDomainMatcher = struct {
    mem: []const u8,
    /// 可选 regex 运行时（编译缓存）。含 regex 桶的数据经 `RegexEngine.init` 预编译后由
    /// 调用方装配；纯域名数据为 null（match 行为零变化）。指向调用方持有的 RegexEngine。
    regex: ?RegexHook = null,

    pub fn init(mem: []const u8) !ZrsDomainMatcher {
        if (mem.len < HEADER_SIZE) return InvalidFormat;
        if (!std.mem.eql(u8, mem[0..4], "ZRS2")) return InvalidFormat;
        if (mem[OFF_VERSION] != VERSION) return InvalidFormat;
        if (mem[OFF_KIND] != KIND_DOMAIN) return InvalidFormat;
        return .{ .mem = mem };
    }

    inline fn entryCount(self: *const ZrsDomainMatcher) u32 {
        return readU32L(self.mem[OFF_ENTRY_COUNT..][0..4]);
    }
    inline fn indexOff(self: *const ZrsDomainMatcher) u32 {
        return readU32L(self.mem[OFF_INDEX_OFF..][0..4]);
    }
    inline fn dataOff(self: *const ZrsDomainMatcher) u32 {
        return readU32L(self.mem[OFF_DATA_OFF..][0..4]);
    }

    const Tag = struct {
        exact_count: u32,
        exact_off: u32,
        suffix_count: u32,
        suffix_off: u32,
        keyword_count: u32,
        keyword_off: u32,
        regex_count: u32,
        regex_off: u32,
    };

    fn findTag(self: *const ZrsDomainMatcher, tag: []const u8) ?Tag {
        const n = self.entryCount();
        const idx_off = self.indexOff();
        const tags_base = idx_off + 4 * @as(u32, n);
        var lo: u32 = 0;
        var hi: u32 = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rel = readU32L(self.mem[idx_off + 4 * mid ..][0..4]);
            const p = tags_base + rel;
            const tl = self.mem[p];
            const t = self.mem[p + 1 ..][0..tl];
            switch (std.mem.order(u8, t, tag)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    const f = p + 1 + tl;
                    return .{
                        .exact_count = readU32L(self.mem[f..][0..4]),
                        .exact_off = readU32L(self.mem[f + 4 ..][0..4]),
                        .suffix_count = readU32L(self.mem[f + 8 ..][0..4]),
                        .suffix_off = readU32L(self.mem[f + 12 ..][0..4]),
                        .keyword_count = readU32L(self.mem[f + 16 ..][0..4]),
                        .keyword_off = readU32L(self.mem[f + 20 ..][0..4]),
                        .regex_count = readU32L(self.mem[f + 24 ..][0..4]),
                        .regex_off = readU32L(self.mem[f + 28 ..][0..4]),
                    };
                },
            }
        }
        return null;
    }

    /// 点查：domain 是否匹配 tag（exact / suffix / keyword 任一）。tag 须已小写。
    pub fn match(self: *const ZrsDomainMatcher, tag: []const u8, domain: []const u8) bool {
        const e = self.findTag(tag) orelse return false;
        const d_off = self.dataOff();

        if (e.exact_count > 0 and matchExact(self.mem, d_off + e.exact_off, e.exact_count, domain)) return true;
        if (e.suffix_count > 0) {
            // 反转用栈缓冲 [256]u8：>256 字符域名静默跳过 suffix 匹配（已记录极限——
            // 合法域名最长 253 字符（RFC 1035），远超常见域；exact/keyword 无此上限）。
            var rev_buf: [256]u8 = undefined;
            if (domain.len <= rev_buf.len) {
                const rev = reverseInBuf(rev_buf[0..domain.len], domain);
                if (matchSuffix(self.mem, d_off + e.suffix_off, e.suffix_count, rev)) return true;
            }
        }
        if (e.keyword_count > 0 and matchKeyword(self.mem, d_off + e.keyword_off, e.keyword_count, domain)) return true;
        // regex 桶：仅含 regex 的 tag 走到这一步；匹配经注入的 RegexHook（消费侧预编译）
        if (e.regex_count > 0) {
            if (self.regex) |hook| if (hook.matchTag(tag, domain)) return true;
        }
        return false;
    }

    /// 存在性校验：tag（站点标签）是否有条目。tag 须已小写。
    pub fn hasTag(self: *const ZrsDomainMatcher, tag: []const u8) bool {
        return self.findTag(tag) != null;
    }
};


// =============================================================================
// 复合容器（geo-full.zrs / geo-base.zrs —— 2026-10-31 数据集分发架构 v2）
// =============================================================================

/// 容器头（15B，全部小端）：
///   [0..4)   magic "KZF1"
///   [4]      version u8 = 1
///   [5..7)   reserved [2]u8 = 0
///   [7..11)  domain_len u32
///   [11..15) ip_len u32
///   [15..]   domain 段（serializeDomain 输出，ZRS2 kind=Domain）
///   [..]     ip 段（serializeIp 输出，ZRS2 kind=IP）
///
/// 设计约束：两段是**完整的既有 ZRS2 字节流**（自带 magic/版本/kind 自校验），
/// 容器装载 = 头校验 + 两段切片，各段 init 复用既有 matcher 代码（零改动）。
/// 分发形态：全量/裁剪库各一个容器文件（壳下载 zip → 流式解压出容器 → 引擎
/// mmap 整文件两段直查）。
const CONTAINER_MAGIC = "KZF1";
const CONTAINER_HEADER_SIZE: usize = 15;

pub const Container = struct {
    domain_mem: []const u8,
    ip_mem: []const u8,

    pub fn open(mem: []const u8) !Container {
        if (mem.len < CONTAINER_HEADER_SIZE) return error.InvalidFormat;
        if (!std.mem.eql(u8, mem[0..4], CONTAINER_MAGIC)) return error.InvalidFormat;
        if (mem[4] != 1) return error.InvalidFormat;
        const dom_len: usize = readU32L(mem[7..11]);
        const ip_len: usize = readU32L(mem[11..15]);
        if (dom_len == 0 or ip_len == 0) return error.InvalidFormat;
        const dom_end = CONTAINER_HEADER_SIZE + dom_len;
        const ip_end = dom_end + ip_len;
        if (ip_end != mem.len) return error.InvalidFormat; // 截断/尾部垃圾拒收
        return .{ .domain_mem = mem[CONTAINER_HEADER_SIZE..dom_end], .ip_mem = mem[dom_end..ip_end] };
    }

    pub fn domainMatcher(self: Container) !ZrsDomainMatcher {
        return ZrsDomainMatcher.init(self.domain_mem);
    }

    pub fn ipMatcher(self: Container) !ZrsIpMatcher {
        return ZrsIpMatcher.init(self.ip_mem);
    }
};

/// 序列化容器：两段由既有序列化器产出后拼接（中间字节经内部 arena，不外泄）。
pub fn serializeContainer(
    alloc: std.mem.Allocator,
    dom_entries: []const DomainEntry,
    ip_entries: []const IpEntry,
) ![]u8 {
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const t = tmp.allocator();

    const dom = try serializeDomain(t, dom_entries);
    const ip = try serializeIp(t, ip_entries);
    if (dom.len > std.math.maxInt(u32) or ip.len > std.math.maxInt(u32)) return error.ContainerTooLarge;

    const out = try alloc.alloc(u8, CONTAINER_HEADER_SIZE + dom.len + ip.len);
    @memcpy(out[0..4], CONTAINER_MAGIC);
    out[4] = 1;
    out[5] = 0;
    out[6] = 0;
    writeU32L(out[7..11], @intCast(dom.len));
    writeU32L(out[11..15], @intCast(ip.len));
    @memcpy(out[CONTAINER_HEADER_SIZE..][0..dom.len], dom);
    @memcpy(out[CONTAINER_HEADER_SIZE + dom.len ..][0..ip.len], ip);
    return out;
}

test "zrs: 容器 round-trip（domain+ip 双段直查）" {
    const alloc = std.testing.allocator;
    const dom = [_]DomainEntry{
        .{ .tag = "cn", .domain_suffixes = &.{".baidu.com"} },
        .{ .tag = "google", .domains = &.{"google.com"} },
    };
    const ip = [_]IpEntry{
        .{ .tag = "cn", .cidrs = &.{testCidrV4("192.168.1.0/24")} },
    };

    const buf = try serializeContainer(alloc, &dom, &ip);
    defer alloc.free(buf);

    const c = try Container.open(buf);
    const dm = try c.domainMatcher();
    const im = try c.ipMatcher();
    try testing.expect(dm.match("cn", "www.baidu.com"));
    try testing.expect(!dm.match("cn", "baidu.com.evil.org"));
    try testing.expect(dm.match("google", "google.com"));
    try testing.expect(dm.hasTag("google"));
    try testing.expect(im.contains("cn", .{ .v4 = .{ 192, 168, 1, 77 } }));
    try testing.expect(!im.contains("cn", .{ .v4 = .{ 8, 8, 8, 8 } }));
    try testing.expect(im.hasTag("cn"));
}

test "zrs: 容器格式校验（坏 magic / 截断 / 尾部垃圾拒收）" {
    const alloc = std.testing.allocator;
    const dom = [_]DomainEntry{.{ .tag = "cn", .domain_suffixes = &.{".baidu.com"} }};
    const ip = [_]IpEntry{.{ .tag = "cn", .cidrs = &.{testCidrV4("1.2.3.4/32")} }};
    const buf = try serializeContainer(alloc, &dom, &ip);
    defer alloc.free(buf);

    // 坏 magic
    var bad1 = try alloc.dupe(u8, buf);
    defer alloc.free(bad1);
    bad1[0] = 'X';
    try testing.expectError(error.InvalidFormat, Container.open(bad1));

    // 截断
    try testing.expectError(error.InvalidFormat, Container.open(buf[0 .. buf.len - 1]));

    // 尾部多一字节
    var bad3 = try alloc.alloc(u8, buf.len + 1);
    defer alloc.free(bad3);
    @memcpy(bad3[0..buf.len], buf);
    bad3[buf.len] = 0;
    try testing.expectError(error.InvalidFormat, Container.open(bad3));
}

// =============================================================================
// 测试
// =============================================================================

const testing = std.testing;

fn testCidrV4(s: []const u8) Cidr {
    return Cidr.parse(s) catch unreachable;
}

/// 解析 IPv6 地址字符串（含 /128 前缀，复用 Cidr.parse）为 16 字节
fn testIp6(s: []const u8) [16]u8 {
    return (Cidr.parse(s) catch unreachable).v6.base;
}

test "zrs: IP round-trip 二分点查" {
    const alloc = testing.allocator;
    const entries = [_]IpEntry{
        .{
            .tag = "cn",
            .cidrs = &.{
                testCidrV4("10.0.0.0/8"),
                testCidrV4("10.1.0.0/16"),
                testCidrV4("192.168.1.0/24"),
            },
        },
        .{
            .tag = "us",
            .cidrs = &.{ testCidrV4("8.8.8.0/24"), testCidrV4("1.1.1.0/24") },
        },
        .{
            .tag = "all",
            .cidrs = &.{testCidrV4("0.0.0.0/0")},
        },
    };
    const buf = try serializeIp(alloc, &entries);
    defer alloc.free(buf);

    const m = try ZrsIpMatcher.init(buf);

    try testing.expect(m.contains("cn", .{ .v4 = .{ 10, 2, 3, 4 } }));
    try testing.expect(m.contains("cn", .{ .v4 = .{ 10, 1, 5, 6 } }));
    try testing.expect(m.contains("cn", .{ .v4 = .{ 192, 168, 1, 99 } }));
    try testing.expect(!m.contains("cn", .{ .v4 = .{ 192, 168, 2, 1 } }));

    try testing.expect(m.contains("us", .{ .v4 = .{ 8, 8, 8, 8 } }));
    try testing.expect(!m.contains("us", .{ .v4 = .{ 8, 8, 9, 1 } }));

    // /0 兜底匹配一切 IP（嵌套前缀回溯到 /0）
    try testing.expect(m.contains("all", .{ .v4 = .{ 200, 1, 2, 3 } }));
    try testing.expect(!m.contains("jp", .{ .v4 = .{ 10, 1, 1, 1 } }));

    // 存在性校验
    try testing.expect(m.hasTag("cn"));
    try testing.expect(m.hasTag("us"));
    try testing.expect(!m.hasTag("jp"));
}

test "zrs: IPv6 round-trip 二分点查" {
    const alloc = testing.allocator;
    const entries = [_]IpEntry{
        .{
            .tag = "cn6",
            .cidrs = &.{
                testCidrV4("2001:db8::/32"),
                testCidrV4("2001:db8:1::/48"),
                testCidrV4("240e::/20"),
            },
        },
        .{
            .tag = "v6all",
            .cidrs = &.{testCidrV4("::/0")},
        },
    };
    const buf = try serializeIp(alloc, &entries);
    defer alloc.free(buf);

    const m = try ZrsIpMatcher.init(buf);

    // 命中 /48（更具体）
    try testing.expect(m.contains("cn6", .{ .v6 = testIp6("2001:db8:1::1/128") }));
    // 命中 /32（回溯到更宽前缀）
    try testing.expect(m.contains("cn6", .{ .v6 = testIp6("2001:db8:2:3:4:5:6:7/128") }));
    // 命中 240e::/20（中国教育网段）
    try testing.expect(m.contains("cn6", .{ .v6 = testIp6("240e:390::1/128") }));
    // 不命中（db9 不在 db8/32 内）
    try testing.expect(!m.contains("cn6", .{ .v6 = testIp6("2001:db9::1/128") }));
    // v6 /0 兜底
    try testing.expect(m.contains("v6all", .{ .v6 = testIp6("::1/128") }));

    // v4 与 v6 隔离：v4 查询不命中纯 v6 tag
    try testing.expect(!m.contains("cn6", .{ .v4 = .{ 1, 2, 3, 4 } }));
}

test "zrs: Domain round-trip 三分匹配" {
    const alloc = testing.allocator;
    const entries = [_]DomainEntry{
        .{
            .tag = "google",
            .domains = &.{ "google.com", "google.cn" },
            .domain_suffixes = &.{ ".google.com", ".youtube.com", ".googlevideo.com" },
            .domain_keywords = &.{},
        },
        .{
            .tag = "netflix",
            .domains = &.{},
            .domain_suffixes = &.{".netflix.com"},
            .domain_keywords = &.{},
        },
        .{
            .tag = "kw",
            .domains = &.{},
            .domain_suffixes = &.{},
            .domain_keywords = &.{"abc"},
        },
    };
    const buf = try serializeDomain(alloc, &entries);
    defer alloc.free(buf);

    const m = try ZrsDomainMatcher.init(buf);

    // exact
    try testing.expect(m.match("google", "google.com"));
    try testing.expect(!m.match("google", "google.org"));
    // suffix（反转前缀匹配）
    try testing.expect(m.match("google", "www.google.com"));
    try testing.expect(m.match("google", "a.b.youtube.com"));
    try testing.expect(!m.match("google", "google.com.evil.org"));
    try testing.expect(!m.match("google", "example.org"));
    // keyword（子串匹配）
    try testing.expect(m.match("kw", "xxabcyy"));
    try testing.expect(!m.match("kw", "xyz"));

    try testing.expect(m.match("netflix", "www.netflix.com"));
    try testing.expect(!m.match("netflix", "www.youtube.com"));

    // 存在性校验
    try testing.expect(m.hasTag("google"));
    try testing.expect(m.hasTag("netflix"));
    try testing.expect(m.hasTag("kw"));
    try testing.expect(!m.hasTag("example"));
}

test "zrs: Domain suffix label 边界（裸 com 不误命中 notcom/ecom/xcom）" {
    const alloc = testing.allocator;
    const entries = [_]DomainEntry{
        .{
            .tag = "tld",
            .domains = &.{},
            // 裸后缀（无前导 '.'，对齐 dat Domain(2) → domain_suffixes 的落盘形态）
            .domain_suffixes = &.{ "com", "foo.bar" },
            .domain_keywords = &.{},
        },
    };
    const buf = try serializeDomain(alloc, &entries);
    defer alloc.free(buf);
    const m = try ZrsDomainMatcher.init(buf);

    // 裸后缀应命中「自身 / 以 "."+后缀 结尾」的域名（反转前缀 + '.' 边界截断）
    try testing.expect(m.match("tld", "example.com")); // 以 ".com" 结尾
    try testing.expect(m.match("tld", "foo.bar")); // 恰等于两层后缀自身
    try testing.expect(m.match("tld", "sub.example.foo.bar")); // foo.bar 子域
    // 反转前缀须在 '.' 边界截断：label 紧邻的异形域名不得被 "com"/"foo.bar" 命中
    try testing.expect(!m.match("tld", "notcom")); // rev 前缀 "moc"，但下一字符 'o' ≠ '.'
    try testing.expect(!m.match("tld", "ecom")); // rev "moce"
    try testing.expect(!m.match("tld", "xcom")); // rev "mocx"
    try testing.expect(!m.match("tld", "xfoo.bar")); // "foo.bar" 前有 'x'，非其子域
    try testing.expect(!m.match("tld", "bar")); // 短查询不被两层后缀 "foo.bar" 的反转前缀命中
}

test "zrs: Domain suffix 深层 label 边界（多层 foo.bar 前缀区分）" {
    const alloc = testing.allocator;
    const entries = [_]DomainEntry{
        .{
            .tag = "fb",
            .domains = &.{},
            .domain_suffixes = &.{"foo.bar"}, // 两层后缀，反转 "rab.oof" 含内部 '.'
            .domain_keywords = &.{},
        },
    };
    const buf = try serializeDomain(alloc, &entries);
    defer alloc.free(buf);
    const m = try ZrsDomainMatcher.init(buf);

    // 命中：恰等 / 多级真子域（内部多层 '.' 均须在 rev[s.len] 处成边界）
    try testing.expect(m.match("fb", "foo.bar"));
    try testing.expect(m.match("fb", "www.foo.bar")); // rev "rab.oof.www"，rev[s.len]='.'
    try testing.expect(m.match("fb", "deep.sub.foo.bar")); // 多层子域
    // 不命中：紧邻后缀前/后的 label 未在 '.' 边界截断
    try testing.expect(!m.match("fb", "xfoo.bar")); // rev "rab.oofx"，s 后字符 'x' ≠ '.'
    try testing.expect(!m.match("fb", "notcom")); // 无后缀匹配时整体 false
}

test "zrs: Domain suffix 超长(>256)域名静默跳过不崩溃（已记录极限）" {
    const alloc = testing.allocator;
    // 构造 [320]u8 复用缓冲，分段填出不同长度的 "a...a.com" 查询串
    var buf: [320]u8 = undefined;

    // 304 = 300×'a' + ".com"，超 rev_buf[256] 上限：suffix 分支应静默跳过（不崩溃、不命中）
    @memset(buf[0..300], 'a');
    @memcpy(buf[300..304], ".com");
    const long_dom = buf[0..304];

    const entries = [_]DomainEntry{
        .{
            .tag = "t",
            .domains = &.{},
            // 同时存一个 304 字符后缀：验证超长 suffix 条目序列化 + 二分读串不越界
            .domain_suffixes = &.{ "com", long_dom },
            .domain_keywords = &.{},
        },
    };
    const sbuf = try serializeDomain(alloc, &entries);
    defer alloc.free(sbuf);
    const m = try ZrsDomainMatcher.init(sbuf);

    // >256 域名：suffix 被栈缓冲上限静默跳过 → 不崩溃且不命中（已记录极限，见 match() 注释）
    try testing.expect(!m.match("t", long_dom));
    // 恰在上限 256 内：仍应正常 label 命中 → 证明是长度上限而非语义缺陷
    @memset(buf[0..252], 'a');
    @memcpy(buf[252..256], ".com");
    try testing.expect(m.match("t", buf[0..256]));
    // 仅越界 1 字符（257）即静默跳过
    @memset(buf[0..253], 'a');
    @memcpy(buf[253..257], ".com");
    try testing.expect(!m.match("t", buf[0..257]));
    // 256 内短域名对照：同后缀正常命中，label 边界仍生效
    @memset(buf[0..100], 'a');
    @memcpy(buf[100..104], ".com");
    try testing.expect(m.match("t", buf[0..104]));
    try testing.expect(!m.match("t", "ecom"));
}

test "zrs: 格式校验拒绝错 kind / 错 version" {
    const alloc = testing.allocator;
    const entries = [_]IpEntry{.{ .tag = "cn", .cidrs = &.{testCidrV4("10.0.0.0/8")} }};
    const buf = try serializeIp(alloc, &entries);
    defer alloc.free(buf);

    try testing.expectError(InvalidFormat, ZrsDomainMatcher.init(buf));

    var bad = try alloc.dupe(u8, buf);
    defer alloc.free(bad);
    bad[OFF_VERSION] = 99;
    try testing.expectError(InvalidFormat, ZrsIpMatcher.init(bad));
}

test "zrs: v1 magic（ZRS1）被 v2 matcher 拒收（破坏性升版）" {
    const alloc = testing.allocator;
    const entries = [_]IpEntry{.{ .tag = "cn", .cidrs = &.{testCidrV4("10.0.0.0/8")} }};
    const buf = try serializeIp(alloc, &entries);
    defer alloc.free(buf);
    var old = try alloc.dupe(u8, buf);
    defer alloc.free(old);
    @memcpy(old[0..4], "ZRS1");
    try testing.expectError(InvalidFormat, ZrsIpMatcher.init(old));
    try testing.expectError(InvalidFormat, ZrsDomainMatcher.init(old));
}
