#!/usr/bin/env bash
# 3106 正式版发布：构建 → 打包 → 校验 → 更新清单 → GitHub + Gitee 双端上传。
#
# 用法:
#   bash scripts/release.sh                 # 使用 project.pbxproj 中的版本号
#   bash scripts/release.sh 3.2.12          # 显式指定版本（必须与 pbxproj 一致）
#   bash scripts/release.sh --skip-build    # 复用 /tmp/3106-dd 的既有构建
#   bash scripts/release.sh --notes docs/releases/3.2.12.md
#
# 约定:
#   - 应用内更新检查与下载只走 Gitee；GitHub 仅作项目主页与镜像备份。
#   - 设置页与 README 的「项目地址」展示 GitHub（QuinnTangO/3106）。
#   - 两端必须上传同一 IPA 与同一 SHA256SUMS.txt。
#   - IPA 必须保留 Payload/3106.app/ 目录层，否则签名工具拒绝导入。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GH_REPO="QuinnTangO/3106"
GITEE_OWNER="tangzhanyuan"
GITEE_REPO="3106"
GITEE_API="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}"
DERIVED="/tmp/3106-dd"
PBX="ThreeOneOSSix.xcodeproj/project.pbxproj"

SKIP_BUILD=0
NOTES_FILE=""

log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- 参数 ----------------------------------------------------------------
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --notes) NOTES_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) [[ -z "$VERSION" ]] || die "多余参数: $1"; VERSION="$1"; shift ;;
  esac
done

PBX_VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PBX" | sed -E 's/.*= ([^;]+);/\1/')"
PBX_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBX" | sed -E 's/.*= ([^;]+);/\1/')"
[[ -n "$PBX_VERSION" && -n "$PBX_BUILD" ]] || die "无法从 project.pbxproj 读取版本号"

VERSION="${VERSION:-$PBX_VERSION}"
[[ "$VERSION" == "$PBX_VERSION" ]] || die "参数版本 $VERSION 与 pbxproj $PBX_VERSION 不一致，先改 pbxproj"
[[ -z "$NOTES_FILE" ]] || [[ -f "$NOTES_FILE" ]] || die "notes 文件不存在: $NOTES_FILE"

IPA_NAME="3106-${VERSION}-unsigned.ipa"
IPA="dist/${IPA_NAME}"
TAG="v${VERSION}"

log "发布 ${VERSION} (build ${PBX_BUILD}) → GitHub ${GH_REPO} + Gitee ${GITEE_OWNER}/${GITEE_REPO}"

# ---- 构建 ----------------------------------------------------------------
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  log "Release 构建"
  xcodebuild -project ThreeOneOSSix.xcodeproj -scheme 3106 -configuration Release \
    -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" -derivedDataPath "$DERIVED" build
else
  log "跳过构建（--skip-build）"
fi

APP="${DERIVED}/Build/Products/Release-iphoneos/3106.app"
[[ -d "$APP" ]] || die "找不到构建产物: $APP"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
APP_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" && "$APP_BUILD" == "$PBX_BUILD" ]] \
  || die "构建产物版本 ${APP_VERSION}(${APP_BUILD}) 与期望 ${VERSION}(${PBX_BUILD}) 不一致"
[[ "$APP_BUNDLE" == "com.qingtang.3106" ]] || die "Bundle ID 异常: $APP_BUNDLE"

# ---- 打包（必须保留 Payload/3106.app/） ----------------------------------
log "打包 ${IPA_NAME}"
mkdir -p dist
[[ ! -f "$IPA" ]] || cp -f "$IPA" "dist/backups/${IPA_NAME}.$(date +%Y%m%d-%H%M%S).bak"

WORK="$(mktemp -d /tmp/3106-ipa.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
( cd "$WORK" && zip -qry -X "$ROOT/$IPA" Payload -x "*.DS_Store" )

# ---- 产物校验 ------------------------------------------------------------
log "校验 IPA 结构与版本"
# Do not pipe `unzip -l` into `grep -q`: with `set -o pipefail`, grep exits at
# the first match, unzip receives SIGPIPE, and the pipeline reports failure
# even though the entry exists.
unzip -l "$IPA" > "$WORK/ipa-list.txt"
grep -q 'Payload/3106.app/Info.plist' "$WORK/ipa-list.txt" \
  || die "IPA 缺少 Payload/3106.app/ 目录层，签名工具会拒绝导入"
