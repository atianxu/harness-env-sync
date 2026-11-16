/**
 * dsh-env-sync — Harness 环境同步（插件版）
 *
 * 把“配置 + 当前在用插件及其配置 + 会话 + 技能 + 记忆库”打包进一个 Git 仓库，换机器一键恢复。
 * 真正干活的是 engine/env-sync.ps1（backup / restore / status），本文件只把引擎接成 Harness 工具，
 * 并在需要时拉起图形控制台。
 *
 * 发布约束：
 *  - 不带任何本机绝对路径：数据目录、仓库目录、git 全部运行期自动探测，或由 env_sync_configure 写入。
 *  - 仓库地址可为空（只做本地备份仓）；含令牌的地址只存本机，不进同步内容，展示一律脱敏。
 *  - 配置写在插件目录下的 env-sync.json，模板里没有任何地址与令牌。
 */
import { execFile, execFileSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-env-sync'
// 先声明注入，才能在 apply 里安全读取 ctx.tools。
export const inject = ['tools']

const pluginDir = dirname(fileURLToPath(import.meta.url))
const enginePath = process.env.DSH_ENV_SYNC_ENGINE || join(pluginDir, 'engine', 'env-sync.ps1')

/**
 * 配置的落点只有一个：优先环境变量 DSH_ENV_SYNC_CONFIG；
 * 否则如果插件就放在 <env-sync>\plugin\dsh-env-sync 里，用上两级的共享 env-sync.json，
 * 这样 GUI 和插件改的是同一份配置，不会各说各话；都没有才退回插件目录里的那份。
 */
const sharedConfigPath = join(pluginDir, '..', '..', 'env-sync.json')
function configPath() {
  if (process.env.DSH_ENV_SYNC_CONFIG) { return process.env.DSH_ENV_SYNC_CONFIG }
  if (existsSync(sharedConfigPath)) { return sharedConfigPath }
  return join(pluginDir, 'env-sync.json')
}

/** 统一的输出契约：所有工具只回一段人可读的文本结果。 */
function textOutput() {
  return {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: { result: { type: 'string' } },
    },
    render: (_args, value) => [{ type: 'text', text: String(value && value.result) }],
  }
}

function powershellPath() {
  const systemRoot = process.env.SystemRoot || process.env.windir || 'C:\\Windows'
  const full = join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  return existsSync(full) ? full : 'powershell.exe'
}

function readConfig() {
  const path = configPath()
  if (!existsSync(path)) { return {} }
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    throw new Error(`env-sync.json 解析失败：${error.message}`)
  }
}

/**
 * 跑一次引擎。路径参数只在配置里显式写了才传，其余交给引擎自动探测，
 * 这样同一份代码换机器后不用改任何东西。
 */
function runEngine(mode, timeoutMs) {
  const cfg = readConfig()
  const path = configPath()
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', enginePath, '-Mode', mode, '-ConfigPath', path]
  if (cfg.dataRoot) { args.push('-DataRoot', cfg.dataRoot) }
  if (cfg.repoDir) { args.push('-RepoDir', cfg.repoDir) }
  if (cfg.branch) { args.push('-Branch', cfg.branch) }
  if (cfg.git) { args.push('-GitExe', cfg.git) }
  if (cfg.repoUrl) { args.push('-RepoUrl', cfg.repoUrl) }

  return new Promise((resolve, reject) => {
    execFile(powershellPath(), args, {
      timeout: timeoutMs,
      windowsHide: true,
      maxBuffer: 16 * 1024 * 1024,
      env: process.env,
    }, (error, stdout, stderr) => {
      if (error) {
        const detail = (stdout || '').trim()
        reject(new Error(`环境同步引擎执行失败（${mode}）：${(stderr || error.message).trim()}${detail ? `\n${detail}` : ''}`))
        return
      }
      resolve((stdout || '').trim())
    })
  })
}

