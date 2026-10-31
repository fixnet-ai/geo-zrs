//! dat.zig — V2Ray protobuf 格式(.dat)后端
//!
//! 解析 geoip.dat / geosite.dat 文件。
//! 支持 mihomo geodata-mode=true 场景及 xray-core 原生格式。
//!
//! 文件格式:
//!   geoip.dat  = protobuf GeoIPList{GeoIP{country_code=1, cidr=2{ip=1(4/16B), prefix=2}}}
//!   geosite.dat = protobuf GeoSiteList{GeoSite{country_code=1, domain=2{Domain{type=1, value=2}}}}
//!   Domain.type: Plain(0)/Regex(1)/Domain(2)/Full(3)
//!
//! 目录模式（对齐 srs/mrs 后端语义）:
//!   - init() 接收目录路径，不预加载
//!   - parseAllCountries(data) → 一次遍历全量国家条目（转换器路径）；
//!     解析并提取 cn 的 CIDR 后立即 unmap
//!   - lookupSite("google") → 同上读 geosite.dat
//!   - 已解析条目缓存在 StringHashMap（缓存键 "ip:"/"site:" 前缀，避免冲突）
//!   - FileNotFound → null（对齐 srs）；文件存在但解析失败 → 显式错误
//!   - 稳态不持有文件映射：缓存只存提取结果（CIDR 值类型 / 域名 dupe 拷贝），
//!     大文件（geoip ~17MB）不再整读进 arena（避免 VPN 常驻被 OS 杀）
//!   - 选 mmap 而非 mihomo memconservative 流式读+Seek（内存更优）：全异步铁律禁止
//!     同步 read/seek，mmap 缺页由内核异步完成；代价是顺序遍历 touch 全部页、启动
//!     峰值 RSS≈文件大小，该峰值问题由 iOS 走 srs 化解（见 findings.md「dat 后端内存优化调研」）
//!
//! Domain.type 四分类映射（findings geodb-1 裁定 + P3 超集升版）:
//!   Domain(2)→domain_suffixes、Full(3)→domains、Plain(0)→domain_keywords、Regex(1)→domain_regexes
//!
//! 实现陷阱:
//!   - Cidr4.network 是主机序 u32、Cidr6.base 是网络字节序 [16]u8；
//!     protobuf 里 ip 字段是网络字节序，v4 转主机序经 std.mem.readInt(.big)。
//!   - protobuf varint 与 Go binary.Uvarint 编码一致，实现在 dat/protobuf.zig。
//!   - ⚠️ 域名是 mmap buffer 的引用：parseGeoSiteDomains 必须 arena.dupe 拷贝，
//!     否则 mmap 临时映射 unmap 后悬垂指针（CIDR 是值类型，天然安全）。

const std = @import("std");
const geodb = @import("zrs.zig");
const pb = @import("dat/protobuf.zig");
const zrs_mod = @import("zrs.zig"); // 端到端测试用（dat 收集产物 → geosite.zrs v2 → matcher）

const Cidr = zrs_mod.Cidr;
/// 国家查询结果（转换器内部形态；count/isEmpty 与消费方门面同构）。
pub const CountryResult = struct {
    cidrs: []const Cidr = &.{},
    pub fn count(self: CountryResult) usize {
        return self.cidrs.len;
    }
};

/// 站点查询结果——域名四桶（转换器内部形态）。
pub const SiteResult = struct {
    domains: []const []const u8 = &.{},
    domain_suffixes: []const []const u8 = &.{},
    domain_keywords: []const []const u8 = &.{},
    domain_regexes: []const []const u8 = &.{},
    pub fn count(self: SiteResult) usize {
        return self.domains.len + self.domain_suffixes.len + self.domain_keywords.len +
            self.domain_regexes.len;
    }
    pub fn isEmpty(self: SiteResult) bool {
        return self.count() == 0;
    }
};

/// dat 文件大小上限（全量 geoip.dat ~17MB / geosite.dat ~11MB，64MB 留足余量）
const DAT_MAX_FILE_SIZE = 64 * 1024 * 1024;

pub const CountryEntry = struct {
    code: []const u8,
    cidrs: []const Cidr,
};

