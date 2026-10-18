#!/bin/bash
# 把上游 blackmatrix7/ios_rule_script 的 rule/ 目录镜像到本仓库。
#
# 为什么要这个脚本（而不是直接 fork / 在 Surge 里直接引用上游）：
#   1. 上游每 2 天全量重生成一次，**每个文件头部的 `# UPDATED: <时间戳>` 都会变**。
#      不做处理的话，每次同步全部 1557 个文件都"变"了，仓库几个月就涨到 GB 级。
#      本脚本用「把时间戳掩码掉之后的内容」判断文件是否真的变了 —— 实测每次
#      只有约 3.5% 的文件真变，于是 git 每次只需存这几百 KB 增量。
#   2. 上游是 4.3 GB（5 个客户端 + 1990 个 icon + script/rewrite）。
#      这里只镜像 `rule/`（485 MB / 8841 文件），够 Surge/Clash/其他客户端用。
#
# 用法：
#   ./sync-rules.sh             本地：同步 + 统计（不提交，方便先看差异）
#   ./sync-rules.sh --commit    本地：同步 + 有变化才提交 + 推送
#   CI_STRICT=1 ./sync-rules.sh GitHub Actions：同步（由 workflow 负责提交）
set -u
cd "$(dirname "$0")" || exit 1

UPSTREAM="https://github.com/blackmatrix7/ios_rule_script.git"
UP_BRANCH="master"
WORK=".upstream"     # 上游稀疏克隆工作副本（.gitignore 排除）
SCOPE="rule"         # 只镜像这个目录
COMMIT=0
for a in "$@"; do case "$a" in
  --commit) COMMIT=1;;
  --no-push) :;;
  *) echo "未知参数: $a"; exit 2;;
esac; done

say() { printf '\033[36m▸\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 2; }

# ── 1. 取上游工作副本（稀疏克隆：只拉 rule/ 的 blob）──────────────
if [ ! -d "$WORK/.git" ]; then
  say "首次稀疏克隆上游（只取 $SCOPE/，跳过 3.8 GB 的 icon/script）"
  rm -rf "$WORK"
  git clone -q --filter=blob:none --sparse --depth 1 "$UPSTREAM" "$WORK" || die "克隆上游失败"
  git -C "$WORK" sparse-checkout set "$SCOPE" || die "设置 sparse-checkout 失败"
else
  say "更新上游（fetch ${UP_BRANCH}）"
  git -C "$WORK" fetch -q --filter=blob:none --depth 1 origin "$UP_BRANCH" || die "fetch 上游失败"
  git -C "$WORK" checkout -q -f FETCH_HEAD || die "checkout 上游失败"
  git -C "$WORK" sparse-checkout set "$SCOPE" >/dev/null 2>&1
fi
[ -d "$WORK/$SCOPE" ] || die "上游没有 $SCOPE/ 目录"
UP_SHA=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null || echo '?')
UP_DATE=$(git -C "$WORK" log -1 --format=%cI 2>/dev/null || echo '?')
say "上游版本 ${UP_SHA}（${UP_DATE}）"

# ── 2. 同步：只在「掩码时间戳后的内容」真变时覆盖文件 ────────────
# 数据全部用「文件参数」传给 python，不用管道（heredoc 已占用 stdin）。
STATS=$(python3 - "$WORK/$SCOPE" "$SCOPE" <<'PY'
import sys, os, re, hashlib, shutil

src, dst = sys.argv[1], sys.argv[2]
# 时间戳掩码：覆盖三种上游格式
#   .list/.yaml :  # UPDATED: 2026-10-12 05:17:14
#   AdGuard .txt:  ! Updated: 2026-10-12 05:17:33
#   .sgmodule   :  #!desc=... 2025-06-06 09:13:23
TS = re.compile(rb'\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}')

def norm_bytes(raw: bytes) -> bytes:
    return TS.sub(b'<TS>', raw)

def walk(root):
    out = {}
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d != '.git']
        for fn in fns:
            fp = os.path.join(dp, fn)
            if os.path.islink(fp) or not os.path.isfile(fp):
                continue
            out[os.path.relpath(fp, root)] = fp
    return out