/** 脱敏：只保留协议 + 主机 + 路径。 */
function maskRemote(url) {
  if (!url) { return '' }
  return url
    .replace(/oauth2:[^@\s]+@/g, 'oauth2:***@')
    .replace(/(https?:\/\/)[^/@\s:]+:[^/@\s]+@/g, '$1***@')
}

function describeConfig() {
  const cfg = readConfig()
  const repoDir = cfg.repoDir || (cfg.dataRoot || process.env.DSH_HOME
    ? join(cfg.dataRoot || process.env.DSH_HOME, 'env-sync-repo')
    : '')
  let remote = maskRemote(cfg.repoUrl)
  if (!remote && repoDir && existsSync(repoDir)) {
    // 配置里没写地址时，回读仓库自己的 origin，免得界面说“未配置”其实一直在推。
    try {
      remote = maskRemote(execFileSync(cfg.git || 'git', ['-C', repoDir, 'remote', 'get-url', 'origin'],
        { encoding: 'utf8', windowsHide: true, timeout: 8000 }).trim()) || ''
    } catch {}
  }
  return [
    `配置文件 : ${configPath()}`,
    `引擎     : ${enginePath}`,
    `数据目录 : ${cfg.dataRoot || '(自动探测)'}`,
    `同步仓库 : ${cfg.repoDir || (repoDir || '(自动探测)')}`,
    `分支     : ${cfg.branch || 'env-sync'}`,
    `远端     : ${remote || '(未配置，仅本地备份仓)'}`,
    `git      : ${cfg.git || '(自动探测)'}`,
    `同步条目 : ${Array.isArray(cfg.include) ? cfg.include.length : 0} 项`,
  ].join('\n')
}

/** 启动自检：把加载结果记一行到 <数据目录>\logs\dsh-env-sync.log；任何异常都吞掉。 */
function logBoot(line) {
  try {
    const home = process.env.DSH_HOME
    if (!home) { return }
    const dir = join(home, 'logs')
    mkdirSync(dir, { recursive: true })
    appendFileSync(join(dir, 'dsh-env-sync.log'), `[${new Date().toISOString()}] ${line}\n`, 'utf8')
  } catch {}
}

