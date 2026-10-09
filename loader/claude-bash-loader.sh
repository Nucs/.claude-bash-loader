# claude-bash-loader.sh - the BASH_ENV loader of the bash-loader plugin.
#
# https://github.com/Nucs/.claude-bash-loader
#
# Every non-interactive bash sources the file that BASH_ENV names before it runs anything. The
# plugin's session-start hook keeps a copy of this file at
# <config dir>/plugin-data/bash-loader/claude-bash-loader.sh and points BASH_ENV at it (the file
# name matches none of the extension patterns below, so the copy never loads itself), so every Bash call Claude
# Code makes (and every hook it starts through a shell) gets the user's bash extensions:
# functions, aliases and exported variables written once in ~/.claude or in a project's .claude.
# Outside Claude Code a shell or OS variable can point BASH_ENV at the same copy (see README).
#
# What it loads, in this order:
#   0. The machine's own BASH_ENV, the value the plugin replaced (an OS variable, a shell
#      profile's export, settings.json env), passed in CLAUDE_BASH_LOADER_PARENT. Installing the
#      plugin keeps that setup; its parentBashEnv option turns this off.
#   1. <root>/.env: every NAME=value and export NAME=value line, exported.
#   2. Global extensions, <root> being $CLAUDE_BASH_LOADER_ROOT, else $CLAUDE_CONFIG_DIR, else
#      ~/.claude: every *.sh up to 4 levels deep in <root>/bash-ext; in the other folders of
#      <root> only files named like an extension (env.sh, bash-env.sh, bash-ext.sh, setup_*.sh,
#      *_setup.sh, *-cli.sh, *-ext.sh, *-bash.sh, ...: the second find below). Data folders are
#      skipped: projects, plugins, plugin-data, file-history and the others in _cbl_skip.
#   3. Project extensions: every *.sh up to 4 levels deep in
#      $CLAUDE_BASH_LOADER_PROJECT/.claude/bash-ext. The plugin sets that variable only for a
#      project its "projects" option allows: a cloned repository must not get its code into
#      every Bash call by default.
#
# Cost: a build concatenates those files into one cache (two finds, one sort, one gawk: ~1.3 s
# on Git Bash for ~25 files); every other start only sources the cache (~35 ms for ~550 KB). A
# cache lives one UTC day, per platform (win, wsl, linux, darwin) and per project; an edit shows
# up the next day, or at once after claude_bash_reload (or ENV_SETUP_REBUILD=1).
#
# Reads: CLAUDE_BASH_LOADER_PARENT, CLAUDE_BASH_LOADER_ROOT, CLAUDE_CONFIG_DIR, HOME,
#   CLAUDE_BASH_LOADER_PROJECT, ENV_SETUP_REBUILD=1 (rebuild now), ENV_SETUP_PERF=1 (print
#   timing) or 2 (print only above ENV_SETUP_WARN_MS, default 10).
# Leaves behind: the extensions' own definitions, CLAUDE_BASH_ENV_LOADED=1 (exported) and the
#   function claude_bash_reload. Every other name it uses starts with _cbl_ and is removed
#   before it returns, so nothing of the loader itself leaks into the shell.

# Re-entry guard. A chain that leads back here must neither recurse nor load twice: on a
# machine whose own BASH_ENV is a shim that sources this loader (the parent, below), the nested
# call returns at once and this outer call does the loading, with its own root. _cbl_active is
# set from here to the end of the file; not exported, so a child bash loads again.
if [[ -n ${_cbl_active:-} ]]; then return 0 2>/dev/null || exit 0; fi
_cbl_active=1

