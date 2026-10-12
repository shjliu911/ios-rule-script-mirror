#!/bin/bash
# 校验镜像出来的 rule/：根目录结构完整、文件数合理、没有截断空文件、
# Surge 的 .list 抽样格式合法。供 CI 在提交前调用；退出码非 0 则阻止提交。
#
# 设计原则：只查「上游出问题会露出来的破绽」，不做会随上游正常变化而误报的断言。
set -u
cd "$(dirname "$0")" || exit 1
fail=0
R="rule"

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

# ── 2) 总文件数下限（上游当前 ~8841；设 7000 留足余量）──────
tot=$(find "$R" -type f | wc -l | tr -d ' ')
if [ "$tot" -ge 7000 ]; then
  echo "✓ rule/ 共 $tot 个文件"
else
  echo "✗ rule/ 只有 $tot 个文件（< 7000，疑似上游异常或克隆不全）"; fail=1
fi

# ── 3) 无 0 字节文件（截断/抓取失败的典型迹象）────────────
empty=$(find "$R" -type f -size 0 | head -20)
if [ -n "$empty" ]; then
  echo "✗ 存在 0 字节文件（疑似截断）："; echo "$empty"; fail=1
else
  echo "✓ 无 0 字节文件"
fi

# ── 4) Surge .list 抽样格式（自适应两种文件）────────────────
#   a) 规则表   ：非注释行以合法规则类型开头，如 `DOMAIN-SUFFIX,xx.com`
#   b) 裸域名表 ：`*_Domain.list`，一行一个域名（配 DOMAIN-SET 用），无类型前缀
VALID='^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-SET|DOMAIN-WILDCARD|IP-CIDR|IP-CIDR6|IP6-CIDR|IP-ASN|URL-REGEX|USER-AGENT|PROCESS-NAME|PROCESS-PATH|GEOIP|RULE-SET|SRC-IP|SUBNET|DEST-PORT|PROTOCOL|AND|OR|NOT),'
DOMRE='^[A-Za-z0-9_.*-]+$'
bad=0; checked=0
while IFS= read -r f; do
  checked=$((checked+1))
  [ "$checked" -gt 300 ] && break          # 抽查 300 个即可
  body=$(grep -vE '^[[:space:]]*(#|;|!|\[|$)' "$f")
  [ -n "$body" ] || continue
  # 判断类型：看第一行是否像规则行
  if printf '%s\n' "$body" | head -1 | grep -qE "$VALID"; then
    b=$(printf '%s\n' "$body" | grep -vE "$VALID" | head -3)
  else
    b=$(printf '%s\n' "$body" | grep -vE "$DOMRE" | head -3)   # 裸域名表
  fi
  if [ -n "$b" ]; then
    echo "✗ $f 有非法行："; echo "$b"; bad=$((bad+1)); fail=1
  fi
done < <(find "$R/Surge" -name '*.list' -type f | sort)
if [ "$bad" = 0 ]; then echo "✓ Surge .list 抽样格式通过（查了 $checked 个）"; fi

# ── 5) 关键类别必须存在（你的 lll.conf 实际用到的）──────────
echo "── 关键类别 ──"
miss=""
for c in Advertising Apple Google Netflix YouTube Bahamut GlobalMedia Spotify \
         BiliBili DouYin iQIYI TencentVideo ChinaMedia Telegram PrivateTracker \
         ChinaMax Global; do
  [ -d "$R/Surge/$c" ] || miss="$miss $c"
done
if [ -n "$miss" ]; then echo "✗ 缺少类别：$miss"; fail=1; else echo "  ✓ 全部齐全"; fi

exit $fail