# ── 本地豁免：修上游误杀 ──────────────────────────────────
# 上游广告清单里的整域封禁会连带打死正常站点。这些域名在写入镜像时从
# Advertising 类文件里剔除；每次同步都重新应用，不会被上游覆盖回去。
# 只作用于 rule/<client>/Advertising/ 下的文件，其他类别一律不动。
EXEMPT_DOMAINS = (
    # Cafe24 电商基础设施。cafe24.poxo.com 是韩国 Cafe24 店铺最主要的商品图
    # CDN（一个商品页就引用 25 处），assets.poxo.com 是它的前端 jet.js。
    # AdGuard 的 ||poxo.com^ 会把所有 Cafe24 店铺的图片一并掐掉。
    'poxo.com',
)
# 一行里出现该域名（或它的子域）的整域规则才算命中：DOMAIN-SUFFIX,x /
# HOST-SUFFIX,x / DOMAIN,x / .x / +.x / ||x^ 都能覆盖。前后不能紧挨域名
# 字符或点，所以 mypoxo.com、poxo.com.evil.com 这类不会被误伤。
EXEMPT_LINE = re.compile(
    rb'(?<![a-z0-9-])(?:[a-z0-9-]+\.)*(?:'
    + b'|'.join(re.escape(d.encode()) for d in EXEMPT_DOMAINS)
    + rb')(?![a-z0-9.-])'
)

def strip_exempt(rel, raw):
    """剔除 Advertising 类文件里被误杀的整域规则；其他文件原样返回。"""
    if '/Advertising/' not in rel.replace(os.sep, '/'):
        return raw
    if not any(d.encode() in raw for d in EXEMPT_DOMAINS):
        return raw
    kept, removed = [], 0
    for line in raw.splitlines(keepends=True):
        body = line.strip()
        if body and not body.startswith((b'#', b'!', b';')) and EXEMPT_LINE.search(body):
            removed += 1
            continue
        kept.append(line)
    return b''.join(kept) if removed else raw

s, d = walk(src), walk(dst)
added = changed = 0
skipped = 0

for rel, sp in s.items():
    dp = os.path.join(dst, rel)
    raw = open(sp, 'rb').read()
    # 比对和写入都用「应用豁免后」的内容：否则带豁免的 Advertising 文件
    # 每次同步都会被判为"有变化"，白写一遍。
    out = strip_exempt(rel, raw)
    if rel in d:
        # 已有文件：比"掩码后内容"，相同就原样保留（含旧时间戳），
        # 这样 git diff 只显示真正变了的文件，仓库不会虚胖。
        old = open(dp, 'rb').read()
        if norm_bytes(old) == norm_bytes(out):
            skipped += 1
            continue
        changed += 1
    else:
        added += 1
    os.makedirs(os.path.dirname(dp), exist_ok=True)
    with open(dp, 'wb') as f:
        f.write(out)                     # 上游内容（保留真实时间戳）+ 本地豁免

# 上游删掉的文件，镜像里也删掉
removed = 0
for rel in d:
    if rel not in s:
        os.remove(os.path.join(dst, rel))
        removed += 1

# 清掉空目录
for dp, dns, fns in os.walk(dst, topdown=False):
    if not os.listdir(dp):
        os.rmdir(dp)

print(f'{added} {changed} {skipped} {removed} {len(s)}')
PY
) || die "同步失败"

read -r ADDED CHANGED SKIPPED REMOVED TOTAL <<< "$STATS"
say "上游 $TOTAL 个文件：新增 ${ADDED}，内容变化 ${CHANGED}，未变 ${SKIPPED}（跳过），上游删除 $REMOVED"

# ── 3. 可选：提交 + 推送 ─────────────────────────────────────
if [ "$COMMIT" = 1 ]; then
  if [ -z "$(git status --porcelain)" ]; then
    say "无实质变化，不提交"
  else
    SUMMARY="+$ADDED ~$CHANGED -$REMOVED"
    say "提交（${SUMMARY}）"
    git add -A
    git commit -q -m "sync: 镜像上游 rule/ @${UP_SHA} ($SUMMARY)"
    say "推送"
    ok=0
    for i in 1 2 3; do
      if git push -q origin main; then ok=1; break; fi
      echo "    push 被拒，rebase 后重试 (#$i)…"
      git pull -q --rebase --autostash origin main || { echo "    ✗ rebase 冲突"; break; }
    done
    [ "$ok" = 1 ] && say "✓ 已推送" || die "推送未成功"
  fi
fi

# 供 workflow 读取
echo "added=$ADDED"     >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "changed=$CHANGED" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "removed=$REMOVED" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "upstream_sha=$UP_SHA" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
