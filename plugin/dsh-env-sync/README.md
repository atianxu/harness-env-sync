# dsh-env-sync · Harness 环境同步插件

把 DeepSeek Harness 的**配置 + 当前在用插件及其配置 + 会话 + 技能 + 记忆库**打包到一个 Git 仓库，
换机器拉下来一键恢复。装好之后在 Harness 里直接说“备份一下环境”“把环境恢复过来”就能用，也可以打开图形控制台点按钮。

## 同步什么

| 类别 | 具体路径（相对数据目录） |
| --- | --- |
| 配置与凭证 | `.credentials.yaml`、`.anonymous-user-id`、`profiles/desktop/*`（cordis、package.json、lock、npmrc 等） |
| 当前在用插件及其配置 | `.meow-smooth`、`dsh-market`、`dsh-windows-mcp.*.json`、`storages/`、插件清单 `profiles/desktop/cordis.patch.yml` |
| 会话 | `sessions/` |
| 技能 | `skills/` |
| 记忆库 | `mnemon/`（mnemon.db 与身份文件） |
| 附件与市场状态 | `attachments/`、`dsh-market/` |

默认**不同步**可重建的大体积目录：`node_modules`、语音模型（`speech-to-text`）、浏览器/工具产物（`dsh-ops`、
`dsh-windows-mcp` 的缓存）、`logs`、`cache`。这些换机器重装即可，避免仓库被几百 MB 的二进制塞满。

## 路径不写死

所有路径运行期自动探测，也能手动指定：

| 项 | 自动探测顺序 | 手动指定 |
| --- | --- | --- |
| 数据目录 | 配置 `dataRoot` → 环境变量 `DSH_HOME` → 程序同级 `data` | `env_sync_configure` 的 `data_root` |
| 同步仓库 | 配置 `repoDir` → `<数据目录>\env-sync-repo` | `env_sync_configure` 的 `repo_dir` |
| git.exe | 配置 `git` → `tools\MinGit\cmd\git.exe` → PATH | `env_sync_configure` 的 `git_exe` |
| 仓库地址 | 配置 `repoUrl`（可为空） | `env_sync_configure` 的 `repo_url` |
| 分支 | 配置 `branch`，默认 `env-sync` | `env_sync_configure` 的 `branch` |

## 配置只有一份

插件按这个顺序找配置：环境变量 `DSH_ENV_SYNC_CONFIG` → 上级共享 `<插件目录>\..\..\env-sync.json`
（即插件放在 `<env-sync>\plugin\dsh-env-sync` 时用 GUI 同一份配置）→ 插件目录自己的 `env-sync.json`。
所以控制台里改完，聊天里调工具读到的就是同一份，不会各说各话。
配置里 `repoUrl` 留空时，展示的远端会回读仓库自己的 `origin`，并做脱敏。

## 安装

1. 把本目录放进 `<数据目录>\profiles\desktop\node_modules\dsh-env-sync`（或做软链接指向它）。
2. 在 `profiles/desktop/cordis.patch.yml` 的 bundles 列表末尾追加 `dsh-env-sync`。
3. 重启 Harness。

## 工具

| 工具 | 作用 |
| --- | --- |
| `env_sync_status` | 查看数据目录、仓库、分支、工作区改动、最近提交，以及当前生效配置（地址已脱敏） |
| `env_sync_backup` | 复制清单内容 → commit → push |
| `env_sync_restore` | 先把本地将被覆盖的内容快照一份，再 pull 并写回 |
| `env_sync_configure` | 配置仓库地址/分支/数据目录/仓库目录/git 路径；传空字符串表示恢复自动探测 |
| `env_sync_open_console` | 打开图形控制台（白色界面，备份/恢复/设置按钮） |

## 首次配置仓库

```
env_sync_configure(repo_url="https://gitee.com/<你的账号>/<仓库>.git")
env_sync_backup()
```

带令牌的地址（`https://oauth2:<令牌>@gitee.com/...`）只保存在本机 `env-sync.json` 与本地 git 配置里，
不会进入同步内容；仓库里也不存在令牌。展示时一律脱敏成 `https://***@...`。

## 换机器恢复

1. 新机器装好 Harness，设置 `DSH_HOME` 指向数据目录（或直接使用默认）。
2. 安装本插件，配置同一个仓库地址。
3. 调用 `env_sync_restore`：先 pull，再把清单内容写回数据目录；覆盖前的本地版本会留在
   `<数据目录上级>\env-restore-backup-<时间戳>`。
4. 重启 Harness，重新安装依赖（`profiles/desktop` 下 `pnpm install`）以重建 `node_modules`。

## 注意

- 恢复是覆盖式写入，务必确认仓库里是你要的那一版；`env_sync_restore` 的快照只覆盖本次会写回的条目。
- `.credentials.yaml` 会进入仓库：**仓库必须是私有的**，公开发布版不要带自己的仓库地址和令牌。
- 引擎是独立 PowerShell 脚本（`engine/env-sync.ps1`），不依赖本插件也能单独跑：
  `powershell -NoProfile -ExecutionPolicy Bypass -File engine\env-sync.ps1 -Mode status`。