unzip -t "$IPA" >/dev/null || die "IPA zip 完整性校验失败"
if grep -qiE '__MACOSX|\.DS_Store' "$WORK/ipa-list.txt"; then
  die "IPA 含 __MACOSX/.DS_Store 杂项"
fi
rm -rf "$WORK/verify"
mkdir -p "$WORK/verify"
unzip -q "$IPA" -d "$WORK/verify"
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORK/verify/Payload/3106.app/Info.plist")"
B="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WORK/verify/Payload/3106.app/Info.plist")"
[[ "$V" == "$VERSION" && "$B" == "$PBX_BUILD" ]] || die "IPA 内版本 ${V}(${B}) 不一致"
file "$WORK/verify/Payload/3106.app/3106" | grep -q 'arm64' || die "可执行文件不是 arm64"

SHA="$(shasum -a 256 "$IPA" | awk '{print $1}')"
SIZE="$(stat -f%z "$IPA")"
log "SHA256 ${SHA} · ${SIZE} 字节"

# ---- 更新清单 ------------------------------------------------------------
log "更新 dist/SHA256SUMS.txt 与 update.json"
python3 - "$IPA_NAME" "$SHA" <<'PY'
import sys, pathlib
name, sha = sys.argv[1], sys.argv[2]
p = pathlib.Path('dist/SHA256SUMS.txt')
lines = [f"{sha}  {name}" if l.endswith(name) else l for l in p.read_text().splitlines()]
if not any(l.endswith(name) for l in lines):
    lines.append(f"{sha}  {name}")
p.write_text("\n".join(lines) + "\n")
PY

python3 - "$VERSION" "$PBX_BUILD" "$IPA_NAME" <<'PY'
import sys, json, pathlib, datetime
ver, build, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
p = pathlib.Path('update.json')
d = json.loads(p.read_text())
d['version'] = ver
d['build'] = build
d['page'] = f"https://gitee.com/tangzhanyuan/3106/releases/tag/v{ver}"
d['ipa'] = f"https://gitee.com/tangzhanyuan/3106/releases/download/v{ver}/{name}"
d['published'] = datetime.date.today().isoformat()
p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY

# ---- 发布说明 ------------------------------------------------------------
NOTES="$(mktemp /tmp/3106-notes.XXXXXX)"
if [[ -n "$NOTES_FILE" ]]; then
  cat "$NOTES_FILE" > "$NOTES"
else
  printf '## %s (build %s)\n\n' "$VERSION" "$PBX_BUILD" > "$NOTES"
fi
cat >> "$NOTES" <<EOF

## 下载

