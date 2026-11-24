# 配置说明

## 1. 生成 GPG 签名密钥

在任意有 GPG 的机器上（一次性，离线保存好）：

```bash
gpg --quick-generate-key "DDE Repository Signing Key <you@example.com>" rsa3072 sign never
gpg --list-secret-keys --keyid-format LONG
# 导出私钥（ASCII armor），填进 GitHub Secret
gpg --armor --export-secret-keys <KEY_ID> > private.key
```

## 2. 配置 GitHub Secrets

仓库 Settings → Secrets and variables → Actions：

| Secret | 值 |
|---|---|
| `GPG_PRIVATE_KEY` | 上一步 `private.key` 全文 |
| `SIGNING_KEY_ID` | KEY_ID（可选，用于导出公钥） |

`GITHUB_TOKEN` 由 Actions 自动提供，用来拉私有/限流仓库。

## 3. 启用 GitHub Pages

Settings → Pages → Build and deployment：
- Source 选 **GitHub Actions**
- workflow 里的 `configure-pages` / `deploy-pages` 会处理部署

## 4. 触发构建

- 手动：Actions 页 → **Build DDE for Debian** → Run workflow
- 自动：push 到 main 且改动了 `config/packages.json` / `scripts/`；每天 18:00 UTC 定时重建

## 5. 逐个打开包

编辑 `config/packages.json`，把目标包的 `enabled` 改为 `true`。
建议顺序：

1. 先只留 `dtkcommon`（L1）跑通完整链路 → Pages 上能 `apt update`
2. 打开 L0 四个包，确认补丁版 qt6-wayland 能编过
3. 打开 L1 剩余 DTK 包
4. 打开 L2 / L3

每开一层，看 Actions 里该层 job 的日志，`build-layer.yml` 会把上一层的 deb
下载到 `upstream-debs/` 并注册成本地 apt 源。

## 6. 客户端安装

```bash
curl -fsSL https://tensortensor666.github.io/dde-debian-repo/install.sh | sudo bash
sudo apt install deepin-desktop-environment-base \
                 deepin-desktop-environment-core \
                 deepin-desktop-environment-extras
```

虚拟机里先测，参考社区先例（Debian 13 + DDE25）的已知风险：
Wayland/Treeland 可能黑屏、圆角异常、托盘异常。

## 7. 保留历史版本（重要）

当前 `publish-repo.sh` 每次从空目录建仓库，旧版本不会保留。
要做增量仓库，在 publish job 里加一步，构建前把线上仓库拉回来：

```yaml
- name: Import existing repo
  run: |
    git clone --depth 1 --branch gh-pages "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY.git" prev-repo || true
    cp -a prev-repo/. repo-out/ 2>/dev/null || true
```

或者用 `morph027/apt-repo-action@v3` 的 `import-from-repo-url` 输入。
Actions 缓存不可变，别指望用 cache 存 reprepro 数据库。
