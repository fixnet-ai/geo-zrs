//! dat/protobuf.zig — V2Ray protobuf wire 格式解析器（局部实现）
//!
//! 仅服务 geodb/dat.zig 单一消费点（geoip.dat / geosite.dat 解析），
//! 不膨胀 zigfoundation：zigfoundation endian 无 varint，varint 在此实现。
//!
//! protobuf wire format:
//!   tag = (field_number << 3) | wire_type
//!   wire_type: 0=varint, 1=64-bit, 2=length-delimited, 5=32-bit
//!   varint 编码与 Go binary.Uvarint 一致（可复用 srs/binary.zig readUvarint 逻辑）
//!
//! 本模块只读字节切片、不分配内存；length-delimited 字段返回原始数据切片。

const std = @import("std");

/// protobuf wire 类型
pub const WireType = enum(u3) {
    varint = 0,
    i64 = 1,
    length_delimited = 2,
    group_start = 3,
    group_end = 4,
    i32 = 5,

    /// 从 wire 值解码；group(3/4) 与非法值(6/7) 返回错误
    pub fn fromValue(v: u3) !WireType {
        return switch (v) {
            0 => .varint,
            1 => .i64,
            2 => .length_delimited,
            5 => .i32,
            3, 4, 6, 7 => error.UnsupportedWireType,
        };
    }
};

/// 解码后的字段头（field_number + wire_type）
pub const Field = struct {
    number: u32,
    wire_type: WireType,
};