- IPA：\`${IPA_NAME}\`（未签名，需自行签名后安装）
- 体积：${SIZE} 字节
- SHA256：\`${SHA}\`
- 校验清单：\`SHA256SUMS.txt\`（Release 附件）
- Gitee：https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/releases/tag/${TAG}
- GitHub 镜像：https://github.com/${GH_REPO}/releases/tag/${TAG}
EOF

# ---- GitHub --------------------------------------------------------------
log "上传 GitHub ${TAG}"
if gh release view "$TAG" -R "$GH_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$IPA" dist/SHA256SUMS.txt --clobber -R "$GH_REPO"
  gh release edit "$TAG" -R "$GH_REPO" --notes-file "$NOTES"
else
  gh release create "$TAG" "$IPA" dist/SHA256SUMS.txt -R "$GH_REPO" \
    --title "3106 ${TAG} (build ${PBX_BUILD})" --notes-file "$NOTES" --target "$(git rev-parse HEAD)"
fi

# ---- Gitee ---------------------------------------------------------------
log "上传 Gitee ${TAG}"
TOKEN="$(printf 'protocol=https\nhost=gitee.com\n\n' | git credential fill 2>/dev/null \
  | awk -F= '/^password=/{print substr($0, index($0,"=")+1)}')"
[[ -n "$TOKEN" ]] || die "未能从 git credential 取得 Gitee token"

RELEASE_JSON="$(curl -sS --max-time 30 "${GITEE_API}/releases/tags/${TAG}?access_token=${TOKEN}")"
RELEASE_ID="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"

if [[ -z "$RELEASE_ID" ]]; then
  log "Gitee Release 不存在，创建 ${TAG}"
  CREATE_JSON="$(curl -sS --max-time 30 -X POST "${GITEE_API}/releases" \
    --data-urlencode "access_token=${TOKEN}" \
    --data-urlencode "tag_name=${TAG}" \
    --data-urlencode "name=3106 ${VERSION} (build ${PBX_BUILD})" \
    --data-urlencode "target_commitish=$(git rev-parse HEAD)" \
    --data-urlencode "body@${NOTES}")"
  RELEASE_ID="$(printf '%s' "$CREATE_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')"
  [[ -n "$RELEASE_ID" ]] || die "Gitee Release 创建失败: $CREATE_JSON"
fi

# 同名旧附件会被 Gitee 保留并优先下载，必须先删。
log "清理 Gitee 同名旧附件"
LIST_JSON="$(curl -sS --max-time 30 "${GITEE_API}/releases/${RELEASE_ID}/attach_files?access_token=${TOKEN}")"
printf '%s' "$LIST_JSON" > "$WORK/attach.json"
python3 - "$WORK/attach.json" "$IPA_NAME" <<'PY' | while read -r AID; do
import sys, json
assets = json.load(open(sys.argv[1]))
for a in assets:
    if a.get("name") in {sys.argv[2], "SHA256SUMS.txt"}:
        print(a["id"])
PY
  [[ -z "$AID" ]] || curl -sS -X DELETE "${GITEE_API}/releases/${RELEASE_ID}/attach_files/${AID}?access_token=${TOKEN}" >/dev/null
done

for F in "$IPA" dist/SHA256SUMS.txt; do
  log "Gitee 上传 $(basename "$F")"
  R="$(curl -sS --max-time 300 -X POST "${GITEE_API}/releases/${RELEASE_ID}/attach_files" \
    -F "access_token=${TOKEN}" \
    -F "file=@${F}")"
  printf '%s' "$R" | grep -q '"id"' || die "Gitee 上传失败: $R"
done

# 同步 Gitee Release 说明（PATCH 要求 tag_name/name/body 同时提供）。
curl -sS --max-time 60 -X PATCH "${GITEE_API}/releases/${RELEASE_ID}" \
  --data-urlencode "access_token=${TOKEN}" \
  --data-urlencode "tag_name=${TAG}" \
  --data-urlencode "name=3106 ${VERSION} (build ${PBX_BUILD})" \
  --data-urlencode "body@${NOTES}" >/dev/null

# ---- 验证 ----------------------------------------------------------------
log "回读两端资产"
GH_SIZE="$(gh api "repos/${GH_REPO}/releases/tags/${TAG}" --jq ".assets[] | select(.name==\"${IPA_NAME}\") | .size")"
[[ "$GH_SIZE" == "$SIZE" ]] || die "GitHub 资产大小不匹配: ${GH_SIZE:-缺失} != $SIZE"

curl -sS --max-time 30 "${GITEE_API}/releases/${RELEASE_ID}/attach_files?access_token=${TOKEN}" > "$WORK/attach-final.json"
GITEE_SIZE="$(python3 - "$WORK/attach-final.json" "$IPA_NAME" <<'PY'
import sys, json
assets = json.load(open(sys.argv[1]))
print(next((a["size"] for a in assets if a["name"] == sys.argv[2]), ""))
PY
)"
[[ "$GITEE_SIZE" == "$SIZE" ]] || die "Gitee 资产大小不匹配: ${GITEE_SIZE:-缺失} != $SIZE"

cat <<EOF

发布完成：
  IPA      ${IPA}
  SHA256   ${SHA}
  GitHub   https://github.com/${GH_REPO}/releases/tag/${TAG}
  Gitee    https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/releases/tag/${TAG}

还需提交清单与文档改动并推送两端：
  git add dist/SHA256SUMS.txt update.json README.md README.en.md CHANGELOG.md
  git commit -m "release: ${VERSION} (${PBX_BUILD})"
  git push gitee 3106 && git push github 3106
EOF