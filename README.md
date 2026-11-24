# DDE for Debian — GitHub Actions 构建骨架

把 Deepin Desktop Environment (DDE25) 编译成 Debian 包，通过自建 APT 仓库发行。
目标基线：Debian 13 (trixie) / x86_64。

## 状态

**骨架阶段**：CI 链路已定义，默认只启用了一个 smoke test 包（`dtkcommon`），
用来验证"拉源码 → trixie 容器打包 → 生成仓库 → 部署 Pages"整条链路。
L0/L2/L3 的包都还在清单里但 `enabled: false`，跑通后再逐个打开。

## 目录结构

```
.github/workflows/
  build.yml          # 主入口：prepare → L0 → L1 → L2 → L3 → publish
  build-layer.yml    # 可复用：单层内按 matrix 并行打包
scripts/
  gen_matrix.py      # 从 packages.json 生成各层 matrix + 计数
  fetch-source.sh    # 拉上游源码 (git clone / apt source)
  setup-local-repo.sh# 把上一层 .deb 做成 apt 源供本层用
  verify-debs.sh     # 打包后校验元数据
  publish-repo.sh    # reprepro 建仓库 + 导出公钥
config/
  packages.json      # 包清单，控制每层构建哪些包
apt-repo/conf/       # reprepro 配置
install.sh           # 客户端一键加源
```

## 为什么分四层

DDE 的私有依赖不在 Debian 官方源里，必须先编译出来才能编译上层。
每层产物通过 GitHub Actions artifact 传给下一层，作为本地 apt 源：

- **L0 私有依赖**：补丁版 qt6-wayland、treeland-protocols、waylib、qwlroots ← 最难，先啃这层
- **L1 DTK6**：dtkcommon / dtkcore / dtkgui / dtkwidget / dtkdeclarative
- **L2 会话层**：ddm、treeland、application-manager、tray-loader、dde-daemon
- **L3 桌面组件**：dde-shell、control-center、file-manager、launchpad、session-shell

## 快速开始

1. 按 [`docs/SETUP.md`](docs/SETUP.md) 配好 GPG 签名密钥和 Secrets
2. Fork / push 到 `main`，或手动触发 workflow_dispatch
3. 看 Actions 日志；smoke test 通过后，在 `config/packages.json` 里把 L0 的包设为 `enabled: true`

## 局限 / 待办

- GitHub Actions 的缓存不可变，reprepro 数据库不能跨 run 持久化 → 当前每次发布是全新仓库。
  见 `docs/SETUP.md` 的 `import-from-repo-url` 方案。
- 上游版本跑得快，固定 `ref` 才能可复现；目前清单里用分支名，稳定后改 tag/commit。
- 只构建 binary 包（`-b`）；source 包发布尚未接入。
- `/etc/os-version` 伪装等系统集成留给客户端安装后的收尾，不在本骨架内。