/// 全量解析条目：一次遍历 geosite.dat 提取全部 site（tag → 域名四分类）。
pub const SiteEntry = struct {
    tag: []const u8,
    domains: []const []const u8,
    domain_suffixes: []const []const u8,
    domain_keywords: []const []const u8,
    domain_regexes: []const []const u8,
};

/// 读 GeoIP/GeoSite 消息的 field 1（country_code / tag），转小写 dupe。
fn msgCodeLower(arena: std.mem.Allocator, msg: []const u8) !?[]const u8 {
    var r = pb.Reader.init(msg);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        if (tag.number == 1) {
            if (tag.wire_type != .length_delimited) return error.InvalidFormat;
            const code = try r.readBytes();
            const lower = try arena.dupe(u8, code);
            for (lower) |*c| c.* = std.ascii.toLower(c.*);
            return lower;
        } else {
            try r.skipField(tag.wire_type);
        }
    }
    return null;
}

/// 一次遍历 geoip.dat，提取全部 country 的 CIDR。
pub fn parseAllCountries(arena: std.mem.Allocator, data: []const u8) ![]CountryEntry {
    var entries: std.ArrayList(CountryEntry) = .empty;
    var r = pb.Reader.init(data);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        switch (tag.number) {
            1 => {
                if (tag.wire_type != .length_delimited) return error.InvalidFormat;
                const msg = try r.readBytes();
                const code = (try msgCodeLower(arena, msg)) orelse continue;
                var cidrs: std.ArrayList(Cidr) = .empty;
                try parseCidrs(arena, msg, &cidrs);
                if (cidrs.items.len > 0) try entries.append(arena, .{ .code = code, .cidrs = cidrs.items });
            },
            else => try r.skipField(tag.wire_type),
        }
    }
    return entries.items;
}

/// 一次遍历 geosite.dat，提取全部 site 的域名四分类。
pub fn parseAllSites(arena: std.mem.Allocator, data: []const u8) ![]SiteEntry {
    var entries: std.ArrayList(SiteEntry) = .empty;
    var r = pb.Reader.init(data);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        switch (tag.number) {
            1 => {
                if (tag.wire_type != .length_delimited) return error.InvalidFormat;
                const msg = try r.readBytes();
                const tagname = (try msgCodeLower(arena, msg)) orelse continue;
                var domains: std.ArrayList([]const u8) = .empty;
                var suffixes: std.ArrayList([]const u8) = .empty;
                var keywords: std.ArrayList([]const u8) = .empty;
                var regexes: std.ArrayList([]const u8) = .empty;
                try parseGeoSiteDomains(arena, msg, &domains, &suffixes, &keywords, &regexes);
                if (domains.items.len > 0 or suffixes.items.len > 0 or
                    keywords.items.len > 0 or regexes.items.len > 0)
                {
                    try entries.append(arena, .{
                        .tag = tagname,
                        .domains = domains.items,
                        .domain_suffixes = suffixes.items,
                        .domain_keywords = keywords.items,
                        .domain_regexes = regexes.items,
                    });
                }
            },
            else => try r.skipField(tag.wire_type),
        }
    }
    return entries.items;
}

/// parseAllCountries 的**内过滤**变体：一次遍历 geoip.dat，仅提取指定 code
/// （小写）的 CIDR。过滤点必须在 msgCodeLower 之后、parseCidrs **之前** continue
/// ——「先全量 parse 再过滤」会物化全部国家的 CIDR（全量 geoip.dat 17MB），
/// 运行期按需转换路径内存不可接受。语义与「先 parseAllCountries 再按 code 过滤」
/// 等价（同序、同 code 小写归一、同「空 CIDR 块跳过」判据）。
/// code 不存在 → 空切片（调用方映射为 error.TagAbsent）。
pub fn parseAllCountriesFiltered(
    arena: std.mem.Allocator,
    data: []const u8,
    code: []const u8,
) ![]CountryEntry {
    var entries: std.ArrayList(CountryEntry) = .empty;
    var r = pb.Reader.init(data);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        switch (tag.number) {
            1 => {
                if (tag.wire_type != .length_delimited) return error.InvalidFormat;
                const msg = try r.readBytes();
                // 早退：非目标 code 不 dupe、不 parseCidrs（零中间物化）
                if (!try msgHasCode(msg, code)) continue;
                const tagname = (try msgCodeLower(arena, msg)) orelse continue;
                var cidrs: std.ArrayList(Cidr) = .empty;
                try parseCidrs(arena, msg, &cidrs);
                if (cidrs.items.len > 0) try entries.append(arena, .{ .code = tagname, .cidrs = cidrs.items });
            },
            else => try r.skipField(tag.wire_type),
        }
    }
    return entries.items;
}

