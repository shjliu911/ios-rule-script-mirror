#!/bin/bash
# 从 rule/ 目录生成无 KEYWORD（去 keyword 化）的规则集，存入 rule-no-keyword/。
#
# 为什么要无 KEYWORD 规则集：
#   Surge 和 Loon 底层对 DOMAIN/DOMAIN-SUFFIX 有基于 Trie 树的高性能索引，
#   但遇到 DOMAIN-KEYWORD / HOST-KEYWORD 必须逐条进行全文子串扫描，
#   会导致请求延迟上升、CPU/电量消耗增加，且极易引发广谱误杀。
#   本脚本将上游规则全量去 KEYWORD 化，产出纯净规则集供 Surge/Loon/Clash 等直接引用。
#
# 增量更新机制：
#   同 sync-rules.sh 一致，采用时间戳掩码比对。
#   只有在规则内容发生实质变化时才覆盖目标文件，确保 git 历史轻量且只记录真实增量。
#
# 用法：
#   ./build-no-keyword.sh             本地：生成 + 增量统计（不提交）
#   ./build-no-keyword.sh --commit    本地：生成 + 有变化才提交并推送
#   CI_STRICT=1 ./build-no-keyword.sh GitHub Actions：生成（由 workflow 提交）
set -u
cd "$(dirname "$0")" || exit 1

SRC="rule"
DST="rule-no-keyword"
COMMIT=0

for a in "$@"; do case "$a" in
  --commit) COMMIT=1;;
  --no-push) :;;
  *) echo "未知参数: $a"; exit 2;;
esac; done

say() { printf '\033[36m▸\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 2; }

[ -d "$SRC" ] || die "源目录 $SRC 不存在，请先执行 sync-rules.sh"

say "开始从 $SRC 生成去 KEYWORD 规则集到 $DST/..."

STATS=$(python3 - "$SRC" "$DST" <<'PY'
import sys, os, re, shutil

src, dst = sys.argv[1], sys.argv[2]
TS = re.compile(rb'\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}')

def norm_bytes(raw: bytes) -> bytes:
    return TS.sub(b'<TS>', raw)

def process_file_content(raw: bytes, ext: str) -> tuple[bytes, int]:
    try:
        content = raw.decode('utf-8')
    except UnicodeDecodeError:
        return raw, 0

    if 'KEYWORD' not in content:
        return raw, 0

    lines = content.splitlines()
    new_lines = []
    removed_kw = 0
    total_idx = -1
    total_val = None

    for line in lines:
        # 头部统计行过滤
        m_kw = re.match(r'^#\s*(DOMAIN-KEYWORD|HOST-KEYWORD):\s*(\d+)', line)
        if m_kw:
            continue
        m_tot = re.match(r'^#\s*TOTAL:\s*(\d+)', line)
        if m_tot:
            total_idx = len(new_lines)
            total_val = int(m_tot.group(1))
            new_lines.append(line)
            continue
        
        # 规则行过滤：Surge/Loon/Shadowrocket/Clash/QuantumultX
        stripped = line.strip()
        if stripped.startswith(('DOMAIN-KEYWORD,', 'HOST-KEYWORD,', '- DOMAIN-KEYWORD,')):
            removed_kw += 1
            continue
        new_lines.append(line)

    if total_idx != -1 and total_val is not None:
        new_total = max(0, total_val - removed_kw)
        new_lines[total_idx] = f'# TOTAL: {new_total}'

    # Clash YAML 边界：如果 payload 规则被全部剔空，转为合法空列表 payload: []
    if ext in ('.yaml', '.yml'):
        non_comment = [l.strip() for l in new_lines if l.strip() and not l.strip().startswith('#')]
        if non_comment == ['payload:']:
            for idx, l in enumerate(new_lines):
                if l.strip() == 'payload:':
                    new_lines[idx] = 'payload: []'
                    break

    res = '\n'.join(new_lines)
    if content.endswith('\n'):
        res += '\n'
    return res.encode('utf-8'), removed_kw

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

s, d = walk(src), walk(dst)
added = changed = skipped = removed = 0
kw_rules_removed_total = 0
kw_files_affected = 0

rule_exts = {'.list', '.yaml', '.yml', '.txt', '.conf', '.snippet'}

for rel, sp in s.items():
    dp = os.path.join(dst, rel)
    raw = open(sp, 'rb').read()
    ext = os.path.splitext(rel)[1].lower()

    if ext in rule_exts:
        processed, kw_cnt = process_file_content(raw, ext)
        if kw_cnt > 0:
            kw_rules_removed_total += kw_cnt
            kw_files_affected += 1
    else:
        processed = raw

    if rel in d:
        old = open(dp, 'rb').read()
        if norm_bytes(old) == norm_bytes(processed):
            skipped += 1
            continue
        changed += 1
    else:
        added += 1

    os.makedirs(os.path.dirname(dp), exist_ok=True)
    with open(dp, 'wb') as f:
        f.write(processed)

# 目标目录中上游已删除的文件，同步删除
for rel in d:
    if rel not in s:
        os.remove(os.path.join(dst, rel))
        removed += 1

# 清理空目录
for dp, dns, fns in os.walk(dst, topdown=False):
    if not os.listdir(dp):
        os.rmdir(dp)

print(f'{added} {changed} {skipped} {removed} {len(s)} {kw_rules_removed_total} {kw_files_affected}')
PY
) || die "生成失败"

read -r ADDED CHANGED SKIPPED REMOVED TOTAL KW_REMOVED KW_FILES <<< "$STATS"
say "处理完成：共 $TOTAL 个文件"
say "  新增: $ADDED | 内容更新: $CHANGED | 未变跳过: $SKIPPED | 删除: $REMOVED"
say "  共在 $KW_FILES 个文件中剥离了 $KW_REMOVED 条 KEYWORD 规则"

# ── 可选：提交 + 推送 ─────────────────────────────────────
if [ "$COMMIT" = 1 ]; then
  if [ -z "$(git status --porcelain "$DST")" ]; then
    say "无实质变化，不提交"
  else
    SUMMARY="+$ADDED ~$CHANGED -$REMOVED (剥离 $KW_REMOVED 条 KEYWORD)"
    say "提交（${SUMMARY}）"
    git add -A "$DST"
    git commit -q -m "sync: 增量更新 $DST/ ($SUMMARY)"
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

# 供 GitHub Actions workflow 读取
echo "added=$ADDED"                 >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "changed=$CHANGED"             >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "skipped=$SKIPPED"             >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "removed=$REMOVED"             >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "kw_removed=$KW_REMOVED"       >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "kw_files=$KW_FILES"           >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
