//! geo-zrs 库面：zrs 格式唯一实现源（公开仓自包含）。
//! 消费方（zigroute 等）经 `@import("geozrs").zrs` 引用格式与 matcher。

pub const zrs = @import("zrs.zig");
pub const dat = @import("dat.zig");

test {
    _ = zrs;
    _ = dat;
}
