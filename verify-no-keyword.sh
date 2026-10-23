#!/bin/bash
# 校验 rule-no-keyword/：确保所有客户端目录齐全、文件数完整、无 0 字节截断，
# 最重要的是断言「零 KEYWORD 规则残留」。
# 供 CI 在提交前调用；退出码非 0 则阻止提交。
set -u
cd "$(dirname "$0")" || exit 1
fail=0
R="rule-no-keyword"

[ -d "$R" ] || { echo "✗ 目录 $R 不存在"; exit 1; }

# ── 1) 六个客户端目录齐全 ────────────────────────────────
echo "── 客户端目录 ──"
for c in Clash Surge QuantumultX Loon Shadowrocket AdGuard; do
  if [ -d "$R/$c" ]; then
    n=$(find "$R/$c" -type f | wc -l | tr -d ' ')
    printf '  ✓ %-14s %5s 个文件\n' "$c" "$n"
  else
    printf '  ✗ %-14s 缺失\n' "$c"; fail=1
  fi
done

# ── 2) 总文件数下限 ──────────────────────────────────────
tot=$(find "$R" -type f | wc -l | tr -d ' ')
if [ "$tot" -ge 7000 ]; then
  echo "✓ $R 共 $tot 个文件"
else
  echo "✗ $R 只有 $tot 个文件（< 7000，疑似生成不全）"; fail=1
fi

# ── 3) 无 0 字节文件 ────────────────────────────────────
empty=$(find "$R" -type f -size 0 | head -20)
if [ -n "$empty" ]; then
  echo "✗ 存在 0 字节文件（疑似截断）："; echo "$empty"; fail=1
else
  echo "✓ 无 0 字节文件"
fi

# ── 4) 核心断言：必须 100% 无 KEYWORD 规则 ───────────────
echo "── KEYWORD 零残留审查 ──"
kw_leaks=$(python3 - "$R" <<'PY'
import sys, os

root = sys.argv[1]
leaks = []
for dp, dns, fns in os.walk(root):
    for fn in fns:
        if fn.endswith(('.list', '.yaml', '.yml', '.txt', '.conf', '.snippet')):
            fp = os.path.join(dp, fn)
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                for idx, line in enumerate(f, 1):
                    s = line.strip()
                    if s.startswith(('DOMAIN-KEYWORD,', 'HOST-KEYWORD,', '- DOMAIN-KEYWORD,')):
                        leaks.append(f"{fp}:{idx}: {s}")
                        if len(leaks) >= 10:
                            break
    if len(leaks) >= 10:
        break

if leaks:
    for l in leaks:
        print(l)
    sys.exit(1)
sys.exit(0)
PY
)
if [ $? -eq 0 ]; then
  echo "  ✓ 完美：所有规则集已完全去 KEYWORD 化（0 条残留）"
else
  echo "  ✗ 发现 KEYWORD 残留规则："
  echo "$kw_leaks"
  fail=1
fi

# ── 5) 关键类别必须存在 ──────────────────────────────────
echo "── 关键类别 ──"
miss=""
for c in Advertising Apple Google Netflix YouTube Bahamut GlobalMedia Spotify \
         BiliBili DouYin iQIYI TencentVideo ChinaMedia Telegram PrivateTracker \
         ChinaMax Global; do
  [ -d "$R/Surge/$c" ] || miss="$miss $c"
done
if [ -n "$miss" ]; then echo "✗ 缺少类别：$miss"; fail=1; else echo "  ✓ 全部齐全"; fi

exit $fail
