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

# 上游广告表里的**误杀项**：这些是微软 / LinkedIn 的功能端点，不是广告。
# 只从 rule-no-keyword/ 剔除，rule/ 仍保持上游原样镜像；
# 客户端模板（proxy-configs）另有本地豁免，双保险。
#   presence.teams.live.com        Teams 在线状态
#   nexus(.rules).officeapps.live.com  Office 配置/实验下发
#   crl.microsoft.com              证书吊销列表
#   glbdns.microsoft.com           微软服务发现
#   c.microsoft.com                微软下载/跳转 CDN
#   platform.linkedin.com          LinkedIn 分享按钮 / 登录嵌入
EXCLUDE_DOMAINS="presence.teams.live.com,nexus.officeapps.live.com,nexusrules.officeapps.live.com,crl.microsoft.com,glbdns.microsoft.com,c.microsoft.com,platform.linkedin.com"

for a in "$@"; do case "$a" in
  --commit) COMMIT=1;;
  --no-push) :;;
  *) echo "未知参数: $a"; exit 2;;
esac; done

say() { printf '\033[36m▸\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 2; }

[ -d "$SRC" ] || die "源目录 $SRC 不存在，请先执行 sync-rules.sh"

say "开始从 $SRC 生成去 KEYWORD 规则集到 $DST/..."

STATS=$(python3 - "$SRC" "$DST" "$EXCLUDE_DOMAINS" <<'PY'
import sys, os, re, shutil

src, dst = sys.argv[1], sys.argv[2]
EXCLUDE = [x.strip().lower() for x in sys.argv[3].split(',') if x.strip()]
TS = re.compile(rb'\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}')

def norm_bytes(raw: bytes) -> bytes:
    return TS.sub(b'<TS>', raw)

def norm_dom(d: str) -> str:
    d = d.strip().strip("'").strip('"').lower()
    if d.startswith('+.'):
        d = d[2:]
    elif d.startswith('.'):
        d = d[1:]
    return d.rstrip('.')

def rule_domain(line: str):
    """取出规则行的域名值（Surge / Loon / Clash / QX / AdGuard 五种形态）。"""
    s = line.strip()
    if not s or s.startswith(('#', '!')):
        return None
    if s.startswith('- '):
        s = s[2:].strip().strip("'").strip('"')
        if ',' in s:
            typ, rest = s.split(',', 1)
            if typ.strip().upper() in ('DOMAIN', 'DOMAIN-SUFFIX', 'HOST', 'HOST-SUFFIX'):
                return norm_dom(rest.split(',')[0])
            return None
        return norm_dom(s) if s else None
    if s.startswith('||'):
        m = re.match(r'^\|\|([^/^$]+)', s)
        return norm_dom(m.group(1)) if m else None
    if ',' in s:
        p = s.split(',')
        if p[0].strip().upper() in ('DOMAIN', 'DOMAIN-SUFFIX', 'HOST', 'HOST-SUFFIX'):
            return norm_dom(p[1])
    # 纯域名列表（Loon / Shadowrocket 的 *_Domain.list：每行一个域名，可能带前导点）
    if ' ' not in s and '.' in s:
        return norm_dom(s)
    return None

def is_excluded(domain: str) -> bool:
    if not domain:
        return False
    return any(domain == ex or domain.endswith('.' + ex) for ex in EXCLUDE)

def process_file_content(raw: bytes, ext: str, rel: str) -> tuple[bytes, int, int]:
    try:
        content = raw.decode('utf-8')
    except UnicodeDecodeError:
        return raw, 0, 0

    # 误杀豁免只作用于广告类规则（Advertising / AdvertisingLite / AdvertisingTest / MiTV），
    # 避免误删 Microsoft.list 等其它类别里的同名条目；AdvertisingExempt 是豁免表本身，不处理。
    apply_ex = bool(re.search(r'/Advertising(?:Lite|Test|MiTV)?/', rel))

    # 快路径：既无 KEYWORD、也不含任何待剔除域名 → 原样返回（避免无谓改写）。
    if 'KEYWORD' not in content and not (apply_ex and any(ex in content for ex in EXCLUDE)):
        return raw, 0, 0

    lines = content.splitlines()
    new_lines = []
    removed_kw = 0
    removed_ex = 0
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
        # 误杀豁免：按域名值剔除（支持 DOMAIN / DOMAIN-SUFFIX / HOST / '+.' / '||...^'）
        if apply_ex and is_excluded(rule_domain(line)):
            removed_ex += 1
            continue
        new_lines.append(line)

    if total_idx != -1 and total_val is not None and (removed_kw or removed_ex):
        new_total = max(0, total_val - removed_kw - removed_ex)
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
    return res.encode('utf-8'), removed_kw, removed_ex

# ── 静态豁免表（不属于上游镜像，但随 rule-no-keyword 一起发布）──────────
# 规则集本身不能携带「单条规则用哪个策略」——RULE-SET 的策略对整张表生效。
# 所以误杀豁免必须做成**独立小表**，由客户端在广告表之前引用，才能指向
# 「🪟 微软服务」/「🌍 全球代理」。这两张表就是给客户端引用的。
MS_EXACT = ['presence.teams.live.com', 'nexus.officeapps.live.com', 'nexusrules.officeapps.live.com']
MS_SUFFIX = ['crl.microsoft.com', 'glbdns.microsoft.com', 'c.microsoft.com']
GL_EXACT = ['platform.linkedin.com']

def build_static():
    out = {}
    surge_ms = ('# NAME: AdvertisingExempt-Microsoft\n'
                '# NOTE: 广告表误杀豁免（微软功能端点）。必须在 Advertising 之前引用，策略=🪟 微软服务。\n'
                + ''.join(f'DOMAIN,{d}\n' for d in MS_EXACT)
                + ''.join(f'DOMAIN-SUFFIX,{d}\n' for d in MS_SUFFIX))
    surge_gl = ('# NAME: AdvertisingExempt-Global\n'
                '# NOTE: 广告表误杀豁免（LinkedIn）。必须在 Advertising 之前引用，策略=🌍 全球代理。\n'
                + ''.join(f'DOMAIN,{d}\n' for d in GL_EXACT))
    clash_ms = ('# NAME: AdvertisingExempt-Microsoft\npayload:\n'
                + ''.join(f'  - DOMAIN,{d}\n' for d in MS_EXACT)
                + ''.join(f'  - DOMAIN-SUFFIX,{d}\n' for d in MS_SUFFIX))
    clash_gl = ('# NAME: AdvertisingExempt-Global\npayload:\n'
                + ''.join(f'  - DOMAIN,{d}\n' for d in GL_EXACT))
    qx_ms = ('# NAME: AdvertisingExempt-Microsoft\n'
             + ''.join(f'host, {d}, direct\n' for d in MS_EXACT)
             + ''.join(f'host-suffix, {d}, direct\n' for d in MS_SUFFIX))
    qx_gl = ('# NAME: AdvertisingExempt-Global\n'
             + ''.join(f'host, {d}, proxy\n' for d in GL_EXACT))
    ag_ms = ('! NAME: AdvertisingExempt-Microsoft\n'
             + ''.join(f'@@||{d}^\n' for d in MS_EXACT + MS_SUFFIX))
    ag_gl = ('! NAME: AdvertisingExempt-Global\n'
             + ''.join(f'@@||{d}^\n' for d in GL_EXACT))
    for c in ('Surge', 'Loon', 'Shadowrocket'):
        out[f'{c}/AdvertisingExempt/AdvertisingExempt-Microsoft.list'] = surge_ms
        out[f'{c}/AdvertisingExempt/AdvertisingExempt-Global.list'] = surge_gl
    out['Clash/AdvertisingExempt/AdvertisingExempt-Microsoft.yaml'] = clash_ms
    out['Clash/AdvertisingExempt/AdvertisingExempt-Global.yaml'] = clash_gl
    out['QuantumultX/AdvertisingExempt/AdvertisingExempt-Microsoft.list'] = qx_ms
    out['QuantumultX/AdvertisingExempt/AdvertisingExempt-Global.list'] = qx_gl
    out['AdGuard/AdvertisingExempt/AdvertisingExempt-Microsoft.txt'] = ag_ms
    out['AdGuard/AdvertisingExempt/AdvertisingExempt-Global.txt'] = ag_gl
    return out

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

STATIC = build_static()
s, d = walk(src), walk(dst)
added = changed = skipped = removed = 0
kw_rules_removed_total = 0
kw_files_affected = 0
ex_rules_removed_total = 0
ex_files_affected = 0

rule_exts = {'.list', '.yaml', '.yml', '.txt', '.conf', '.snippet'}

for rel, sp in s.items():
    dp = os.path.join(dst, rel)
    raw = open(sp, 'rb').read()
    ext = os.path.splitext(rel)[1].lower()

    if ext in rule_exts:
        processed, kw_cnt, ex_cnt = process_file_content(raw, ext, rel)
        if kw_cnt > 0:
            kw_rules_removed_total += kw_cnt
            kw_files_affected += 1
        if ex_cnt > 0:
            ex_rules_removed_total += ex_cnt
            ex_files_affected += 1
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

# 写入静态豁免表（上游没有对应源文件，需在增量删除中豁免）
for rel, text in STATIC.items():
    dp = os.path.join(dst, rel)
    data = text.encode('utf-8')
    if rel in d:
        if norm_bytes(open(dp, 'rb').read()) == norm_bytes(data):
            skipped += 1
            continue
        changed += 1
    else:
        added += 1
    os.makedirs(os.path.dirname(dp), exist_ok=True)
    with open(dp, 'wb') as f:
        f.write(data)

# 目标目录中上游已删除的文件，同步删除（静态豁免表除外）
for rel in d:
    if rel not in s and rel not in STATIC:
        os.remove(os.path.join(dst, rel))
        removed += 1

# 清理空目录
for dp, dns, fns in os.walk(dst, topdown=False):
    if not os.listdir(dp):
        os.rmdir(dp)

print(f'{added} {changed} {skipped} {removed} {len(s)} {kw_rules_removed_total} {kw_files_affected} {ex_rules_removed_total} {ex_files_affected}')
PY
) || die "生成失败"

read -r ADDED CHANGED SKIPPED REMOVED TOTAL KW_REMOVED KW_FILES EX_REMOVED EX_FILES <<< "$STATS"
say "处理完成：共 $TOTAL 个文件"
say "  新增: $ADDED | 内容更新: $CHANGED | 未变跳过: $SKIPPED | 删除: $REMOVED"
say "  共在 $KW_FILES 个文件中剥离了 $KW_REMOVED 条 KEYWORD 规则"
say "  共在 $EX_FILES 个文件中剔除了 $EX_REMOVED 条误杀豁免域名"

# ── 可选：提交 + 推送 ─────────────────────────────────────
if [ "$COMMIT" = 1 ]; then
  if [ -z "$(git status --porcelain "$DST")" ]; then
    say "无实质变化，不提交"
  else
    SUMMARY="+$ADDED ~$CHANGED -$REMOVED (剥离 $KW_REMOVED 条 KEYWORD，剔除 $EX_REMOVED 条误杀域)"
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
echo "ex_removed=$EX_REMOVED"       >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
echo "ex_files=$EX_FILES"           >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
