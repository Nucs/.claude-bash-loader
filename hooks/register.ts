import type { EngineInterface, Register } from 'claude-code'

/**
 * The loader's file name, in the plugin (`loader/`) and in the copy BASH_ENV names.
 *
 * Chosen to match none of the extension names the loader itself searches the config folder for
 * (`env.sh`, `bash-env.sh`, `*-cli.sh`, `*_setup.sh`, ...): a copy that did match would be swept
 * into the cache and source the loader again in every shell.
 */
export const LOADER = 'claude-bash-loader.sh'

/**
 * Where the loader copy lives, under the Claude config folder.
 *
 * A stable path on purpose: the plugin's own folder moves with every installed version, while
 * shells outside Claude Code (a Git Bash terminal, WSL) keep BASH_ENV pointed at one place.
 */
export const DATA_DIR = 'plugin-data/bash-loader'

/**
 * Rewrites every backslash of a path as a forward slash.
 *
 * Bash on Windows (Git Bash) reads `C:/x` as well as `C:\x`; slashes keep the value readable in
 * logs and compare equal to what the loader writes.
 *
 * @param path any path
 * @returns the same path with `/` separators
 */
export function toSlashes(path: string): string {
  return path.replace(/\\/g, '/')
}

/**
 * Resolves the Claude config folder: `CLAUDE_CONFIG_DIR`, else `<home>/.claude`.
 *
 * Home is read from USERPROFILE before HOME: a Claude Code started from Git Bash can carry an
 * MSYS HOME (`/c/Users/...`) that Windows file calls read as `C:\c\Users\...`.
 *
 * @param $ the engine interface
 * @returns the folder, with forward slashes and no trailing slash
 * @throws Error when none of the three variables is set; the caller logs it and the session
 *   runs without the loader
 */
export async function configDir($: EngineInterface): Promise<string> {
  const config = await $.env.get('CLAUDE_CONFIG_DIR')
  if (config) return toSlashes(config).replace(/\/+$/, '')
  const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME'))
  if (!home) throw new Error('none of CLAUDE_CONFIG_DIR, USERPROFILE and HOME is set')
  return `${toSlashes(home).replace(/\/+$/, '')}/.claude`
}

/**
 * Spells a path the way the allow-list compares it.
 *
 * Forward slashes, no trailing slash, an MSYS drive (`/k/source`) as a Windows one
 * (`k:/source`), and the drive letter in lower case, so `K:\source\x`, `k:/source/x` and
 * `/k/source/x` all compare equal.
 *
 * @param path a project root or an allow-list entry
 * @returns the comparable spelling
 */
export function comparable(path: string): string {
  let p = toSlashes(path.trim()).replace(/\/+$/, '')
  const msys = /^\/([A-Za-z])(\/|$)/.exec(p)
  if (msys) p = `${msys[1]}:${p.slice(2)}`
  if (/^[A-Za-z]:/.test(p)) p = p[0].toLowerCase() + p.slice(1)
  return p
}

/**
 * Reports whether two spellings name the same path: {@link comparable} spellings compared
 * whole, ignoring case when they are Windows paths (a drive letter), whose case does not matter.
 *
 * @param a one path, in any spelling
 * @param b the other
 * @returns true when both name the same path
 */
export function samePath(a: string, b: string): boolean {
  const x = comparable(a)
  const y = comparable(b)
  return /^[a-z]:/.test(x) ? x.toLowerCase() === y.toLowerCase() : x === y
}

/**
 * Turns one allow-list entry into an anchored regular expression.
 *
 * `**` matches any run of characters, folders included; `*` a run within one folder name;
 * every other character itself.
 *
 * @param glob the entry, already {@link comparable}
 * @param ignoreCase true for Windows paths, whose case does not matter
 * @returns the expression
 */
export function globRegExp(glob: string, ignoreCase: boolean): RegExp {
  let source = ''
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (c === '*') {
      if (glob[i + 1] === '*') {
        source += '.*'
        i++
      } else {
        source += '[^/]*'
      }
    } else {
      source += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&')
    }
  }
  return new RegExp(`^${source}$`, ignoreCase ? 'i' : '')
}

