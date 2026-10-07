# GitLabPipelineMonitor

A tiny macOS menu bar app that watches GitLab CI/CD pipelines and notifies you the moment a
build succeeds or fails — no more staring at the GitLab web UI after every push.

一个挂在 macOS 菜单栏的小工具：定时轮询 GitLab 各项目指定分支的最近一次流水线，状态一变就弹
系统通知（成功 ✅ / 失败 ❌ 并附带失败的 job 名），不用再开网页盯构建。

- [English](#features)
- [简体中文](#功能)

> Not affiliated with GitLab B.V. / 与 GitLab 官方无关

## Features

- Polls the latest pipeline of each configured project/branch (default every 60 s, configurable)
- Native macOS notifications on success / failure / cancel; failure alerts include the failed job names
- Color-coded menu bar icon: 🟢 all green · 🟠 dashed = building · 🔴 failed · ⚠️ token/network issue · ⏸ paused
- Click a menu row to jump straight to the pipeline (or failed job) page
- Pause / resume polling anytime; one-click manual refresh
- Hot-reloaded config — edit `config.json`, no restart needed
- Universal binary: Intel & Apple Silicon
- Optional launch-at-login

## 功能

- 按项目/分支轮询最近一次流水线（默认 60 秒一轮，可配置）
- 成功、失败、取消都会弹 macOS 系统通知；失败时直接给出失败的 job 名
- 菜单栏彩色圆点实时汇总：🟢 全部成功 / 🟠 构建中 / 🔴 有失败 / ⚠️ 异常 / ⏸ 已暂停
- 点菜单条目直达流水线或失败 job 页面
- 随时暂停/恢复轮询，一键手动刷新
- 配置热加载，改完即生效，无需重启
- 双架构通用二进制（Intel / M 系列）
- 可选开机自启

## Build / 构建

Requirements: macOS 12+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
open ~/Applications/GitLabPipelineMonitor.app
```

`build.sh` compiles a universal binary (x86_64 + arm64), bundles `AppIcon.icns` and ad-hoc
codesigns the app. The signing step matters: **macOS silently drops notifications from unsigned
apps** (no permission prompt, the app never shows up in System Settings).

构建脚本会产出双架构通用二进制并做 ad-hoc 签名。签名这步不能省：未签名的应用 macOS 会静默
忽略其通知——授权弹窗不出现、系统设置的通知列表里也找不到它。

## Configure / 配置

Create `~/.config/gitlab-pipeline-monitor/config.json`（菜单里点「打开配置文件」可自动创建）：

```json
{
  "gitlabUrl": "https://gitlab.example.com",
  "token": "<personal access token, read_api scope>",
  "intervalSeconds": 60,
  "repos": [
    { "project": "my-group/backend", "ref": "main", "alias": "Backend" },
    { "project": "1234", "ref": "release", "alias": "Legacy Service" }
  ]
}
```

| 字段 | 说明 |
| --- | --- |
| `gitlabUrl` | Your GitLab instance base URL（你的 GitLab 地址，self-hosted 或 gitlab.com 均可） |
| `token` | Personal Access Token with `read_api` scope（只需只读权限） |
| `intervalSeconds` | Polling interval, minimum 15（轮询间隔，最低 15 秒） |
| `repos[].project` | Project path (`group/project`) or numeric id（项目路径或数字 ID） |
| `repos[].ref` | Branch to watch（要监控的分支） |
| `repos[].alias` | Display name in the menu, optional（菜单显示名，可省略） |

The token is stored only in this local file (outside any git repo) and is sent exclusively to
your own GitLab instance. Keep the file's `600` permissions.

Token 只保存在本地这个配置文件里（不在任何 git 仓库中），且只发往你自己的 GitLab；
文件权限保持 600。

First launch: allow notifications when macOS asks, or use the in-menu
「静默授权 / silent authorization」 fallback.

首次启动请在弹窗里允许通知权限；如果没弹窗，用菜单里的「静默授权」。

## License

[MIT](LICENSE)
