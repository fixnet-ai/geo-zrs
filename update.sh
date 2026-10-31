#!/usr/bin/env bash
# update.sh — 拉最新上游 dat → zrs-convert 转换 → 刷 latest.json → commit push。
# 依赖：ZIGROUTE=<zigroute 检出路径>（含 zig build zrs-convert 产物链）+ 可达代理 PROXY。
set -euo pipefail
: "${ZIGROUTE:?ZIGROUTE=<zigroute 检出路径> 必须设置}"
PROXY="${PROXY:-http://127.0.0.1:7890}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
curl -sS -x "$PROXY" -L -o "$WORK/geoip.dat"    https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip.dat
curl -sS -x "$PROXY" -L -o "$WORK/geosite.dat" https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat

cp "$WORK/geoip.dat"    "$ZIGROUTE/src/geodb/testdata/full/geoip.dat"
cp "$WORK/geosite.dat" "$ZIGROUTE/src/geodb/testdata/full/geosite.dat"
(cd "$ZIGROUTE" && zig build zrs-convert)

cp "$ZIGROUTE/src/geodb/testdata/zrs-full/geoip.zrs"    "$REPO_DIR/"
cp "$ZIGROUTE/src/geodb/testdata/zrs-full/geosite.zrs" "$REPO_DIR/"

IP_SHA=$(shasum -a 256 "$REPO_DIR/geoip.zrs"    | cut -d' ' -f1)
DOM_SHA=$(shasum -a 256 "$REPO_DIR/geosite.zrs" | cut -d' ' -f1)
IP_SIZE=$(stat -f%z "$REPO_DIR/geoip.zrs")
DOM_SIZE=$(stat -f%z "$REPO_DIR/geosite.zrs")
TODAY=$(date +%F)
cat > "$REPO_DIR/latest.json" <<JSON
{
  "v": 1,
  "updated_at": "$TODAY",
  "geoip": { "size": $IP_SIZE, "sha256": "$IP_SHA" },
  "geosite": { "size": $DOM_SIZE, "sha256": "$DOM_SHA" }
}
JSON

git -C "$REPO_DIR" add geoip.zrs geosite.zrs latest.json

# ── 分流数据集镜像腿（2026-10-31 latest.json 判定迁移）─────────────────────
# 7 件 srs @MetaCubeX@sing → datasets/<tag>.srs + datasets.json（tag→size+sha256，
# 客户端探测/刷新的唯一新鲜度判据——etag/304 跨源不可信裁定在此通道整族退役）。
DATASET_TAGS=(category-ai-\!cn category-ads-all geosite-cn geoip-cn geosite-google geosite-github geosite-gfw)
for t in "${DATASET_TAGS[@]}"; do
  curl -sS -x "$PROXY" -L -o "datasets/$t.srs" \
    "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/$t.srs" \
    || curl -sS -x "$PROXY" -L -o "datasets/$t.srs" \
    "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/${t#geoip-}.srs"
done
python3 - <<'PY'
import hashlib, json, glob, os
tags = ["category-ai-!cn","category-ads-all","geosite-cn","geoip-cn","geosite-google","geosite-github","geosite-gfw"]
ds = {}
for t in tags:
    p = f"datasets/{t}.srs"
    b = open(p, "rb").read()
    ds[t] = {"size": len(b), "sha256": hashlib.sha256(b).hexdigest()}
m = {"v": 1, "updated_at": os.popen("date +%F").read().strip(), "datasets": ds}
open("datasets.json", "w").write(json.dumps(m, ensure_ascii=False, indent=2) + "\n")
PY
git -C "$REPO_DIR" add datasets datasets.json

git -C "$REPO_DIR" -c user.name=fixnet-ai -c user.email=28281228+fixnet-ai@users.noreply.github.com \
  commit -m "data: refresh full zrs ($TODAY)" || { echo 'no changes'; exit 0; }
git -C "$REPO_DIR" push origin main

# jsDelivr 边缘缓存主动失效（@main 可变引用边缘 TTL ~12h，不 purge 设备要等一个
# TTL 窗口才见新表——2026-10-31 mode-profiles v4 实锚；官方工具页
# https://www.jsdelivr.com/tools/purge 的 API 形态）。发布物全清；purge 失败
# 只警告不阻断（旧缓存内容自洽，最坏晚一个 TTL 生效）。
PURGE_FILES=(latest.json geoip.zrs geosite.zrs mode-profiles.json datasets.json)
for t in category-ai-\!cn category-ads-all geosite-cn geoip-cn geosite-google geosite-github geosite-gfw; do
  PURGE_FILES+=("datasets/$t.srs")
done
for f in "${PURGE_FILES[@]}"; do
  curl -sS -x "$PROXY" "https://purge.jsdelivr.net/gh/fixnet-ai/geo-zrs@main/$f" \
    | grep -q '"status"[[:space:]]*:[[:space:]]*"finished"' \
    || echo "WARN: purge $f 未确认（CDN 可能仍陈旧一个 TTL）"
done

echo "updated: $TODAY ip=$IP_SHA dom=$DOM_SHA"