/**
 * Reports whether a session's project may load its own `.claude/bash-ext` scripts.
 *
 * Off by default: those scripts run in every Bash call of the session, so a repository someone
 * clones must not get that just by being opened.
 *
 * @param root the session's project root, in any spelling
 * @param allowed the `projects` option: entries separated by `;` or line breaks, each an
 *   absolute path or a glob ({@link globRegExp}); `*` alone allows every project
 * @returns true when an entry matches the root
 */
export function isProjectAllowed(root: string, allowed: string): boolean {
  const target = comparable(root)
  const windows = /^[a-z]:/.test(target)
  for (const raw of allowed.split(/[;\n]/)) {
    const entry = raw.trim()
    if (!entry) continue
    if (entry === '*') return true
    if (globRegExp(comparable(entry), windows).test(target)) return true
  }
  return false
}

/**
 * Prepares one session: refreshes the loader copy, keeps the machine's own BASH_ENV as the
 * loader's parent, points BASH_ENV at the copy, and names the project for the loader when the
 * `projects` option allows it.
 *
 * Everything the session starts afterwards inherits these variables: every Bash call, every
 * hook run through a shell, every MCP server. The copy is rewritten only when its text differs,
 * and without CR: a checkout that turned the loader's LF into CRLF would otherwise hand bash a
 * `\r` at the end of every command.
 *
 * The parent: the BASH_ENV this process inherited (an OS variable, a shell profile's export,
 * settings.json env) goes to CLAUDE_BASH_LOADER_PARENT, which the loader sources first, so
 * taking over BASH_ENV keeps the machine's setup. When BASH_ENV already names the copy, the
 * value is this plugin's own (a module reload in this process, or a child Claude Code process
 * that inherited both variables): the parent recorded then stays as it is. Off
 * (`parentBashEnv: false`), the variable is unset and only this plugin's loader runs.
 *
 * @param $ the engine interface
 * @param projects the `projects` option
 * @param chainParent the `parentBashEnv` option: true to run the machine's BASH_ENV first
 * @throws Error when the plugin's loader cannot be read, the copy cannot be written, or the
 *   config folder cannot be resolved; the caller logs it and the session runs without the loader
 */
export async function setUp($: EngineInterface, projects: string, chainParent: boolean): Promise<void> {
  const copy = `${await configDir($)}/${DATA_DIR}/${LOADER}`
  const text = (await $.fs.read(`${$.plugin.root}/loader/${LOADER}`)).replace(/\r/g, '')
  const current = (await $.fs.exists(copy)) ? await $.fs.read(copy) : undefined
  if (current !== text) await $.fs.write(copy, text)
  const inherited = await $.env.get('BASH_ENV')
  if (!chainParent) {
    await $.env.set('CLAUDE_BASH_LOADER_PARENT', undefined)
  } else if (inherited !== undefined && inherited.trim() !== '' && !samePath(inherited, copy)) {
    await $.env.set('CLAUDE_BASH_LOADER_PARENT', inherited)
  }
  await $.env.set('BASH_ENV', copy)
  const root = await $.session.root()
  await $.env.set('CLAUDE_BASH_LOADER_PROJECT', isProjectAllowed(root, projects) ? toSlashes(root) : undefined)
}

/**
 * Registers the plugin's one hook: `session.start` prepares the environment before the engine's
 * own session start runs, so its shell snapshot and the settings' SessionStart hooks see
 * BASH_ENV exactly as a BASH_ENV from settings.json would have given it.
 *
 * The hook fails open: an error goes to the debug log and the session starts without the loader,
 * never with a broken start. A change of the `projects` option reloads the module, which runs
 * `session.start` again with the new value.
 *
 * @param on the engine's registrar
 * @param options the plugin's settings; `projects` is the project allow-list, `parentBashEnv`
 *   (default true) runs the machine's own BASH_ENV first
 */
export const register: Register = (on, options) => {
  const projects = typeof options.projects === 'string' ? options.projects : ''
  const chainParent = options.parentBashEnv !== false
  on('session.start', async ($, e, next) => {
    try {
      await setUp($, projects, chainParent)
    } catch (error) {
      $.ui.log(`bash-loader: this session runs without the loader: ${String(error)}`, { to: 'debug' })
    }
    return next(e)
  })
}