/// parseAllSites 的**内过滤**变体：一次遍历 geosite.dat，仅提取指定 tag（小写）
/// 的域名四分类。过滤点必须在 msgCodeLower 之后、parseGeoSiteDomains **之前**
/// continue（理由同 parseAllCountriesFiltered）。tag 不存在 → 空切片。
pub fn parseAllSitesFiltered(
    arena: std.mem.Allocator,
    data: []const u8,
    target: []const u8,
) ![]SiteEntry {
    var entries: std.ArrayList(SiteEntry) = .empty;
    var r = pb.Reader.init(data);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        switch (tag.number) {
            1 => {
                if (tag.wire_type != .length_delimited) return error.InvalidFormat;
                const msg = try r.readBytes();
                if (!try msgHasCode(msg, target)) continue; // 早退：不 dupe 域名、不 parse
                const tagname = (try msgCodeLower(arena, msg)) orelse continue;
                var domains: std.ArrayList([]const u8) = .empty;
                var suffixes: std.ArrayList([]const u8) = .empty;
                var keywords: std.ArrayList([]const u8) = .empty;
                var regexes: std.ArrayList([]const u8) = .empty;
                try parseGeoSiteDomains(arena, msg, &domains, &suffixes, &keywords, &regexes);
                if (domains.items.len > 0 or suffixes.items.len > 0 or
                    keywords.items.len > 0 or regexes.items.len > 0)
                {
                    try entries.append(arena, .{
                        .tag = tagname,
                        .domains = domains.items,
                        .domain_suffixes = suffixes.items,
                        .domain_keywords = keywords.items,
                        .domain_regexes = regexes.items,
                    });
                }
            },
            else => try r.skipField(tag.wire_type),
        }
    }
    return entries.items;
}

/// 解析 GeoSiteList，提取指定 tag 的域名四分类结果。
/// 找不到 tag 或结果全空 → null。
fn parseSite(
    arena: std.mem.Allocator,
    data: []const u8,
    tag: []const u8,
) !?SiteResult {
    var r = pb.Reader.init(data);
    var domains: std.ArrayList([]const u8) = .empty;
    var suffixes: std.ArrayList([]const u8) = .empty;
    var keywords: std.ArrayList([]const u8) = .empty;
    var regexes: std.ArrayList([]const u8) = .empty;
    while (r.remaining() > 0) {
        const tag_field = try r.readTag();
        switch (tag_field.number) {
            1 => { // GeoSite 消息
                if (tag_field.wire_type != .length_delimited) return error.InvalidFormat;
                const msg = try r.readBytes();
                if (try msgHasCode(msg, tag)) {
                    try parseGeoSiteDomains(arena, msg, &domains, &suffixes, &keywords, &regexes);
                    if (domains.items.len == 0 and suffixes.items.len == 0 and
                        keywords.items.len == 0 and regexes.items.len == 0)
                    {
                        return null;
                    }
                    return SiteResult{
                        .domains = domains.items,
                        .domain_suffixes = suffixes.items,
                        .domain_keywords = keywords.items,
                        .domain_regexes = regexes.items,
                    };
                }
            },
            else => try r.skipField(tag_field.wire_type), // 忽略未知字段
        }
    }
    return null;
}

/// 检查消息的 country_code 字段（=1，length-delimited）是否等于目标值。
/// GeoIP 与 GeoSite 均以 country_code 作为字段 1。
/// 大小写不敏感（对齐 mihomo `strings.EqualFold`）：.dat 文件内 code 可能为大写
/// （如 MetaCubeX geosite-lite 的 "GOOGLE"/"CN"），而门面已统一将查询转为小写，
/// 故此处必须忽略大小写，否则小写查询无法命中大写 tag（现有 dat 测试曾因
/// `orelse return` 静默跳过而未暴露此问题）。
fn msgHasCode(msg: []const u8, code: []const u8) !bool {
    var r = pb.Reader.init(msg);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        if (tag.number == 1) {
            if (tag.wire_type != .length_delimited) return error.InvalidFormat;
            if (std.ascii.eqlIgnoreCase(try r.readBytes(), code)) return true;
        } else {
            try r.skipField(tag.wire_type);
        }
    }
    return false;
}

