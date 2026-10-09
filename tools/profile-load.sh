#!/usr/bin/env bash
# profile-load.sh - where does a bash-loader cache's load time go, file by file?
#
# Usage: bash tools/profile-load.sh [cache-file] [rounds]
#   cache-file  default: the newest global cache in ${CLAUDE_CONFIG_DIR:-~/.claude}
#   rounds      default 5; each round runs in a fresh bash, the table shows the median
#
# The cache is split at its _SOURCE_DIR= lines into one segment per extension file. In one
# clean bash (no BASH_ENV) each segment is first parsed only (wrapped in a function body and
# eval'd, so none of it runs), then sourced for real (parse + top-level code), in load order, so
# a file sees what the files before it defined. "run" = source - parse: the time its top-level
# code takes. Above ~1 ms usually means it starts a process ($(...), date, dirname, ...), which
# costs every bash start ~15-25 ms on Git Bash. Reads only; writes to a temporary folder.

set -u
ROOT="${CLAUDE_BASH_LOADER_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
ROOT="${ROOT//\\//}"
CACHE="${1:-}"
ROUNDS="${2:-5}"
if [[ -z $CACHE ]]; then
  # Newest global cache (project caches carry "-project-" in their name).
  for f in "$ROOT"/.env-cached-*; do
    [[ -f $f && $f != *-project-* ]] || continue
    [[ -z $CACHE || $f -nt $CACHE ]] && CACHE="$f"
  done
fi
[[ -n $CACHE && -f $CACHE ]] || { echo "no cache found in $ROOT (start a bash with the loader first)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/seg"
# Segment 000 is the .env exports before the first header; each header starts the next one.
gawk -v dir="$TMP/seg" 'BEGIN { f = sprintf("%s/%03d.sh", dir, 0) }
  /^_SOURCE_DIR="/ { n++; f = sprintf("%s/%03d.sh", dir, n) }
  { print > f }' "$CACHE"

for ((r = 1; r <= ROUNDS; r++)); do
  env -u BASH_ENV bash --noprofile --norc -c '
    for seg in "$1"/seg/*.sh; do
      body=$(< "$seg")
      t0=${EPOCHREALTIME/./}
      eval "__profile_parse_only() {
$body
:
}" 2>/dev/null
      t1=${EPOCHREALTIME/./}
      source "$seg" >/dev/null 2>&1
      t2=${EPOCHREALTIME/./}
      echo "${seg##*/} $((t1 - t0)) $((t2 - t1))"
    done' _ "$TMP" > "$TMP/round-$r.txt"
done

# Median per segment, with the file's folder, line count and first function, slowest first.
gawk -v rounds="$ROUNDS" -v dir="$TMP/seg" -v root="$ROOT/" '
  function median(list, n,   i, j, t, a) {
    split(list, a, " "); n = length(a)
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
    return a[int((n + 1) / 2)]
  }
  { parse[$1] = parse[$1] " " $2; src[$1] = src[$1] " " $3 }
  END {
    for (s in src) {
      p = median(parse[s]); t = median(src[s]); path = dir "/" s
      where = ".env"; fn = "-"; lines = 0
      while ((getline line < path) > 0) {
        lines++
        if (line ~ /^_SOURCE_DIR="/) { where = line; sub(/^_SOURCE_DIR="/, "", where); sub(/"$/, "", where); sub(root, "", where) }
        if (fn == "-" && match(line, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:-]*[ \t]*\(\)/)) {
          fn = substr(line, RSTART, RLENGTH); sub(/^[ \t]*(function[ \t]+)?/, "", fn); sub(/[ \t]*\(\)$/, "", fn)
        }
      }
      close(path)
      printf "%9.1f %8.1f %8.1f %6d  %s / %s\n", t / 1000, p / 1000, (t - p) / 1000, lines, where, fn
      total += t; totalp += p
    }
    printf "TOTAL %9.1f %8.1f %8.1f\n", total / 1000, totalp / 1000, (total - totalp) / 1000 > "/dev/stderr"
  }' "$TMP"/round-*.txt 2> "$TMP/total.txt" | sort -rn > "$TMP/table.txt"

printf 'cache: %s (%s bytes), median of %s runs\n\n' "$CACHE" "$(wc -c < "$CACHE")" "$ROUNDS"
printf '%9s %8s %8s %6s  %s\n' "load ms" "parse" "run" "lines" "folder / first function"
cat "$TMP/table.txt"
printf '%s\n' "-------------------------------------------------------------"
cat "$TMP/total.txt"