/// protobuf 二进制读取器（只读切片，不分配）
pub const Reader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }

    /// 剩余未读字节数
    pub fn remaining(self: Reader) usize {
        return self.data.len -| self.pos;
    }

    pub fn readByte(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfStream;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// 读取 protobuf varint（与 Go binary.Uvarint 编码一致）。
    /// shift 用 u7 防止溢出；超过 10 字节的恶意 varint 返回 error。
    pub fn readVarint(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try self.readByte();
            if (shift >= 64) return error.InvalidData; // 第 10 字节之后的高位会被截断
            result |= (@as(u64, b & 0x7f) << @as(u6, @intCast(shift)));
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    /// 读取字段 tag → Field{number, wire_type}。
    /// tag=0 与 field_number=0 非法（protobuf 规范禁止）。
    pub fn readTag(self: *Reader) !Field {
        const raw = try self.readVarint();
        if (raw > std.math.maxInt(u32)) return error.InvalidData;
        const number: u32 = @intCast(raw >> 3);
        if (number == 0) return error.InvalidData;
        return .{ .number = number, .wire_type = try WireType.fromValue(@intCast(raw & 7)) };
    }

    /// 读取 length-delimited 字节切片（引用原始数据，不分配）
    pub fn readBytes(self: *Reader) ![]const u8 {
        const len = try self.readVarint();
        if (len > self.remaining()) return error.UnexpectedEndOfStream;
        const n: usize = @intCast(len);
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    /// 跳过当前字段（按 wire_type），用于忽略未知/不相关字段
    pub fn skipField(self: *Reader, wire_type: WireType) !void {
        switch (wire_type) {
            .varint => _ = try self.readVarint(),
            .length_delimited => {
                const len = try self.readVarint();
                if (len > self.remaining()) return error.UnexpectedEndOfStream;
                self.pos += @as(usize, @intCast(len));
            },
            .i64 => {
                if (self.remaining() < 8) return error.UnexpectedEndOfStream;
                self.pos += 8;
            },
            .i32 => {
                if (self.remaining() < 4) return error.UnexpectedEndOfStream;
                self.pos += 4;
            },
            .group_start, .group_end => return error.UnsupportedWireType,
        }
    }
};

// =============================================================================
// 测试（纯内存构造，恒跑）
// =============================================================================

const testing = std.testing;

/// 测试辅助：编码 varint（与 readVarint 对称）
fn encVarint(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (true) {
        var b: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) b |= 0x80;
        try buf.append(alloc, b);
        if (v == 0) break;
    }
}

test "protobuf: varint 解码" {
    const cases = [_]struct { bytes: []const u8, want: u64 }{
        .{ .bytes = &.{0x00}, .want = 0 },
        .{ .bytes = &.{0x01}, .want = 1 },
        .{ .bytes = &.{ 0x96, 0x01 }, .want = 150 },
        .{ .bytes = &.{ 0xac, 0x02 }, .want = 300 },
        .{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, .want = 4294967295 },
        // u64 最大值：9×0xff + 0x01（10 字节）
        .{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, .want = std.math.maxInt(u64) },
    };
    for (cases) |c| {
        var r = Reader.init(c.bytes);
        try testing.expectEqual(c.want, try r.readVarint());
        try testing.expectEqual(@as(usize, 0), r.remaining());
    }
}

test "protobuf: varint 空数据/截断 → 错误" {
    // 空数据
    var r = Reader.init(&.{});
    _ = r.readVarint() catch |err| {
        try testing.expectEqual(error.UnexpectedEndOfStream, err);
        return;
    };
    @panic("预期报错但实际成功");
}

test "protobuf: varint 截断（高位=1 但数据结束）→ 错误" {
    var r = Reader.init(&.{0x80});
    _ = r.readVarint() catch |err| {
        try testing.expectEqual(error.UnexpectedEndOfStream, err);
        return;
    };
    @panic("预期报错但实际成功");
}

test "protobuf: varint 超长（>10 字节）→ 错误" {
    // 11 字节 0xff：第 11 字节读到 shift=70 ≥ 64 → InvalidData
    var r = Reader.init(&[_]u8{0xff} ** 11);
    _ = r.readVarint() catch |err| {
        try testing.expectEqual(error.InvalidData, err);
        return;
    };
    @panic("预期报错但实际成功");
}

test "protobuf: tag 解码" {
    // field 1, length_delimited → tag = (1<<3)|2 = 0x0a
    var r = Reader.init(&.{0x0a});
    const f1 = try r.readTag();
    try testing.expectEqual(@as(u32, 1), f1.number);
    try testing.expectEqual(WireType.length_delimited, f1.wire_type);

    // field 2, varint → tag = (2<<3)|0 = 0x10
    r = Reader.init(&.{0x10});
    const f2 = try r.readTag();
    try testing.expectEqual(@as(u32, 2), f2.number);
    try testing.expectEqual(WireType.varint, f2.wire_type);

    // 大字段号 300 → tag = (300<<3)|0
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    try encVarint(&buf, arena.allocator(), (@as(u64, 300) << 3) | 0);
    r = Reader.init(buf.items);
    const f3 = try r.readTag();
    try testing.expectEqual(@as(u32, 300), f3.number);
    try testing.expectEqual(WireType.varint, f3.wire_type);

    // group wire type (3) → 错误
    r = Reader.init(&.{0x0b}); // (1<<3)|3
    _ = r.readTag() catch |err| {
        try testing.expectEqual(error.UnsupportedWireType, err);
        return;
    };
    @panic("预期报错但实际成功");
}

test "protobuf: tag=0 非法" {
    var r = Reader.init(&.{0x00});
    _ = r.readTag() catch |err| {
        try testing.expectEqual(error.InvalidData, err);
        return;
    };
    @panic("预期报错但实际成功");
}

test "protobuf: readBytes" {
    // len=5 "hello"
    var r = Reader.init(&.{ 0x05, 'h', 'e', 'l', 'l', 'o' });
    const s = try r.readBytes();
    try testing.expectEqualStrings("hello", s);
    try testing.expectEqual(@as(usize, 0), r.remaining());
}

test "protobuf: readBytes 超长 → 错误" {
    // 声明 len=10 但只有 2 字节数据
    var r = Reader.init(&.{ 0x0a, 0x01, 0x02 });
    _ = r.readBytes() catch |err| {
        try testing.expectEqual(error.UnexpectedEndOfStream, err);
        return;
    };
    @panic("预期报错但实际成功");
}

test "protobuf: skipField 各 wire type" {
    // varint: 0x96 0x01 = 150
    var r = Reader.init(&.{ 0x96, 0x01, 0x00 });
    try r.skipField(.varint);
    try testing.expectEqual(@as(usize, 2), r.pos);

    // length-delimited: len=2 "hi"
    r = Reader.init(&.{ 0x02, 'h', 'i', 0x00 });
    try r.skipField(.length_delimited);
    try testing.expectEqual(@as(usize, 3), r.pos);

    // i64: 8 字节
    r = Reader.init(&[_]u8{0} ** 8);
    try r.skipField(.i64);
    try testing.expectEqual(@as(usize, 8), r.pos);

    // i32: 4 字节
    r = Reader.init(&[_]u8{0} ** 4);
    try r.skipField(.i32);
    try testing.expectEqual(@as(usize, 4), r.pos);
}

test "protobuf: 空数据 remaining=0" {
    const r = Reader.init(&.{});
    try testing.expectEqual(@as(usize, 0), r.remaining());
    try testing.expect(r.pos <= r.data.len);
}
