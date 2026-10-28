# geo-zrs

预转换的 GeoIP / GeoSite 全量规则库（zrs 格式，滚动 latest + sha256 清单）。
上游：[Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) 与
[MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) 的 release `dat`，
经 [zigroute](../zigroute) 的 `zrs-convert` 转换（同源同工具，与 fixnet 内嵌基础库同血缘）。

## 快速开始

```sh
# 清单（小文件，判断新旧）
curl -L https://cdn.jsdelivr.net/gh/fixnet-ai/geo-zrs@main/latest.json
# 数据（jsdelivr 镜像；GitHub raw 为兜底源）
curl -L -o geoip.zrs    https://cdn.jsdelivr.net/gh/fixnet-ai/geo-zrs@main/geoip.zrs
curl -L -o geosite.zrs https://cdn.jsdelivr.net/gh/fixnet-ai/geo-zrs@main/geosite.zrs
```

## 配置与 API

| 文件 | 说明 |
| --- | --- |
| `geoip.zrs` / `geosite.zrs` | 全量库产物（zrs v2 格式：magic `ZRS2`） |
| `latest.json` | `v` / `updated_at`（YYYY-MM-DD）/ `geoip`、`geosite` 各含 `size`、`sha256` |
| `update.sh` | 一键更新（`ZIGROUTE=<检出路径> ./update.sh`；只碰上述三文件，不触及 `diag/`） |
| `diag/` | 链路解锁判定表（独立资产、独立版本节奏）：`rules.json` + `manifest.json`（sha256）。真源=kiss 仓 `docs/diag-rules/sites.yaml`，经 kiss-core `diag_table` 编译后由 kiss 仓 `docs/diag-rules/publish.sh` 推入此处 |

新旧判定 = 清单 `sha256` 对比本地，不使用 etag / 304。

## 边界情况

- 下载产物 `sha256`/`size` 与清单不符 = 截断或损坏，丢弃重试，不得装载。
- jsdelivr 对单文件有 20MB 上限且偶发被掐：GitHub raw（`raw.githubusercontent.com/fixnet-ai/geo-zrs/main/…`）为第二源。
- `updated_at` 是数据生成日，非发布承诺节奏；客户端应以 sha 为唯一判据。
