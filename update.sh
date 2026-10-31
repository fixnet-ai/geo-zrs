#!/usr/bin/env bash
# update.sh v2 — 数据集分发架构（2026-10-31 定稿，kiss docs/routing-program.md §9）
#
# 上游 dat → zrs-convert（容器 + ads 轻量覆盖）→ zip → dist/ → version.json v2
# → GitHub Release 资产发布（git 历史零增长）。
#
# 数据源 = GitHub raw 唯一（jsDelivr 全族退役，用户裁定 2026-10-31）。
#
# 用法：
#   ZIGROUTE=../zigroute ./update.sh            # 产出 dist/ + version.json（不发布）
#   ZIGROUTE=../zigroute ./update.sh --publish  # 产出 + gh release + commit push version.json
# 本地跑建议挂 PROXY（raw 被墙）；GitHub Action 内直连无需代理。
set -euo pipefail
PROXY="${PROXY:-http://127.0.0.1:7890}"
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1
REPO_SLUG="fixnet-ai/geo-zrs"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 本地有代理环境变量时才挂 -x（Action/可达网络直接连）
CURL=(curl -sS -f -L)
if [[ -n "${http_proxy:-}${https_proxy:-}" || -n "${USE_PROXY:-}" ]]; then
  CURL+=(-x "$PROXY")
fi

TAG="data-$(date +%Y%m%d)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DIST="$REPO_DIR/dist"; mkdir -p "$DIST"

# ── 1. 上游拉取（raw 唯一源）───────────────────────────────────────────────
"${CURL[@]}" -o "$WORK/geoip.dat"    https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip.dat
"${CURL[@]}" -o "$WORK/geosite.dat" https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geosite.dat
# ads 轻量集 = 本仓 vendor 的 ads-lite.txt（人可读三段式；源自 @sing 一次性导出，
# 更新时用消费方工具重新导出——本仓零 srs 解析依赖）

# ── 2. 转换（本仓自包含工具：容器 + ads-lite 覆盖；同批 full/base）──────────
mkdir -p "$WORK/src"
mv "$WORK/geoip.dat" "$WORK/geosite.dat" "$WORK/src/"
zig build zrs-convert
./zig-out/bin/zrs-convert --src "$WORK/src" --out "$DIST" --ads-override ads-lite.txt

# ── 3. zip + 指纹（双层：zip 下载完整性 / zrs 解压正确性）──────────────────
for n in geo-full geo-base; do
  (cd "$DIST" && rm -f "$n.zrs.zip" && zip -9 -q "$n.zrs.zip" "$n.zrs")
done

python3 - "$DIST" "$TAG" "$REPO_SLUG" <<'PY'
import hashlib, json, sys, os
dist, tag, slug = sys.argv[1], sys.argv[2], sys.argv[3]
def entry(name, with_url):
    b = open(os.path.join(dist, name), "rb").read()
    e = {"size": len(b), "sha256": hashlib.sha256(b).hexdigest()}
    if with_url:
        e["url"] = f"https://github.com/{slug}/releases/download/{tag}/{name}"
    return e
m = {
    "v": 2,
    "updated_at": tag.removeprefix("data-"),
    "tag": tag,
    "files": {
        "geo-full.zrs.zip": entry("geo-full.zrs.zip", True),
        "geo-full.zrs":     entry("geo-full.zrs", False),
        "geo-base.zrs.zip": entry("geo-base.zrs.zip", True),
        "geo-base.zrs":     entry("geo-base.zrs", False),
    },
}
open(os.path.join(dist, "version.json"), "w").write(json.dumps(m, indent=2) + "\n")
print("version.json:", json.dumps({k: f"{v['size']/1048576:.2f}MB" for k, v in m["files"].items()}))
PY

# ── 4. 发布（--publish：release 资产 + version.json 入仓；git 历史零增长）──
if [[ "$PUBLISH" == "1" ]]; then
  GH=(gh --repo "$REPO_SLUG")
  if [[ -n "${http_proxy:-}${https_proxy:-}" || -n "${USE_PROXY:-}" ]]; then
    GH=(env https_proxy="$PROXY" gh --repo "$REPO_SLUG")
  fi
  "${GH[@]}" release create "$TAG" \
    "$DIST/geo-full.zrs.zip" "$DIST/geo-base.zrs.zip" \
    --title "$TAG" --notes "dataset refresh $TAG (full ~15MB zrs / zip ~4.4MB; ads-lite override)" \
    --target main
  cp "$DIST/version.json" "$REPO_DIR/version.json"
  git -C "$REPO_DIR" add version.json
  git -C "$REPO_DIR" -c user.name=fixnet-ai -c user.email=28281228+fixnet-ai@users.noreply.github.com \
    commit -m "data: version.json $TAG" || { echo 'no changes'; exit 0; }
  git -C "$REPO_DIR" push origin main
  # 只保留最近 5 个 data-* release（旧资产随 release 删除，存储零累积）
  "${GH[@]}" release list --limit 100 | awk '/data-/ {print $3}' | tail -n +6 | \
    while read -r old; do "${GH[@]}" release delete "$old" --yes || true; done
fi

echo "done: $TAG (dist/ 下 geo-full.zrs.zip + geo-base.zrs.zip + version.json)"
