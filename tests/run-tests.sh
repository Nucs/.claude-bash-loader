#!/usr/bin/env bash
# run-tests.sh - tests of loader/claude-bash-loader.sh, run in clean shells against throw-away
# Claude config folders. Usage: bash tests/run-tests.sh   (exit 0 = all passed)
#
# Each case starts `bash --noprofile --norc` without BASH_ENV, points the loader at a temporary
# root (CLAUDE_BASH_LOADER_ROOT) and checks what a shell holds after sourcing it. Nothing outside
# the temporary folder is read or written, so the tests are safe on a machine that uses the
# plugin. Needs bash 5, GNU find and sort; gawk is used when present.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADER="$HERE/../loader/claude-bash-loader.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
PASS=0
FAIL=0

# check <name> <expected> <actual>: record one assertion.
check() {
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"
  fi
}

# in_shell <root> <code> [env assignments...]: source the loader in a clean bash with <root> as
# CLAUDE_BASH_LOADER_ROOT plus the given assignments, then run <code>; prints its output.
in_shell() {
  local root="$1" code="$2"
  shift 2
  env -u BASH_ENV -u CLAUDE_BASH_LOADER_PROJECT CLAUDE_BASH_LOADER_ROOT="$root" "$@" \
    bash --noprofile --norc -c 'source "$1"; eval "$2"' _ "$LOADER" "$code" 2>&1
}

# platform_tag: the cache name tag the loader uses on this machine.
platform_tag() {
  case "$OSTYPE" in
    msys*|cygwin*) echo win ;;
    *) if [[ -d /mnt/c ]]; then echo wsl; else echo "${OSTYPE%%[^a-z]*}"; fi ;;
  esac
}

# make_root <dir>: a config folder with one extension of each kind and decoys that must not load.
make_root() {
  local r="$1"
  mkdir -p "$r/bash-ext/sub" "$r/skills/tool" "$r/other" "$r/projects/p" "$r/plugins/market/x" \
    "$r/plugin-data/bash-loader" "$r/deep/a/b/c/d"
  printf 'g_fn() { echo global; }\nG_VAR=1\n' > "$r/bash-ext/a.sh"
  printf 'sub_fn() { echo "$_SOURCE_DIR"; }\nSUB_DIR="$_SOURCE_DIR"\n' > "$r/bash-ext/sub/b.sh"
  printf 'tool_fn() { echo tool; }\n' > "$r/skills/tool/bash-ext.sh"
  printf 'crlf_fn() { echo crlf; }\r\nCRLF_VAR=1' > "$r/other/x-cli.sh"
  printf 'echo NOT_AN_EXTENSION\n' > "$r/other/readme.sh"
  printf 'echo FROM_PROJECTS\n' > "$r/projects/p/env.sh"
  printf 'echo FROM_PLUGINS\n' > "$r/plugins/market/x/env.sh"
  printf 'echo FROM_PLUGIN_DATA\n' > "$r/plugin-data/bash-loader/env.sh"
  printf 'echo TOO_DEEP\n' > "$r/deep/a/b/c/d/env.sh"
  printf 'FOO=bar\nexport BAZ=qux\nnot a line\n' > "$r/.env"
}

TAG="$(platform_tag)"
DAY=$((EPOCHSECONDS / 86400))

# 1. Global extensions load; decoys, skipped folders and too-deep files do not.
R1="$TMP/r1"; make_root "$R1"
out="$(in_shell "$R1" 'g_fn; tool_fn; crlf_fn; echo "$G_VAR $CRLF_VAR $FOO $BAZ $CLAUDE_BASH_ENV_LOADED"')"
check "global functions, CRLF file, .env exports" $'global\ntool\ncrlf\n1 1 bar qux 1' "$out"
check "cache file named per platform and UTC day" "yes" "$([[ -f $R1/.env-cached-$TAG-$DAY ]] && echo yes)"
check "decoys and skipped folders not loaded" "0" "$(grep -c -E 'NOT_AN_EXTENSION|FROM_PROJECTS|FROM_PLUGINS|FROM_PLUGIN_DATA|TOO_DEEP' "$R1/.env-cached-$TAG-$DAY")"
check "_SOURCE_DIR is the extension's folder" "$R1/bash-ext/sub" "$(in_shell "$R1" 'echo "$SUB_DIR"')"
check "_SOURCE_DIR unset after loading" "unset" "$(in_shell "$R1" 'echo "${_SOURCE_DIR-unset}"')"
check "no _cbl_ names left" "" "$(in_shell "$R1" 'compgen -v _cbl_; compgen -A function _cbl_')"
check "claude_bash_reload defined" "function" "$(in_shell "$R1" 'type -t claude_bash_reload')"

