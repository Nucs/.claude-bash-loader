import type { On } from 'claude-code'
import { describe, expect, test, type Engine } from 'claude-code/testing'
import { comparable, globRegExp, isProjectAllowed } from './register.ts'

/** What the in-memory world beneath the plugin holds and records. */
type World = {
  /** Files by path (forward slashes). */
  files: Map<string, string>
  /** The process environment the plugin reads and writes. */
  env: Map<string, string | undefined>
  /** How many times the plugin wrote a file. */
  writes: { count: number }
}

/** What a test seeds the world with. */
type Seed = {
  env?: Record<string, string>
  files?: Record<string, string>
  root?: string
  /** When true, reading the plugin's own loader fails, to test the fail-open path. */
  loaderMissing?: boolean
}

/** The plugin's loader as the test serves it: with CRLF, to show the copy drops every CR. */
const LOADER_TEXT = '# loader\r\necho loaded\r\n'

/** The copy path the plugin writes for USERPROFILE C:\Users\me. */
const COPY = 'C:/Users/me/.claude/plugin-data/bash-loader/claude-bash-loader.sh'

/**
 * Stands in for the engine beneath the plugin: environment, files, project root, the engine's
 * own session start and the debug log, all in memory, so no test touches the disk or the real
 * environment.
 *
 * @param on the registrar whose hooks stand for the engine
 * @param seed what the world holds before the test
 * @returns the world, for the test to inspect
 */
function world(on: On, seed: Seed = {}): World {
  const files = new Map<string, string>(Object.entries(seed.files ?? {}))
  const env = new Map<string, string | undefined>(Object.entries(seed.env ?? { USERPROFILE: 'C:\\Users\\me' }))
  const writes = { count: 0 }
  // key(path): one spelling per path, forward slashes. The engine may resolve a path before it
  // raises the event (`C:/x` arriving as `C:\x`), so the map is keyed by this spelling.
  const key = (path: string) => path.replace(/\\/g, '/')
  on('env.get', (_$, e) => ({ value: env.get(e.name) }))
  on('env.set', (_$, e) => {
    env.set(e.name, e.value)
    return { value: undefined }
  })
  on('fs.exists', (_$, e) => ({ value: files.has(key(e.path)) }))
  on('fs.read', (_$, e) => {
    const path = key(e.path)
    // The plugin reads its own loader under $.plugin.root, wherever the test kit puts that.
    if (path.endsWith('/loader/claude-bash-loader.sh') && !files.has(path)) {
      if (seed.loaderMissing) throw new Error(`ENOENT: ${e.path}`)
      return { value: LOADER_TEXT }
    }
    const text = files.get(path)
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    files.set(key(e.path), e.text)
    writes.count++
    return { value: undefined }
  })
  on('session.root', () => ({ value: seed.root ?? 'K:\\source\\demo' }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('ui.log', (_$, e) => {
    // Printed so a failing test shows the plugin's own debug line.
    console.log(`ui.log [${e.to}]: ${e.text}`)
    return { value: undefined }
  })
  return { files, env, writes }
}

/**
 * Starts a session through the plugin, as Claude Code does when it opens or resumes one.
 *
 * @param $ the test engine
 */
async function start($: Engine): Promise<void> {
  await $.session.start({ cwd: 'K:\\source\\demo', surface: 'terminal', isInteractive: true })
}

describe('BASH_ENV', () => {
  test('a session start writes the loader copy without CR and points BASH_ENV at it', async ($, on) => {
    const w = world(on)
    await start($)
    expect(w.env.get('BASH_ENV')).toBe(COPY)
    expect(w.files.get(COPY)).toBe('# loader\necho loaded\n')
  })

  test('CLAUDE_CONFIG_DIR wins over the home folder', async ($, on) => {
    const w = world(on, { env: { CLAUDE_CONFIG_DIR: 'D:\\cfg\\', USERPROFILE: 'C:\\Users\\me' } })
    await start($)
    expect(w.env.get('BASH_ENV')).toBe('D:/cfg/plugin-data/bash-loader/claude-bash-loader.sh')
  })

  test('HOME is the fallback when USERPROFILE is unset (Linux, macOS)', async ($, on) => {
    const w = world(on, { env: { HOME: '/home/me' } })
    await start($)
    expect(w.env.get('BASH_ENV')).toBe('/home/me/.claude/plugin-data/bash-loader/claude-bash-loader.sh')
  })

  test('an up-to-date copy is not written again', async ($, on) => {
    const w = world(on, { files: { [COPY]: '# loader\necho loaded\n' } })
    await start($)
    expect(w.writes.count).toBe(0)
    expect(w.env.get('BASH_ENV')).toBe(COPY)
  })

  test('a failure leaves the session start intact and BASH_ENV untouched', async ($, on) => {
    const w = world(on, { loaderMissing: true })
    await start($)
    expect(w.env.has('BASH_ENV')).toBe(false)
  })
})

describe('project extensions', () => {
  test('off by default: no project is named', async ($, on) => {
    const w = world(on, { env: { USERPROFILE: 'C:\\Users\\me', CLAUDE_BASH_LOADER_PROJECT: 'stale' } })
    await start($)
    expect(w.env.get('CLAUDE_BASH_LOADER_PROJECT')).toBeUndefined()
  })

  test('an allowed project is named, with forward slashes', { options: { projects: 'K:/source/demo' } }, async ($, on) => {
    const w = world(on)
    await start($)
    expect(w.env.get('CLAUDE_BASH_LOADER_PROJECT')).toBe('K:/source/demo')
  })

  test('a glob that does not match leaves it unnamed', { options: { projects: 'K:/other/*' } }, async ($, on) => {
    const w = world(on)
    await start($)
    expect(w.env.get('CLAUDE_BASH_LOADER_PROJECT')).toBeUndefined()
  })
})

describe('allow-list', () => {
  test('spellings of one Windows path compare equal', () => {
    expect(comparable('K:\\source\\x\\')).toBe('k:/source/x')
    expect(comparable('/k/source/x')).toBe('k:/source/x')
    expect(comparable('/home/me/p')).toBe('/home/me/p')
  })

  test('* stays within one folder name, ** crosses folders', () => {
    expect(globRegExp('k:/source/*', true).test('k:/source/demo')).toBe(true)
    expect(globRegExp('k:/source/*', true).test('k:/source/a/b')).toBe(false)
    expect(globRegExp('k:/source/**', true).test('k:/source/a/b')).toBe(true)
  })

  test('entries are split on ; and line breaks, * alone allows everything', () => {
    expect(isProjectAllowed('K:\\source\\demo', 'C:/x; K:/source/*')).toBe(true)
    expect(isProjectAllowed('K:\\source\\demo', 'C:/x\nK:/source/demo')).toBe(true)
    expect(isProjectAllowed('/home/me/p', '*')).toBe(true)
    expect(isProjectAllowed('K:\\source\\demo', '')).toBe(false)
  })

  test('Windows paths ignore case, others do not', () => {
    expect(isProjectAllowed('k:\\SOURCE\\Demo', '/K/source/demo')).toBe(true)
    expect(isProjectAllowed('/home/me/P', '/home/me/p')).toBe(false)
  })

  test('glob characters other than * are literal', () => {
    expect(isProjectAllowed('K:\\a+b\\c', 'K:/a+b/c')).toBe(true)
    expect(isProjectAllowed('K:\\aab\\c', 'K:/a+b/c')).toBe(false)
  })
})
