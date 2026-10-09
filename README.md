# bash-loader

**Your bash extensions in every Bash call Claude Code makes.**

Write a function once in `~/.claude/bash-ext/` (or in a project's `.claude/bash-ext/`), and every
Bash tool call, every hook run through a shell, and every subagent's shell has it. bash-loader
points `BASH_ENV` at a loader that concatenates your extensions into one cache per day, so a shell
start pays about 35 ms for them, not a file walk.

The plugin also ships a skill, `bash-loader:bash-extensions`, that Claude loads when it writes a
bash script for `~/.claude` or a project's `.claude`: where scripts go, the load-time cost rules,
reloading, measuring and testing.

## Install

At the prompt of a Claude Code terminal session:

```
/plugin install bash-loader --marketplace Nucs/.claude-bash-loader
```

Answer `y` to add the marketplace, then choose the user scope. New sessions get the loader at
start; nothing to add to `settings.json`.

Requirements:
- Claude Code with plugin hooks modules (tested on 2.1.291).
- bash 5 as the shell of the Bash tool: Git Bash on Windows, WSL, Linux. On macOS the default
  shell is zsh, which ignores `BASH_ENV`; the loader also skips bash 3.2 (`/bin/bash`).
- GNU `find`, `sort`; `gawk` when present (Git Bash and most Linux distributions have it).

## Writing an extension

```bash
# ~/.claude/bash-ext/hello.sh
# hello <name>: greet someone; prints one line, costs nothing at load time.
hello() { echo "Hello, $1"; }
```

Run `claude_bash_reload` (or start a new session) and every shell has `hello`.

| Location | Loads |
|---|---|
| `~/.claude/bash-ext/*.sh`, 4 levels deep | in every bash |
| a file in another `~/.claude/<folder>/` named `env.sh`, `bash-env.sh`, `bash-ext.sh`, `setup_*.sh`, `*_setup.sh`, `*-cli.sh`, `*-ext.sh`, `*-bash.sh` (and the `_` forms) | in every bash (a skill's `bash-ext.sh`, for example) |
| `~/.claude/.env` | every `NAME=value` line, exported |
| `<project>/.claude/bash-ext/*.sh` | in sessions started in that project, if the `projects` option allows it |

Folders that hold data are never scanned: `projects`, `plugins`, `plugin-data`, `file-history`,
`backups`, `ide`, `plans`, `scripts`, `session-env`, `shell-snapshots`, `src`, `statsig`,
`summary-cache`, `todos`.

**Keep top-level code free of processes.** It runs on every bash start, and on Git Bash each
`$(...)`, `date` or `dirname` costs 15-25 ms. Use builtins (`$EPOCHSECONDS`, `${path%/*}`,
`printf -v`), and find your own folder with `${_SOURCE_DIR:-...}`: the loader sets `_SOURCE_DIR`
before each file because `BASH_SOURCE` points at the cache. The skill has the full rules.

### Project extensions

Off by default: a project's scripts run in every Bash call of the session, so a repository you
clone must not get that by being opened. Allow projects in `/config`, row *Projects allowed to load
their own .claude/bash-ext*: paths or globs separated by `;` (`K:/source/*`, `~`-free absolute
paths, `**` across folders, `*` alone for every project). A project's definitions load after the
global ones and win over them.

### Your machine's own BASH_ENV

bash-loader replaces `BASH_ENV` in Claude Code sessions, but keeps what it replaced. A `BASH_ENV`
that Claude Code inherited (an OS variable, a shell profile's export, `settings.json` env) goes
to the loader as `CLAUDE_BASH_LOADER_PARENT`, and the loader sources that file **first**, then
your extensions, which can override what it defines. Like bash, it expands `$VAR` in the value;
a file that is not there is skipped. The time it takes shows as `parent:` in the timing line.

If that file leads back to bash-loader (a shim that sources the loader), the nested call returns
at once: nothing loads twice and nothing loops. To run only bash-loader's loader, turn off
`/config` → *Run the machine's own BASH_ENV first* (`parentBashEnv`).

### Shells outside Claude Code

The plugin keeps the loader at `~/.claude/plugin-data/bash-loader/claude-bash-loader.sh`. Point
`BASH_ENV` there to get the same extensions in a terminal:

```bash
# Linux, WSL: ~/.bashrc (and the environment of non-interactive shells)
export BASH_ENV="$HOME/.claude/plugin-data/bash-loader/claude-bash-loader.sh"
```

```bat
:: Windows, every Git Bash: a user environment variable
setx BASH_ENV "%USERPROFILE%\.claude\plugin-data\bash-loader\claude-bash-loader.sh"
```

The copy appears at the first Claude Code session after installing.

## How it works

1. At session start the plugin's hooks module copies `loader/claude-bash-loader.sh` to the path
   above (only when it changed), keeps the inherited `BASH_ENV` in `CLAUDE_BASH_LOADER_PARENT`,
   sets `BASH_ENV` to the copy, and sets `CLAUDE_BASH_LOADER_PROJECT` to the session's project when
   the `projects` option allows it. Every process the session starts afterwards inherits them.
2. Each bash sources the loader. It sources the parent `BASH_ENV` first (if any), then looks for
   today's cache,
   `~/.claude/.env-cached-<platform>-<UTC day>` (and the project's
   `.env-cached-project-<platform>-<day>-<project>`), and builds it when missing: `.env` exports,
   then each extension behind a `_SOURCE_DIR="<its folder>"` line, CR removed. Two `find` calls,
   one `sort` and one `gawk`; a lock and an atomic move keep parallel shells from reading half a
   cache.
3. It sources the cache, sets `CLAUDE_BASH_ENV_LOADED=1`, defines `claude_bash_reload`, and removes
   every name of its own (`_cbl_*`).

Caches are per platform (`win`, `wsl`, `linux`, `darwin`): Windows and WSL can share one
`~/.claude`, and a rebuild deletes only its own platform's old caches.

Timing: `ENV_SETUP_PERF=1 bash -c true` prints `[env-setup] 35ms (eval:33ms)`; a rebuild adds
`cache:Nms`. `ENV_SETUP_PERF=2` prints only above `ENV_SETUP_WARN_MS` (default 10).
`tools/profile-load.sh` lists the cost of each extension file.

Measured on an i9-13900K, Git Bash 5.3, 25 extension files, 556 KB: load 33-36 ms per shell,
rebuild 1.3-1.8 s once a day.

## Development

```bash
bash tests/run-tests.sh            # the loader, in throw-away config folders
claude plugin validate .           # manifest, marketplace file, hooks module
claude plugin test .               # the hooks module's tests (hooks/register.test.ts)
bash tools/profile-load.sh         # per-file load cost of your current cache
```

## License

MIT, see [LICENSE](LICENSE).
