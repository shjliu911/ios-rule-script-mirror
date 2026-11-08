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

# ── 6) 断言：广告表误杀豁免不得回流 ──────────────────────
# 这些是微软 / LinkedIn 的功能端点（非广告），build-no-keyword.sh 的
# EXCLUDE_DOMAINS 会从 Advertising* 规则里剔除；此断言防止上游把它们带回来。
echo "── 误杀豁免域名审查 ──"
EX_LEAKS=$(python3 - "$R" <<'PY'
import sys, os, re

ROOT = sys.argv[1]
EX = ['presence.teams.live.com', 'nexus.officeapps.live.com',
      'nexusrules.officeapps.live.com', 'crl.microsoft.com',
      'glbdns.microsoft.com', 'c.microsoft.com', 'platform.linkedin.com']

def norm(d):
    d = d.strip().strip("'").strip('"').lower()
    if d.startswith('+.'): d = d[2:]
    elif d.startswith('.'): d = d[1:]
    return d.rstrip('.')

def dom(line):
    s = line.strip()
    if not s or s.startswith(('#', '!')): return None
    if s.startswith('- '):
        s = s[2:].strip().strip("'").strip('"')
        if ',' in s:
            t, r = s.split(',', 1)
            return norm(r.split(',')[0]) if t.strip().upper() in ('DOMAIN','DOMAIN-SUFFIX','HOST','HOST-SUFFIX') else None
        return norm(s) if s else None
    if s.startswith('||'):
        m = re.match(r'^\|\|([^/^$]+)', s)
        return norm(m.group(1)) if m else None
    if ',' in s:
        p = s.split(',')
        if p[0].strip().upper() in ('DOMAIN','DOMAIN-SUFFIX','HOST','HOST-SUFFIX'):
            return norm(p[1])
    # 纯域名列表（Loon / Shadowrocket 的 *_Domain.list：每行一个域名，可能带前导点）
    if ' ' not in s and '.' in s:
        return norm(s)
    return None

leaks = []
for dp, dns, fns in os.walk(ROOT):
    # 只看广告表本身；AdvertisingExempt 是豁免表，本来就该包含这些域名
    if not re.search(r'/Advertising(?:Lite|Test|MiTV)?/', dp.replace(os.sep, '/')):
        continue
    for fn in fns:
        if not fn.endswith(('.list', '.yaml', '.yml', '.txt', '.conf', '.snippet')):
            continue
        fp = os.path.join(dp, fn)
        with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
            for idx, line in enumerate(f, 1):
                d = dom(line)
                if d and any(d == ex or d.endswith('.' + ex) for ex in EX):
                    leaks.append(f"{fp}:{idx}: {line.strip()}")
                    if len(leaks) >= 10:
                        break
    if len(leaks) >= 10:
        break

if leaks:
    print('\n'.join(leaks))
    sys.exit(1)
sys.exit(0)
PY
)
if [ $? -eq 0 ]; then
  echo "  ✓ 广告表误杀豁免已生效（微软 / LinkedIn 功能端点）"
else
  echo "  ✗ 误杀豁免域名回流到广告表："
  echo "$EX_LEAKS"
  fail=1
fi

# ── 7) 断言：静态豁免表存在且内容完整 ────────────────────
# 规则集无法携带单条策略，所以误杀豁免做成独立小表，由客户端在广告表之前引用。
echo "── 静态豁免表审查 ──"
EX_MISS=""
for f in \
  "$R/Surge/AdvertisingExempt/AdvertisingExempt-Microsoft.list" \
  "$R/Clash/AdvertisingExempt/AdvertisingExempt-Microsoft.yaml" \
  "$R/QuantumultX/AdvertisingExempt/AdvertisingExempt-Microsoft.list" \
  "$R/Surge/AdvertisingExempt/AdvertisingExempt-Global.list" \
  "$R/Clash/AdvertisingExempt/AdvertisingExempt-Global.yaml" \
  "$R/QuantumultX/AdvertisingExempt/AdvertisingExempt-Global.list"; do
  [ -f "$f" ] || EX_MISS="$EX_MISS $f"
done
for d in presence.teams.live.com nexus.officeapps.live.com nexusrules.officeapps.live.com \
         crl.microsoft.com glbdns.microsoft.com c.microsoft.com platform.linkedin.com; do
  grep -q "$d" "$R/Surge/AdvertisingExempt/AdvertisingExempt-Microsoft.list" 2>/dev/null || \
  grep -q "$d" "$R/Surge/AdvertisingExempt/AdvertisingExempt-Global.list" 2>/dev/null || \
  EX_MISS="$EX_MISS $d"
done
if [ -n "$EX_MISS" ]; then
  echo "  ✗ 静态豁免表缺失：$EX_MISS"; fail=1
else
  echo "  ✓ 静态豁免表齐全（Microsoft 6 + LinkedIn 1）"
fi

exit $fail
