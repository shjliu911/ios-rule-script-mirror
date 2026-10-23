# ios-rule-script-mirror

[`blackmatrix7/ios_rule_script`](https://github.com/blackmatrix7/ios_rule_script) 的 **`rule/` 目录镜像** 与 **去 KEYWORD 化规则集**。

## 目录结构

```
rule/             ← 上游原始镜像（每天同步两次）
rule-no-keyword/  ← 去 KEYWORD 纯净规则集（每 7 天增量更新一次，专为 Surge / Loon 优化）
```

---

## 为什么需要 `rule-no-keyword/`（去 KEYWORD 规则集）

Surge、Loon 等现代代理客户端底层针对 `DOMAIN` 和 `DOMAIN-SUFFIX` 采用了 **Trie 树（字典树）** 高度优化索引，纳秒级命中且极省 CPU 和电量。

但原版上游规则中混入了大量的 `DOMAIN-KEYWORD` / `HOST-KEYWORD`：
1. **性能断崖**：系统无法为 Keyword 建立树状索引，每次发起连接都必须全文子串线性遍历，导致网络请求延迟上升、发热耗电；
2. **广谱误杀**：Keyword 无层级边界，如 `apple` 误伤 `pineapple.com`，`steam` 误伤 `upstream.org`。

**`rule-no-keyword/` 的优势**：
* 剔除了全部 `DOMAIN-KEYWORD` 与 `HOST-KEYWORD`，保留纯粹的高效域名与 IP 规则；
* 路径与 `rule/` **完全 1:1 对称**，只需将 URL 中的 `rule/` 换成 `rule-no-keyword/` 即可平滑无缝替换；
* 同样采用 **时间戳掩码增量更新**，内容未变的文件在 git 历史中零冗余。

---

## 用法（以 Surge / Loon 为例）

把 `lll.conf`（或 Loon 配置）里的规则集 URL 直接切换为无 Keyword 版本：

```ini
# 原镜像版本（包含 KEYWORD）
RULE-SET,https://raw.githubusercontent.com/shjliu911/ios-rule-script-mirror/main/rule/Surge/Advertising/Advertising_All.list,"💀 去广告"

# 推荐：无 KEYWORD 纯净高速版（只需把 rule/ 改为 rule-no-keyword/）
RULE-SET,https://raw.githubusercontent.com/shjliu911/ios-rule-script-mirror/main/rule-no-keyword/Surge/Advertising/Advertising_All.list,"💀 去广告"
```

---

## 自动化同步与更新机制

全部由 GitHub Actions 自动化调度执行：

1. **上游同步 (`.github/workflows/sync.yml`)**：
   * 每天跑两次（北京 06:37 / 18:37），稀疏同步上游 `rule/`，时间戳掩码比对，只存真增量。
2. **去 Keyword 生成 (`.github/workflows/no-keyword.yml`)**：
   * **每 7 天** 定期执行一次（每周日北京 11:37 / UTC 03:37），全量去 KEYWORD 化并增量更新到 `rule-no-keyword/`。
   * 支持 GitHub Actions 页面手动随时触发 (`workflow_dispatch`)。

手动在本机运行：

```bash
# 同步上游原始 rule/
./sync-rules.sh
./sync-rules.sh --commit

# 生成无 KEYWORD 规则集 rule-no-keyword/
./build-no-keyword.sh
./build-no-keyword.sh --commit

# 校验产物
./verify-rules.sh
./verify-no-keyword.sh
```

---

## 许可

上游为 **GPL-2.0**，本镜像原样再分发，许可与出处见 [`LICENSE`](LICENSE)、[`NOTICE.md`](NOTICE.md)。
规则内容的著作权归上游作者 [blackmatrix7](https://github.com/blackmatrix7) 所有。
