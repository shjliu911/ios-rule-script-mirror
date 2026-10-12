# ios-rule-script-mirror

[`blackmatrix7/ios_rule_script`](https://github.com/blackmatrix7/ios_rule_script) 的 **`rule/` 目录镜像**。

## 为什么有这个仓库

两个原因，都是上游的客观性质决定的：

1. **上游太大。** 上游共 4.3 GB / 11226 文件（含 1990 个 icon、script、rewrite、5 个客户端各一套规则）。
   这里只镜像 `rule/`（485 MB / 8841 文件），够 Surge / Clash / QuantumultX / Loon /
   Shadowrocket / AdGuard 使用。
2. **上游每个文件都有每次必变的时间戳。** 上游约每 2 天全量重生成，
   每个文件头部的 `# UPDATED: YYYY-MM-DD HH:MM:SS` 都会更新 —— 即使规则内容一个字没改。
   逐个文件原样镜像的话，每次同步等于重写全部 485 MB，git 仓库几个月就涨到 GB 级。
   本仓库的同步脚本**把时间戳掩码后再比较内容**：只有规则真的变了才覆盖文件。
   实测每次上游刷新约 3.5%（~55/1557 个 Surge 文件）真的变化，其余 96.5% 原样跳过。

## 怎么同步的

`.github/workflows/sync.yml` 每天跑两次（北京 06:37 / 18:37），跑在 GitHub 服务器上，与本机无关：

```
稀疏克隆上游 rule/（blob:none，跳过 3.8 GB 的 icon/script）
  → 掩码时间戳后逐文件比对，只覆盖真变了的
  → verify-rules.sh 校验（目录齐全 / 无 0 字节 / .list 抽样格式 / 关键类别）
  → 有变化才提交推送
```

手动立刻同步：

```bash
gh workflow run sync.yml --repo shjliu911/ios-rule-script-mirror
```

或在本机：

```bash
./sync-rules.sh            # 同步 + 统计，不提交
./sync-rules.sh --commit   # 同步 + 提交 + 推送
```

## 用法

把 `lll.conf`（或任何 Surge 配置）里的上游 URL 换成本仓库：

```
# 上游
RULE-SET,https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Surge/Advertising/Advertising_All.list,"💀 去广告"

# 本镜像
RULE-SET,https://raw.githubusercontent.com/shjliu911/ios-rule-script-mirror/main/rule/Surge/Advertising/Advertising_All.list,"💀 去广告"
```

路径 `rule/Surge/<类别>/<文件>` 与上游**完全一致**，只需替换 `github.com/<owner>/<repo>` 这一段。

## 许可

上游为 **GPL-2.0**，本镜像原样再分发，许可与出处见 [`LICENSE`](LICENSE)、[`NOTICE.md`](NOTICE.md)。
规则内容的著作权归上游作者 [blackmatrix7](https://github.com/blackmatrix7) 所有。
