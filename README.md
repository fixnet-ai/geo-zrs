# geo-zrs

数据集分发仓（v2 架构，2026-10-31 定稿：kiss 仓 `docs/routing-program.md` §9）。
上游：[Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) 与
[MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) 的 release `dat`，
经 [zigroute](../zigroute) 的 `zrs-convert` 转成 **KZF1 复合容器**（domain+ip 两段，mmap 直查）。

## 快速开始

```sh
# 版本清单（小文件，判定唯一真源；GitHub raw 唯一，无 CDN）
curl -L https://raw.githubusercontent.com/fixnet-ai/geo-zrs/main/version.json
# 数据资产（GitHub Release，不进 git 历史）
curl -L -o geo-full.zrs.zip https://github.com/fixnet-ai/geo-zrs/releases/download/data-20261031/geo-full.zrs.zip
```

## 配置与 API

| 产物 | 说明 |
| --- | --- |
| `geo-full.zrs(.zip)` | 全量库容器（260 国 / 1563 站点，~14.8MB / zip ~4.4MB） |
| `geo-base.zrs(.zip)` | 裁剪库容器（cn+cn-ip+google+github+gfw+**ads 轻量版**，~2.2MB / zip ~0.76MB；app 构建内置源） |
| `version.json` | `v:2` / `tag` / `files`（zip 与解压后 zrs 双层 size+sha256，zip 条目带 release `url`） |
| `update.sh` | 一键刷新：`./update.sh [--publish]`（本仓自包含工具；--publish = release 资产 + version.json 入仓） |
| `.github/workflows/update.yml` | 每日 cron 自动刷新（需仓 secret `ORG_PAT`：对 fixnet-ai/zigroute 的 contents:read） |
| `ads-lite.txt` | 广告轻量集三段式文本（exact/suffix/keyword/regex；源自 @sing 905 条一次性导出，转换时覆盖上游重版） |
| `src/` | zrs 格式 + dat 解析 + 转换工具（Zig 包 `geozrs`；消费方 import 面 = zrs matcher/容器） |
| `diag/` | 链路解锁判定表（独立资产，不受本架构影响） |

同批产出 full 与 base（同上游同批转换）⇒ 两库公共 tag 点查结果一致。
`category-ads-all` 一律用 @sing 轻量集（~905 条）覆盖上游重版（Q9 裁定）。
新旧判定 = `version.json` sha256 对比本地；数据源 GitHub raw/releases 唯一（jsDelivr 全族退役）。

## 边界情况

- `version.json` 拉不到（raw 不可达）：静默退避下次再查，本地 base/full 照常使用。
- zip 下载损坏 / sha 不符：丢弃保旧；解压写出上限 = manifest 声明的 zrs `size`（防 zip 炸弹）。
- Release 只保留最近 5 个 `data-*` tag（旧资产随 release 删除，存储零累积）。