# 2. The cache is reused: a second start does not rebuild (no "cache:" in the timing line).
out="$(in_shell "$R1" ':' ENV_SETUP_PERF=1)"
check "second start reuses the cache" "no rebuild" "$([[ $out == *cache:* ]] && echo rebuilt || echo 'no rebuild')"

# 3. An edit waits for the next day, or for claude_bash_reload.
printf 'g_fn() { echo edited; }\nG_VAR=2\n' > "$R1/bash-ext/a.sh"
check "edit not seen before a reload" "global" "$(in_shell "$R1" 'g_fn')"
check "claude_bash_reload loads the edit" "edited" "$(in_shell "$R1" 'claude_bash_reload 2>/dev/null; g_fn')"
check "a new shell sees the reloaded cache" "edited" "$(in_shell "$R1" 'g_fn')"

# 4. Project extensions: loaded only when CLAUDE_BASH_LOADER_PROJECT names the project, after the
#    global ones (a project's definition wins), each project with its own cache.
P="$TMP/proj"; mkdir -p "$P/.claude/bash-ext"
printf 'p_fn() { echo project; }\ng_fn() { echo project-wins; }\n' > "$P/.claude/bash-ext/p.sh"
check "project extensions not loaded without the variable" "missing" "$(in_shell "$R1" 'type -t p_fn || echo missing')"
check "project extensions loaded and win over global" $'project\nproject-wins' "$(in_shell "$R1" 'p_fn; g_fn' CLAUDE_BASH_LOADER_PROJECT="$P")"
KEY="$(cd "$P" && pwd)"; KEY="${KEY//[^A-Za-z0-9]/_}"
check "project cache named per project" "yes" "$([[ -f $R1/.env-cached-project-$TAG-$DAY-$KEY ]] && echo yes)"
check "a project without .claude/bash-ext adds nothing" "global" "$(in_shell "$R1" 'g_fn | sed s/edited/global/' CLAUDE_BASH_LOADER_PROJECT="$TMP")"

# 5. A rebuild deletes this platform's old caches and stale temp files, never another
#    platform's; the global rebuild also drops project caches of earlier days.
OTHER=wsl; [[ $TAG == wsl ]] && OTHER=win
touch "$R1/.env-cached-$OTHER-1" "$R1/.env-cached-$TAG-1" "$R1/.env-cache.tmp.999" "$R1/.env-cached-project-$TAG-1-$KEY"
in_shell "$R1" ':' ENV_SETUP_REBUILD=1 >/dev/null
check "other platform's cache kept" "yes" "$([[ -f $R1/.env-cached-$OTHER-1 ]] && echo yes)"
check "old cache, temp file, old project cache removed" "none" "$( (ls "$R1/.env-cached-$TAG-1" "$R1/.env-cache.tmp.999" "$R1/.env-cached-project-$TAG-1-$KEY" 2>/dev/null || true) | wc -l | sed 's/^ *0$/none/')"

# 6. The patterns are quoted: a build started in a folder holding files that match them still
#    finds every extension (unquoted, bash expanded *-cli.sh to the local file names).
D="$TMP/decoy"; mkdir -p "$D"; touch "$D/zz-cli.sh" "$D/a_setup.sh"
check "build from a decoy folder finds every extension" "crlf" "$(cd "$D" && in_shell "$R1" 'crlf_fn' ENV_SETUP_REBUILD=1)"

# 7. Git Bash: a Windows spelling of the root names the same cache and writes MSYS paths.
if [[ $TAG == win ]] && command -v cygpath >/dev/null 2>&1; then
  WIN_ROOT="$(cygpath -w "$R1")"
  out="$(in_shell "$WIN_ROOT" 'echo "$SUB_DIR"' ENV_SETUP_PERF=1)"
  check "Windows spelling reuses the cache, MSYS _SOURCE_DIR" "$R1/bash-ext/sub" "$(printf '%s\n' "$out" | grep -v '^\[env-setup\]')"
  check "Windows spelling did not rebuild" "no rebuild" "$([[ $out == *cache:* ]] && echo rebuilt || echo 'no rebuild')"
fi

# 8. The loader's own file name matches none of its extension patterns: a copy of it under
#    the root is never swept into the cache (it would source itself in every shell).
mkdir -p "$R1/somewhere"; cp "$LOADER" "$R1/somewhere/claude-bash-loader.sh"
in_shell "$R1" ':' ENV_SETUP_REBUILD=1 >/dev/null
check "a copy of the loader under the root is not loaded" "0" "$(grep -c 'claude-bash-loader.sh - the BASH_ENV loader' "$R1/.env-cached-$TAG-$DAY")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