/// 解析 GeoIP 消息中的全部 CIDR 条目（字段 2），追加到 out
fn parseCidrs(arena: std.mem.Allocator, msg: []const u8, out: *std.ArrayList(Cidr)) !void {
    var r = pb.Reader.init(msg);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        if (tag.number == 2) { // cidr
            if (tag.wire_type != .length_delimited) return error.InvalidFormat;
            try out.append(arena, try parseCidr(try r.readBytes()));
        } else {
            try r.skipField(tag.wire_type);
        }
    }
}

/// 解析 CIDR{ip=1, prefix=2} 消息 → Cidr 值类型（零分配）
fn parseCidr(msg: []const u8) !Cidr {
    var ip: []const u8 = &.{};
    var prefix: u8 = 0;
    var r = pb.Reader.init(msg);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        switch (tag.number) {
            1 => {
                if (tag.wire_type != .length_delimited) return error.InvalidFormat;
                ip = try r.readBytes();
            },
            2 => {
                if (tag.wire_type != .varint) return error.InvalidFormat;
                const p = try r.readVarint();
                if (p > 255) return error.InvalidFormat;
                prefix = @intCast(p);
            },
            else => try r.skipField(tag.wire_type),
        }
    }
    if (ip.len == 4) {
        if (prefix > 32) return error.InvalidFormat;
        // 网络字节序 → 主机序 u32（Cidr4.network 为主机序）
        return Cidr{ .v4 = .{ .network = std.mem.readInt(u32, ip[0..4], .big), .mask_bits = prefix } };
    } else if (ip.len == 16) {
        if (prefix > 128) return error.InvalidFormat;
        // Cidr6.base 为网络字节序 [16]u8，直接拷贝
        var base: [16]u8 = undefined;
        std.mem.copyForwards(u8, base[0..], ip[0..16]);
        return Cidr{ .v6 = .{ .base = base, .mask_bits = prefix } };
    }
    return error.InvalidFormat;
}

/// Domain.type 枚举（v2fly Domain_Type）
const DomainType = enum {
    plain, // 0 → domain_keywords（keyword 子串）
    regex, // 1 → domain_regexes（P3 起收集；此前丢弃，srs domain_regex 等价承载）
    domain, // 2 → domain_suffixes（裸域名后缀）
    full, // 3 → domains（精确）
};

/// 解析后的 Domain 条目
const ParsedDomain = struct {
    domain_type: DomainType,
    value: []const u8, // 引用 mmap buffer（临时，unmap 后失效，须 dupe 拷贝）
};

/// 解析 Domain{type=1, value=2} 消息。
/// 未知 type 值（>3）→ 显式错误（意外状态不得静默吞掉）。
fn parseDomain(msg: []const u8) !ParsedDomain {
    var domain_type: DomainType = .plain;
    var value: []const u8 = &.{};
    var r = pb.Reader.init(msg);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        switch (tag.number) {
            1 => {
                if (tag.wire_type != .varint) return error.InvalidFormat;
                domain_type = switch (try r.readVarint()) {
                    0 => .plain,
                    1 => .regex,
                    2 => .domain,
                    3 => .full,
                    else => return error.InvalidFormat,
                };
            },
            2 => {
                if (tag.wire_type != .length_delimited) return error.InvalidFormat;
                value = try r.readBytes();
            },
            else => try r.skipField(tag.wire_type),
        }
    }
    return .{ .domain_type = domain_type, .value = value };
}

/// 解析 GeoSite 消息的 Domain 条目（字段 2），按 type 四分类追加
fn parseGeoSiteDomains(
    arena: std.mem.Allocator,
    msg: []const u8,
    domains: *std.ArrayList([]const u8),
    suffixes: *std.ArrayList([]const u8),
    keywords: *std.ArrayList([]const u8),
    regexes: *std.ArrayList([]const u8),
) !void {
    var r = pb.Reader.init(msg);
    while (r.remaining() > 0) {
        const tag = try r.readTag();
        if (tag.number == 2) { // domain
            if (tag.wire_type != .length_delimited) return error.InvalidFormat;
            const d = try parseDomain(try r.readBytes());
            switch (d.domain_type) {
                // d.value 引用 mmap buffer，须 dupe 拷贝到 arena（否则 unmap 后悬垂）
                .domain => try suffixes.append(arena, try arena.dupe(u8, d.value)),
                .full => try domains.append(arena, try arena.dupe(u8, d.value)),
                .plain => try keywords.append(arena, try arena.dupe(u8, d.value)),
                .regex => try regexes.append(arena, try arena.dupe(u8, d.value)),
            }
        } else {
            try r.skipField(tag.wire_type);
        }
    }
}

