# Harness Env Sync · 环境同步

> 换电脑不用重装。把你的 DeepSeek Harness **配置、在用插件、会话、技能、记忆库**整包搬到新机器，一条命令回来。

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](https://github.com/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](https://github.com/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.3.0-orange)](发布说明.md)

![控制台](docs/images/r78-release-window.png)

---

## 它解决什么问题

Harness 用久了，真正值钱的东西都不在安装目录里：`.credentials.yaml` 的凭证、几十个插件和它们的配置、几百个会话、
自己攒的 skills、`mnemon` 记忆库。换一台机器，靠手抄基本等于重来。

这个工具把这些**打包进一个 Git 仓库**，新机器 `restore` 一下就回到昨天的状态；日常 `backup` 一次就是快照。
不用装服务端、不用注册账号，一个仓库、两个命令。

## 三种用法，共用一个引擎

| 形态 | 适合 | 怎么开始 |
| --- | --- | --- |
| **图形控制台**（双击即用） | 不想碰命令行 | 双击 `HarnessEnvSync.exe`，点「立即备份并推送」 |
| **Harness 插件** | 在聊天里直接指挥 | 装进 Harness，说「备份一下环境」「把环境恢复过来」 |
| **命令行引擎** | 塞进计划任务 / 脚本 | `env-sync.ps1 -Mode backup` |

三者读写**同一份** `env-sync.json`：控制台里改完设置，聊天里的工具立刻生效，反之亦然。

## 快速开始

```text
1) 建一个【私有】Git 仓库（Gitee / GitHub 都行），拿到带令牌的地址
2) 下载 Release 里的 HarnessEnvSync-0.3.0.zip，解压到任意目录，双击 HarnessEnvSync.exe
3) 设置 → 填远端地址 → 保存 → 立即备份并推送
4) 换机器：装好 Harness → 解压同一个包 → 填同一个地址 → 从仓库恢复 → 重启 Harness
```

路径全部**运行期自动探测**，不需要改脚本：数据目录取 `DSH_HOME`（或程序同级 `data`），仓库取
`<数据目录>\env-sync-repo`，git 取 `tools\MinGit`（或 PATH）。探测不对时，设置里可以手动指定，
「留空」永远等于「自动」。

## 同步什么，不同步什么

| 同步 | 说明 |
| --- | --- |
| `.credentials.yaml`、`.anonymous-user-id` | 登录态与身份 |
| `profiles/desktop/*` | 当前在用插件清单与工作区配置 |
| `storages`、`.meow-smooth`、`dsh-market`、`dsh-windows-mcp.*` | 各插件自己的配置与状态 |
| `sessions` | 会话 |
| `skills` | 技能 |
| `mnemon` | 记忆库 |
| `attachments` | 附件 |

不同步：`node_modules`、`speech-to-text`、缓存、`logs`——这些新机器上重装即可（恢复后跑一次依赖安装）。

## 安全

- 备份仓库请设成**私有**：`.credentials.yaml` 会跟着进仓库。
- 带令牌的地址只落在**本机**（`env-sync.json` 与本地 git config），不进仓库内容；界面上、工具返回值里一律显示成
  `https://***@host/...`。
- 恢复前自动把将被覆盖的本地内容快照到 `<数据目录上一级>\env-restore-backup-<时间戳>`，出问题直接拷回。

## 常见问题

**git 从哪来？** 优先用 Harness 自带的 `tools\MinGit\cmd\git.exe`，没有就用 PATH 里的 `git`。都不想在设置里填绝对路径。

**恢复后插件没生效？** 恢复只搬文件，`node_modules` 不同步；在 `profiles/desktop` 下重装一次依赖再重启 Harness。

**会不会把本机路径写进发布包？** 不会。`Build-Release.ps1` 打包前会扫一遍令牌、私有仓库地址和本机绝对路径，命中直接拒绝出包。

**只想看状态不动数据？** `env-sync.ps1 -Mode status`，或者聊天里 `env_sync_status`。

## 目录结构

```text
EnvSyncConsole.ps1            图形控制台（WinForms，PowerShell 5.1 兼容）
HarnessEnvSync.exe            无控制台启动器（launcher.cs 编译，白底窗口）
启动环境同步控制台.vbs        另一条免黑窗的启动方式
engine\env-sync.ps1           引擎：status / backup / restore，独立可跑
plugin\dsh-env-sync\          Harness 插件（5 个工具 + 打开控制台）
Build-Release.ps1             打干净发布包（自动排除令牌与本机路径）
发布说明.md                   逐步骤安装说明
docs\images\                  截图
```

## English

**Harness Env Sync** keeps your DeepSeek Harness setup portable: credentials, plugins and their configs,
sessions, skills and the memory store are committed to a private Git repo, so a new machine is one
`restore` away. Windows 10/11, PowerShell 5.1+, no server, no account. Run `HarnessEnvSync.exe` for the
GUI, or drive it from chat with the bundled plugin, or call `engine\env-sync.ps1` directly.

## License

MIT — 见 [LICENSE](LICENSE)。
