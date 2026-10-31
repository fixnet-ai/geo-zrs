# geo-zrs

Dataset distribution repo and the canonical home of the **zrs format** (ZRS2 segments + KZF1 composite container). Upstream: release `dat` files from [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) and [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat), converted by the self-contained tool in this repo. The repo has **zero private-ecosystem dependencies** — format implementation, matchers, and converter all live in `src/` — so consumers (e.g. zigroute) depend on this public repo, never the other way around, and the daily Action needs no cross-repo secrets.

## Quick Start

```sh
# Version manifest — the only freshness truth (GitHub raw, no CDN)
curl -L https://raw.githubusercontent.com/fixnet-ai/geo-zrs/main/version.json
# Dataset asset (GitHub Release; assets never enter git history)
curl -L -O https://github.com/fixnet-ai/geo-zrs/releases/latest/download/geo-full.zrs.zip
# Build & run the converter locally (expects geoip.dat + geosite.dat in src dir)
zig build zrs-convert
./zig-out/bin/zrs-convert --src <dat-dir> --out dist --ads-override ads-lite.txt
```

## Configuration & API

| Artifact | Description |
| --- | --- |
| `geo-full.zrs(.zip)` | Full container — 260 countries / 1,563 site tags (~15MB, zip ~4.4MB) |
| `geo-base.zrs(.zip)` | Trimmed container for in-app embedding — 12 datasets (~2.4MB, zip ~860KB) |
| `version.json` | `v:2` manifest: `tag`, `updated_at`, dual fingerprints per file (zip sha = download integrity, extracted zrs sha = extraction correctness); zip entries carry the release `url` |
| `update.sh` | One-shot refresh: `./update.sh [--publish]` — fetch upstream → convert (full + base from the same batch) → zip → manifest → Release + commit `version.json`; same-tag rerun is idempotent |
| `.github/workflows/update.yml` | Daily cron refresh (18:23 UTC); installs the official zig tarball itself, runs with zero secrets |
| `ads-lite.txt` | Lightweight ad list, human-editable sections `[exact]` `[suffix]` `[keyword]` `[regex]` (905 entries); replaces the ~194k-entry upstream `category-ads-all` at convert time |
| `src/` | `zrs.zig` — format, container, mmap point-query matchers · `dat.zig` — protobuf dat parser · `convert.zig` — converter tool · `memprobe.zig` — memory-form probe |
| `diag/` | Link-unlock decision tables (standalone assets, unrelated to the dataset pipeline) |

**Base dataset set (12)**: `cn` (IP + domain faces), `category-ads-all` (lite), `cloudflare` (CF loop guard / Workers dialing), `telegram` (always proxy), `google`, `github`, `gfw` (direct-profile exceptions), `category-ip-geo-detect` (diagnostic egress control), `tld-!cn` (non-CN TLD prior), `category-porn` (content rating), `category-games-!cn` (game routing).

**Format**: each `geo-*.zrs` is a **KZF1** composite — `[15B header | domain ZRS2 | ip ZRS2]`, both segments self-validating. Matchers binary-search flat sorted tables directly on **mmap'd file pages**: zero heap expansion, lazy paging (mapping costs +0KB RSS until touched — verified by `memprobe`), and clean pages stay reclaimable / outside iOS `phys_footprint`. Freshness is judged by `version.json` sha256 against the local file; etag/304 is never used.

## Edge Cases

- `version.json` unreachable (raw blocked): consumers back off silently and retry later; the local full/base library keeps working — the embedded base is always a complete fallback, full is an enhancement.
- Corrupt download or sha mismatch: consumers discard the partial file and keep the previous library; the manifest's declared zrs `size` caps extraction (zip-bomb guard) and the extracted sha must match before the file is swapped in.
- Only the 5 most recent `data-*` releases are kept (older assets deleted with their release — zero storage growth); same-day reruns delete and recreate the existing tag.