/** @param {import('@deepseek-ai/cordis').Context} ctx */
export function apply(ctx) {
  const tools = [
    {
      name: 'env_sync_status',
      description:
        '查看 Harness 环境同步状态：数据目录、同步仓库、分支、工作区改动和最近一次提交，同时返回当前生效配置（仓库地址已脱敏）。' +
        '路径默认自动探测，不需要填任何本机路径。',
      parameters: {},
      output: textOutput(),
      execute: async () => {
        const output = await runEngine('status', 60000)
        return { result: `${describeConfig()}\n\n--- git status ---\n${output}` }
      },
    },
    {
      name: 'env_sync_backup',
      description:
        '把当前 Harness 环境备份到配置的 Git 仓库：配置文件、当前在用插件及其配置清单、会话、技能、记忆库等一起复制进仓库，' +
        '然后 commit 并 push。可重建的大体积目录（node_modules、语音模型、工具缓存）默认排除。',
      parameters: {},
      output: textOutput(),
      execute: async () => {
        const output = await runEngine('backup', 180000)
        return { result: output || '备份完成（引擎无输出）' }
      },
    },
    {
      name: 'env_sync_restore',
      description:
        '从配置的 Git 仓库拉取环境并写回本机数据目录，用于换机器或重置后重建环境。覆盖前会先把本地将被覆盖的内容快照一份，出问题可以手工回退。' +
        '恢复完成后需要重启 Harness 并重新安装依赖。',
      parameters: {},
      output: textOutput(),
      execute: async () => {
        const output = await runEngine('restore', 180000)
        return { result: `${output}\n\n恢复后请重启 Harness，并在 profiles/desktop 下重新安装依赖以重建 node_modules。` }
      },
    },
    {
      name: 'env_sync_configure',
      description:
        '配置环境同步：仓库地址（可为空字符串，表示只做本地备份仓）、分支、数据目录、同步仓库目录、git.exe 路径。' +
        '传空字符串表示恢复为自动探测。保存后会把仓库地址写到本地仓库的 origin。',
      parameters: {
        repo_url: { type: 'string', description: 'Git 仓库地址，例如 https://gitee.com/<用户>/<仓库>.git；留空表示不配远端。' },
        branch: { type: 'string', description: '同步分支名，默认 env-sync。' },
        data_root: { type: 'string', description: 'Harness 数据目录；留空自动探测（DSH_HOME 或程序同级 data）。' },
        repo_dir: { type: 'string', description: '本地同步仓库目录；留空为数据目录下的 env-sync-repo。' },
        git_exe: { type: 'string', description: 'git.exe 路径；留空自动探测（tools\\MinGit 或 PATH）。' },
      },
      output: textOutput(),
      execute: async (args) => {
        const cfg = readConfig()
        const next = Object.assign({}, cfg)
        if (typeof args.repo_url === 'string') { next.repoUrl = args.repo_url.trim() }
        if (typeof args.branch === 'string' && args.branch.trim()) { next.branch = args.branch.trim() }
        if (typeof args.data_root === 'string') { next.dataRoot = args.data_root.trim() }
        if (typeof args.repo_dir === 'string') { next.repoDir = args.repo_dir.trim() }
        if (typeof args.git_exe === 'string') { next.git = args.git_exe.trim() }
        writeFileSync(configPath(), JSON.stringify(next, null, 2), 'utf8')

        let remoteResult = '远端未改动'
        const repo = next.repoDir || (next.dataRoot ? join(next.dataRoot, 'env-sync-repo') : '')
        if (typeof args.repo_url === 'string' && repo && existsSync(join(repo, '.git'))) {
          const gitExe = next.git || 'git'
          remoteResult = await new Promise((resolve) => {
            execFile(gitExe, ['-C', repo, 'remote', 'set-url', 'origin', next.repoUrl || ''], { windowsHide: true },
              (error) => {
                if (!error) { resolve('已更新 origin'); return }
                execFile(gitExe, ['-C', repo, 'remote', 'add', 'origin', next.repoUrl || ''], { windowsHide: true },
                  (error2) => resolve(error2 ? `远端更新失败：${error2.message}` : '已新增 origin'))
              })
          })
        }
        return { result: `已保存。${remoteResult}\n\n${describeConfig()}` }
      },
    },
    {
      name: 'env_sync_open_console',
      description:
        '打开 Harness 环境同步的图形控制台（白色界面，含备份/恢复/设置按钮）。' +
        '没装控制台的机器会说明改用 env_sync_backup / env_sync_restore。',
      parameters: {},
      output: textOutput(),
      execute: async () => {
        const candidates = [
          process.env.DSH_ENV_SYNC_GUI || '',
          join(pluginDir, 'HarnessEnvSync.exe'),
          join(pluginDir, 'EnvSyncConsole.ps1'),
        ].filter(Boolean)
        const found = candidates.find((p) => existsSync(p))
        if (!found) {
          return { result: '当前环境没有安装图形控制台，可直接使用 env_sync_status / env_sync_backup / env_sync_restore。' }
        }
        const exe = found.toLowerCase().endsWith('.exe')
        const file = exe ? found : powershellPath()
        const argv = exe ? [] : ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', found]
        await new Promise((resolve, reject) => {
          execFile(file, argv, { windowsHide: true, detached: true }, (error) => (error ? reject(error) : resolve()))
        })
        return { result: `已启动图形控制台：${found}` }
      },
    },
  ]

  logBoot('apply entered')
  try {
    for (const tool of tools) {
      ctx.tools.register(tool)
    }
  } catch (error) {
    logBoot(`APPLY-ERROR ${(error && error.stack) || error}`)
    throw error
  }

  logBoot(`plugin loaded; engine=${enginePath}; tools=${tools.map((t) => t.name).join(',')}`)
}
