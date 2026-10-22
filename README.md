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
| `repos[].jobs` | Optional whitelist of job names (exact match). When set, only these jobs decide the status — useful when a repo has unrelated jobs (e.g. a mobile test) that fail without affecting your deploy（可选：只看这些 job，**精确名字匹配**） |

### Watching a single job / 只关心某个 job

Many pipelines run several jobs; a failing unrelated job (mobile build, optional scan) turns the
whole pipeline red even though `build-job` passed. Add `jobs` to watch only what matters:

```json
{ "project": "my-group/backend", "ref": "main", "alias": "Backend", "jobs": ["build-job"] }
```

Matching is **exact** — `build-job` will not match `build-job-mobile-test`. The repo is green only
when every whitelisted job ends `success` (or `skipped`); `manual` jobs show as "waiting for manual
action" rather than success. Extra jobs are ignored entirely.

流水线里常有多个 job，一个无关 job（移动端构建、可选的扫描）失败会让整条流水线变红，哪怕
`build-job` 已经成功。加 `jobs` 字段只盯你关心的：**精确匹配**（`build-job` 不会命中
`build-job-mobile-test`），白名单里的 job 全部 `success`/`skipped` 才算绿，`manual` 单独显示
"待手动"，其余 job 完全忽略。

### Menu details / 菜单信息

Each row shows status, branch, **finish time** (relative within 24 h, absolute after), the trigger
source (push / manual / schedule / API) and **who triggered it**; running pipelines show elapsed
time instead. The refresh timestamp sits in the menu header. Trigger user is fetched once per
pipeline and cached, so polling cost stays at one request per repo per interval.

每行显示状态、分支、**完成时间**（24 小时内相对、更早显示绝对时间）、触发方式（推送/手动/定时/API）
与**触发人**；进行中的流水线显示"已跑多久"。刷新时间放在菜单标题。触发人每个流水线只查一次并
缓存，轮询开销仍为每仓库每轮一个请求。

The token is stored only in this local file (outside any git repo) and is sent exclusively to
your own GitLab instance. Keep the file's `600` permissions.

Token 只保存在本地这个配置文件里（不在任何 git 仓库中），且只发往你自己的 GitLab；
文件权限保持 600。

First launch: allow notifications when macOS asks, or use the in-menu
「静默授权 / silent authorization」 fallback.

首次启动请在弹窗里允许通知权限；如果没弹窗，用菜单里的「静默授权」。

## License

[MIT](LICENSE)