# The machine's own BASH_ENV first: the plugin saved the value it replaced in
# CLAUDE_BASH_LOADER_PARENT (unset when the plugin's parentBashEnv option is off). bash expands
# a BASH_ENV value (parameters, command substitution, arithmetic) before using it as a file
# name, so the same happens here when the value holds a `$`; a file that is not there is
# skipped silently, as bash itself does. It runs before everything else, so the extensions can
# override what it defines. This part stays bash 3.2-compatible: the parent still runs where
# the rest of the loader cannot (EPOCHREALTIME is empty there, so no timing).
if [[ -n ${CLAUDE_BASH_LOADER_PARENT:-} ]]; then
  _cbl_parent="$CLAUDE_BASH_LOADER_PARENT"
  case "$_cbl_parent" in *'$'*) eval "_cbl_parent=\"$_cbl_parent\"" ;; esac
  _cbl_parent_t0="${EPOCHREALTIME:-}"
  [[ -f "$_cbl_parent" ]] && source "$_cbl_parent"
  [[ -n "$_cbl_parent_t0" ]] && _cbl_parent_ms=$(( (${EPOCHREALTIME/.} - ${_cbl_parent_t0/.}) / 1000 ))
  unset _cbl_parent _cbl_parent_t0
fi

# Needs bash 5 (EPOCHSECONDS, mapfile, declare -A, ${x,,}). An older bash (macOS /bin/bash 3.2)
# skips the rest instead of printing errors in every shell; sourced, `return` ends this file.
if (( ${BASH_VERSINFO[0]:-0} < 5 )); then unset _cbl_active _cbl_parent_ms; return 0 2>/dev/null || exit 0; fi

# Timing, zero-cost when disabled (ENV_SETUP_PERF=1 shows it, =2 warns above a threshold). It
# starts after the parent, whose own time is reported apart ("parent:").
[[ "${ENV_SETUP_PERF:-0}" != "0" ]] && _cbl_perf_start=${EPOCHREALTIME/.}

# _cbl_norm <var> <path>: store <path> in the variable <var> with / separators and no trailing
# slash; on Git Bash also C:/x as /c/x. A builtin-only rewrite (no cygpath process), so that a
# shell started through a Windows spelling (BASH_ENV=C:\...) and one started through an MSYS
# spelling (/c/...) name the same cache and write the same _SOURCE_DIR values into it.
_cbl_norm() {
  local p="${2//\\//}"
  if [[ ! -d /mnt/c && $p =~ ^([A-Za-z]):(/.*)?$ ]]; then p="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"; fi
  [[ $p == / ]] || p="${p%/}"
  printf -v "$1" '%s' "$p"
}

# Platform tag of the cache name: Windows (Git Bash) and WSL can share one root (WSL reaches it
# through /mnt/c), and each needs its own cache because the paths inside differ.
case "$OSTYPE" in
  msys*|cygwin*) _cbl_platform=win ;;
  *) if [[ -d /mnt/c ]]; then _cbl_platform=wsl; else _cbl_platform="${OSTYPE%%[^a-z]*}"; fi ;;
esac
_cbl_norm _cbl_root "${CLAUDE_BASH_LOADER_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
_cbl_day=$((EPOCHSECONDS / 86400))
_cbl_lock="$_cbl_root/.env-cache.lock"
_cbl_rebuild_ms=0

# _cbl_acquire_lock: take the build lock (mkdir is atomic), waiting up to ~3 s. A lock older
# than 60 s is left over from a killed build and is removed first. Returns 1 when it gave up.
_cbl_acquire_lock() {
  local timeout=30 waited=0 lock_age
  if [[ -d "$_cbl_lock" ]]; then
    lock_age=$(( EPOCHSECONDS - $(stat -c %Y "$_cbl_lock" 2>/dev/null || echo 0) ))
    (( lock_age > 60 )) && rmdir "$_cbl_lock" 2>/dev/null
  fi
  while ! mkdir "$_cbl_lock" 2>/dev/null; do
    (( ++waited > timeout )) && return 1
    sleep 0.1
  done
  return 0
}

# _cbl_release_lock: release the build lock.
_cbl_release_lock() { rmdir "$_cbl_lock" 2>/dev/null; }

