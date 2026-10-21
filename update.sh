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
git -C "$REPO_DIR" -c user.name=fixnet-ai -c user.email=28281228+fixnet-ai@users.noreply.github.com \
  commit -m "data: refresh full zrs ($TODAY)" || { echo 'no changes'; exit 0; }
git -C "$REPO_DIR" push origin main
echo "updated: $TODAY ip=$IP_SHA dom=$DOM_SHA"