fn appendVarint(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (true) {
        var b: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) b |= 0x80;
        try buf.append(a, b);
        if (v == 0) break;
    }
}

/// 编码 length-delimited 字段（field_number, bytes）
fn appendField(buf: *std.ArrayList(u8), a: std.mem.Allocator, number: u32, value: []const u8) !void {
    try appendVarint(buf, a, (@as(u64, number) << 3) | 2);
    try appendVarint(buf, a, value.len);
    try buf.appendSlice(a, value);
}

/// 编码 varint 字段（field_number, value）
fn appendVarintField(buf: *std.ArrayList(u8), a: std.mem.Allocator, number: u32, value: u64) !void {
    try appendVarint(buf, a, (@as(u64, number) << 3) | 0);
    try appendVarint(buf, a, value);
}

/// 构造 CIDR{ip=1, prefix=2} 消息
fn buildCidr(a: std.mem.Allocator, ip: []const u8, prefix: u64) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendField(&buf, a, 1, ip);
    try appendVarintField(&buf, a, 2, prefix);
    return buf.items;
}

/// 构造 GeoIP{country_code=1, cidr=2[]} 消息
fn buildGeoIp(a: std.mem.Allocator, code: []const u8, cidrs: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendField(&buf, a, 1, code);
    for (cidrs) |c| try appendField(&buf, a, 2, c);
    return buf.items;
}

/// 构造 Domain{type=1, value=2} 消息
fn buildDomain(a: std.mem.Allocator, domain_type: u64, value: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendVarintField(&buf, a, 1, domain_type);
    try appendField(&buf, a, 2, value);
    return buf.items;
}

/// 构造 GeoSite{country_code=1, domain=2[]} 消息
fn buildGeoSite(a: std.mem.Allocator, tag: []const u8, domains: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendField(&buf, a, 1, tag);
    for (domains) |d| try appendField(&buf, a, 2, d);
    return buf.items;
}

/// 构造 GeoIPList（repeated GeoIP 消息，字段 1）
fn buildGeoIpList(a: std.mem.Allocator, geos: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (geos) |g| try appendField(&buf, a, 1, g);
    return buf.items;
}

/// 构造 GeoSiteList（repeated GeoSite 消息，字段 1）
fn buildGeoSiteList(a: std.mem.Allocator, sites: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (sites) |s| try appendField(&buf, a, 1, s);
    return buf.items;
}

// ---- 解析器单测（纯内存，恒跑） ----

const testing = std.testing;

test "dat: parseAllCountries/Sites 全量遍历（fixture 冒烟）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // GeoIP fixture：cn 一条 v4 段
    const cidr_txt = try buildCidr(a, &.{ 10, 0, 0, 0 }, 8);
    const ip_list = try buildGeoIpList(a, &.{try buildGeoIp(a, "cn", &.{cidr_txt})});
    const cs = try parseAllCountries(a, ip_list);
    try testing.expectEqual(@as(usize, 1), cs.len);
    try testing.expectEqualStrings("cn", cs[0].code);
    try testing.expectEqual(@as(usize, 1), cs[0].cidrs.len);
    try testing.expect(cs[0].cidrs[0] == .v4);

    // GeoSite fixture：google 一个后缀域名
    const dom = try buildDomain(a, 2, ".google.com"); // 2 = suffix（协议枚举对齐上游）
    const site_list = try buildGeoSiteList(a, &.{try buildGeoSite(a, "google", &.{dom})});
    const ss = try parseAllSites(a, site_list);
    try testing.expectEqual(@as(usize, 1), ss.len);
    try testing.expectEqualStrings("google", ss[0].tag);
    try testing.expectEqual(@as(usize, 1), ss[0].domain_suffixes.len);
    try testing.expectEqualStrings(".google.com", ss[0].domain_suffixes[0]);
}