# _cbl_concat <out> <file>...: append each file to <out> the way the cache carries it: a
# _SOURCE_DIR="<its folder>" line, its text with every CR removed, then an empty line. Inside
# the cache BASH_SOURCE[0] is the cache file, so an extension finds its own folder through
# ${_SOURCE_DIR:-...}. One gawk pass writes exactly what printf + tr + printf wrote per file (RT
# keeps a missing final newline missing, BEGINFILE still heads an empty file, LC_ALL=C keeps
# the bytes as they are); without gawk (mawk lacks BEGINFILE and RT) it goes file by file.
_cbl_concat() {
  local out="$1" f
  shift
  (($#)) || return 0
  if command -v gawk >/dev/null 2>&1; then
    LC_ALL=C gawk 'BEGINFILE { d = FILENAME; sub(/\/[^\/]*$/, "", d); printf "_SOURCE_DIR=\"%s\"\n", d }
      { gsub(/\r/, ""); printf "%s%s", $0, RT }
      ENDFILE { printf "\n" }' "$@" >> "$out"
  else
    for f in "$@"; do
      printf '_SOURCE_DIR="%s"\n' "${f%/*}" >> "$out"
      tr -d '\r' < "$f" >> "$out"
      printf '\n' >> "$out"
    done
  fi
}

# _cbl_build_global <out>: write the global cache: the .env exports, then the extensions in
# folder order (glob order of <root>'s folders), sorted by path within each folder.
# Two finds (bash-ext: every *.sh; the rest: extension names), one sort keyed by a zero-padded
# folder rank and one gawk pass replace a find|sort|tr per folder and a tr per file (~190
# processes, 5.2 s on Git Bash). The patterns are quoted: unquoted, bash would expand
# setup_*.sh or *-cli.sh against the current folder and search for those names only.
_cbl_build_global() {
  local out="$1" skip d n k=0 pad h f
  local -a ext=() other=() lines=() files=()
  local -A rank=()
  skip="backups|file-history|ide|plans|projects|scripts|session-env|shell-snapshots|src|statsig|summary-cache|todos|plugins|plugin-data"
  : > "$out"
  if [ -f "$_cbl_root/.env" ]; then
    sed -n '/^[A-Za-z_][A-Za-z0-9_]*=/{s/^/export /p;d}; /^export [A-Za-z_][A-Za-z0-9_]*=/p' "$_cbl_root/.env" | tr -d '\r' >> "$out"
    printf '\n' >> "$out"
  fi
  for d in "$_cbl_root"/*/; do
    [ -d "$d" ] || continue
    n="${d%/}"; n="${n##*/}"
    [[ "$n" =~ ^($skip)$ ]] && continue
    printf -v pad '%04d' "$k"; rank["$d"]=$pad; k=$((k + 1))
    if [[ "$n" == "bash-ext" ]]; then ext+=("$d"); else other+=("$d"); fi
  done
  # find prints "<start folder>\t<path>" (%H is the folder as passed, trailing slash included,
  # which also makes find follow a folder that is a symlink or junction).
  while IFS=$'\t' read -r h f; do
    lines+=("${rank[$h]}"$'\t'"$f")
  done < <(
    ((${#ext[@]})) && find "${ext[@]}" -maxdepth 4 -name '*.sh' -type f -printf '%H\t%p\n' 2>/dev/null
    ((${#other[@]})) && find "${other[@]}" -maxdepth 4 \( -name env.sh -o -name bash-env.sh -o -name bash_env.sh -o -name bash-ext.sh -o -name bash_ext.sh -o -name 'setup_*.sh' -o -name '*_setup.sh' -o -name 'setup-*.sh' -o -name '*-setup.sh' -o -name '*_cli.sh' -o -name '*-cli.sh' -o -name '*_bash.sh' -o -name '*-bash.sh' -o -name '*_ext.sh' -o -name '*-ext.sh' -o -name '*bashext.sh' -o -name '*bash_ext.sh' -o -name '*bash-ext.sh' \) -type f -printf '%H\t%p\n' 2>/dev/null
  )
  ((${#lines[@]})) && mapfile -t files < <(printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1 -k2 | cut -f2- | tr -d '\r')
  _cbl_concat "$out" "${files[@]}"
}

# _cbl_build_project <out> <project>: write a project's cache: every *.sh up to 4 levels deep
# in <project>/.claude/bash-ext, sorted by path. A project has no .env of its own.
_cbl_build_project() {
  local out="$1"
  local -a files=()
  : > "$out"
  mapfile -t files < <(find "$2/.claude/bash-ext/" -maxdepth 4 -name '*.sh' -type f 2>/dev/null | sort | tr -d '\r')
  _cbl_concat "$out" "${files[@]}"
}

# _cbl_clean_global: before a global build, delete this platform's older global caches, stale
# temp files, and project caches of earlier days. Only this platform's: WSL reaches the same
# root through /mnt/c, and deleting its cache would make it rebuild, which would delete this
# one in turn, a rebuild at every switch instead of one a day. Temp files are safe to delete:
# this runs under the lock both platforms share.
_cbl_clean_global() {
  local f
  local -a old=()
  for f in "$_cbl_root"/.env-cached-project-"$_cbl_platform"-*; do
    [[ -e $f && $f != *"-$_cbl_platform-$_cbl_day-"* ]] && old+=("$f")
  done
  rm -f "$_cbl_root"/.env-cached-"$_cbl_platform"-* "$_cbl_root"/.env-cache.tmp.* "${old[@]}" 2>/dev/null
}

# _cbl_clean_project <key>: before a project build, delete that project's older caches.
_cbl_clean_project() {
  rm -f "$_cbl_root"/.env-cached-project-"$_cbl_platform"-*-"$1" "$_cbl_root"/.env-cache.tmp.* 2>/dev/null
}

# _cbl_ensure <cache> <cleaner> <cleaner-arg> <builder> <builder-arg>: build <cache> when it is
# missing or ENV_SETUP_REBUILD=1. Under the lock, re-checked after waiting for it (another shell
# may have built it meanwhile); written to a temp file and moved into place, so no shell ever
# sources half a cache. A shell that could not get the lock waits up to ~5 s for the file.
_cbl_ensure() {
  local cache="$1" tmp t0 i
  [[ ${ENV_SETUP_REBUILD:-} == 1 || ! -f $cache ]] || return 0
  if _cbl_acquire_lock; then
    if [[ ${ENV_SETUP_REBUILD:-} == 1 || ! -f $cache ]]; then
      t0=${EPOCHREALTIME/.}
      tmp="$_cbl_root/.env-cache.tmp.$$"
      "$2" "$3"
      "$4" "$tmp" "$5"
      mv -f "$tmp" "$cache"
      attrib +H "$cache" 2>/dev/null   # Windows: hide it; elsewhere there is no such command
      _cbl_rebuild_ms=$(( _cbl_rebuild_ms + (${EPOCHREALTIME/.} - t0) / 1000 ))
    fi
    _cbl_release_lock
  fi
  if [[ ! -f $cache ]]; then
    for i in {1..50}; do [[ -f $cache ]] && break; sleep 0.1; done
  fi
}

_cbl_cache="$_cbl_root/.env-cached-$_cbl_platform-$_cbl_day"
_cbl_ensure "$_cbl_cache" _cbl_clean_global "" _cbl_build_global ""

_cbl_pcache=""
if [[ -n ${CLAUDE_BASH_LOADER_PROJECT:-} ]]; then
  _cbl_norm _cbl_project "$CLAUDE_BASH_LOADER_PROJECT"
  if [[ -d "$_cbl_project/.claude/bash-ext" ]]; then
    # The project's path, every character outside [A-Za-z0-9] as _, names its cache: unique
    # per project, no hashing process needed.
    _cbl_pkey="${_cbl_project//[^A-Za-z0-9]/_}"
    _cbl_pcache="$_cbl_root/.env-cached-project-$_cbl_platform-$_cbl_day-$_cbl_pkey"
    _cbl_ensure "$_cbl_pcache" _cbl_clean_project "$_cbl_pkey" _cbl_build_project "$_cbl_project"
  fi
fi

# Load at the top level, not inside a function: an extension's `declare` must stay global.
# `source`, not eval "$(tr -d '\r' < cache)": the build already removed every CR, and the
# command substitution cost a subshell, a tr process and a copy of the whole text on every start
# (~48 ms on Git Bash). bash reads a sourced file whole before running it, so a concurrent
# rebuild's mv cannot hand it half a cache.
[[ -n "${_cbl_perf_start:-}" ]] && _cbl_perf_load_start=${EPOCHREALTIME/.}
[[ -f "$_cbl_cache" ]] && source "$_cbl_cache"
[[ -n "$_cbl_pcache" && -f "$_cbl_pcache" ]] && source "$_cbl_pcache"
[[ -n "${_cbl_perf_start:-}" ]] && _cbl_perf_load_ms=$(( (${EPOCHREALTIME/.} - _cbl_perf_load_start) / 1000 ))
unset _SOURCE_DIR

# claude_bash_reload: rebuild this platform's caches now and load them into this shell. Run it
# after editing an extension or .env; otherwise new shells pick the edit up on the next UTC day.
# It remembers this file and the root it loaded from (a shim may have passed the root). Note:
# extensions are sourced inside this function then, so their plain top-level `declare` creates
# locals; an extension that needs a global array declares it with `declare -g`.
printf -v _cbl_q_self '%q' "${BASH_SOURCE[0]}"
printf -v _cbl_q_root '%q' "$_cbl_root"
eval "claude_bash_reload() { CLAUDE_BASH_LOADER_ROOT=$_cbl_q_root ENV_SETUP_REBUILD=1 ENV_SETUP_PERF=\"\${ENV_SETUP_PERF:-1}\" source $_cbl_q_self; }"

# Timing output, only when ENV_SETUP_PERF is set: "cache:" is the rebuild, "eval:" the load
# (the label of the earlier eval-based load, kept for anyone parsing it).
if [[ -n "${_cbl_perf_start:-}" ]]; then
  _cbl_perf_ms=$(( (${EPOCHREALTIME/.} - _cbl_perf_start) / 1000 ))
  _cbl_perf_detail=""
  [[ -n "${_cbl_parent_ms:-}" ]] && _cbl_perf_detail="parent:${_cbl_parent_ms}ms "
  (( _cbl_rebuild_ms > 0 )) && _cbl_perf_detail="${_cbl_perf_detail}cache:${_cbl_rebuild_ms}ms "
  [[ -n "${_cbl_perf_load_ms:-}" ]] && _cbl_perf_detail="${_cbl_perf_detail}eval:${_cbl_perf_load_ms}ms"
  [[ -n "$_cbl_perf_detail" ]] && _cbl_perf_detail=" (${_cbl_perf_detail% })"
  if [[ "${ENV_SETUP_PERF}" == "2" ]] && (( _cbl_perf_ms > ${ENV_SETUP_WARN_MS:-10} )); then
    echo "[env-setup] WARN: ${_cbl_perf_ms}ms${_cbl_perf_detail} (>${ENV_SETUP_WARN_MS:-10}ms)" >&2
  elif [[ "${ENV_SETUP_PERF}" == "1" ]]; then
    echo "[env-setup] ${_cbl_perf_ms}ms${_cbl_perf_detail}" >&2
  fi
fi

# Marker for scripts and hooks that check the environment was loaded.
export CLAUDE_BASH_ENV_LOADED=1

unset -f _cbl_norm _cbl_acquire_lock _cbl_release_lock _cbl_concat _cbl_build_global \
  _cbl_build_project _cbl_clean_global _cbl_clean_project _cbl_ensure
unset _cbl_perf_start _cbl_perf_load_start _cbl_perf_load_ms _cbl_perf_ms _cbl_perf_detail \
  _cbl_platform _cbl_root _cbl_day _cbl_lock _cbl_rebuild_ms _cbl_cache _cbl_pcache \
  _cbl_project _cbl_pkey _cbl_q_self _cbl_q_root _cbl_parent_ms _cbl_active
