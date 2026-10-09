---
name: bash-extensions
description: Use when writing, editing, debugging or reviewing a bash script that lives in ~/.claude (global) or in a project's .claude folder - bash extensions that the bash-loader plugin loads into every Bash call through BASH_ENV (~/.claude/bash-ext/*.sh, <project>/.claude/bash-ext/*.sh, env.sh, *-cli.sh, *_setup.sh, a skill's bash-ext.sh), and hook, status-line or helper scripts under .claude. Covers where a script goes and when it loads, the load-time cost rules (top-level code runs on every bash start; no processes there), self-location with _SOURCE_DIR, reloading, measuring and testing, and Git Bash / WSL pitfalls.
---

# Bash scripts for ~/.claude and a project's .claude

The bash-loader plugin points `BASH_ENV` at its loader, so **every** bash that Claude Code starts
(each Bash tool call, each hook run through a shell) first loads the user's extensions. Top-level
code in an extension therefore runs thousands of times a day. Write it accordingly.

## Where a script goes, and when it loads

| Location | Loads | Notes |
|---|---|---|
| `~/.claude/bash-ext/*.sh` (4 levels deep) | every bash | the normal place for functions and aliases |
| `~/.claude/<folder>/` file named `env.sh`, `bash-env.sh`, `bash-ext.sh`, `bash_ext.sh`, `setup_*.sh`, `*_setup.sh`, `setup-*.sh`, `*-setup.sh`, `*_cli.sh`, `*-cli.sh`, `*_bash.sh`, `*-bash.sh`, `*_ext.sh`, `*-ext.sh` | every bash | e.g. a skill's `skills/<name>/bash-ext.sh` |
| `<project>/.claude/bash-ext/*.sh` | bash in a session started in that project | only when the plugin's `projects` option allows the project (`/config`) |
| `~/.claude/.env` | every bash | each `NAME=value` line, exported |
| `.claude/hooks/*`, status-line scripts, `scripts/*` | only when called | not extensions; never name them like one |

Skipped folders (never scanned): `projects`, `plugins`, `plugin-data`, `file-history`, `backups`,
`ide`, `plans`, `scripts`, `session-env`, `shell-snapshots`, `src`, `statsig`, `summary-cache`,
`todos`. A file in `~/.claude` that matches an extension name but must not load belongs in one of
them, or needs another name: a stray `env.sh` four levels down loads into every shell.

Order: `.env`, then global extensions (folders in name order, files sorted within a folder), then
the project's. A later definition wins, so a project can override a global function.

## The load-time rules

The loader concatenates all extensions into one cache per UTC day and sources it (~35 ms for
~550 KB). What remains per start is parsing plus whatever top-level code runs. On Git Bash every
process start costs ~15-25 ms, so a single `$(...)` at the top level of one file can double the
load time of every Bash call.

1. **No processes at the top level.** No `$(...)`, backticks, pipes, `date`, `dirname`, `basename`,
   `uname`, `cygpath`, `command -v` in a subshell, `git`, `python`. Use builtins:
   - time: `$EPOCHSECONDS`, `$EPOCHREALTIME` (bash 5), not `$(date +%s)`;
   - paths: `${path%/*}` (dirname), `${path##*/}` (basename), `${path//\\//}` (slashes);
   - formatting into a variable: `printf -v name '%s' ...`, not `name=$(printf ...)`;
   - checks: `[[ -f file ]]`, `[[ $OSTYPE == msys* ]]`, `type -t name`.
   Work that needs a process goes inside a function, run when the function is called.
2. **Locate the script's own folder with `_SOURCE_DIR`.** Inside the cache, `BASH_SOURCE[0]` is the
   cache file, not your script. The loader writes `_SOURCE_DIR="<folder of the file>"` before each
   file. Pattern that also works when the file is sourced directly:
   `MY_DIR="${_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"` (the fallback runs only
   outside the cache). Read `_SOURCE_DIR` at the top level, not inside a function: it is unset
   after loading.
3. **No `return` or `exit` at the top level.** All files are one cache: a top-level `return` stops
   every file after it. Use `if ...; then ...; fi` instead of an early return.
4. **Globals:** declare top-level arrays and maps with `declare -g` (`declare -gA MAP=(...)`).
   `claude_bash_reload` sources the cache inside a function, where a plain `declare` creates a
   local that disappears.
5. **Names:** prefix internal functions and variables (`_mytool_*`); everything you define lives in
   every shell. Do not use the `_cbl_` prefix (the loader's own) or redefine `claude_bash_reload`.
6. **Quiet:** print nothing at load time. Output at load lands in front of every command's output.
7. **Background work:** start it at most rarely, and record that it ran (a timestamp file) so the
   next starts skip it. A check that exits early without recording itself runs on every start.
8. **Line endings:** LF. The loader removes CR from extensions, but a hook or helper script with
   CRLF fails (`$'\r': command not found`).

## After editing

- The cache lives one UTC day. Run `claude_bash_reload` (or `ENV_SETUP_REBUILD=1 bash -c true`)
  so new shells get the edit now.
- A running Claude Code session also sources its shell snapshot (taken at session start) after
  the loader, so its Bash calls can keep the old function until the session restarts. Test a new
  definition with `bash -c 'source <file>; <function> ...'` or in a new session.

## Measuring and testing

1. Syntax: `bash -n <file>`.
2. Total load time: `ENV_SETUP_PERF=1 bash -c true` prints `[env-setup] Nms (cache:… eval:…)`;
   `eval:` is the load, `cache:` a rebuild. Expect ~30-40 ms; investigate anything above ~50 ms.
3. Per file: `bash <plugin root>/tools/profile-load.sh` (the plugin root is two folders above this
   skill's base directory) lists each extension's parse and run time. Run time above ~1 ms means
   a process starts at the top level (rule 1).
4. Behavior: source the file in a clean shell, `env -u BASH_ENV bash --noprofile --norc -c
   'source <file>; <checks>'`, so the test does not depend on the cache.

## Hook, status-line and helper scripts under .claude

- Register hooks in exec form (`"command"` + `"args"`, absolute paths): no shell, no `BASH_ENV`,
  ~50 ms instead of hundreds. A string-form command runs through bash and loads every extension
  first.
- SessionEnd hooks have a 1.5 s limit unless the hook sets `"timeout"`; exit and `/clear` wait
  for them.
- Fail open: on an unexpected error print nothing and exit 0; exit 2 blocks or reports.
- Git Bash turns `$HOME` into `/c/Users/<name>`, which a Windows program reads as
  `C:\c\Users\...`: pass Windows programs Windows paths.
- In Claude Code's Bash tool, `\\` inside single quotes reaches the program as `\`: write test
  payloads with backslashes (Windows paths in JSON) to a file with the Write tool and redirect it.

## Documenting

Put a comment above every function: what it does, its parameters, what it prints or returns, and
its consequences (what it costs, what it changes). Explain non-obvious top-level code with a short
WHY comment.
