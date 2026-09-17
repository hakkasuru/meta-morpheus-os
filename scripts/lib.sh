#!/usr/bin/env bash
# lib.sh — shared helpers for meta-morpheus-os scripts. bash 3.2; no side effects on source.
set -euo pipefail
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'error: %s is meant to be sourced, not executed\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

mm_root() { local r; r=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P) || mm_die "cannot resolve the repo root"; printf '%s\n' "$r"; }
mm_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
mm_usage_error() { printf 'error: %s\n' "$*" >&2; usage >&2; exit 2; }
mm_today() { date -u +%Y-%m-%d; }
mm_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mm_store() { printf '%s\n' "${MM_STORE:-$(mm_root)/experience}"; }
mm_sources_file() { printf '%s\n' "${MM_SOURCES:-$(mm_root)/config/sources.yaml}"; }

# mm_sources — "name<TAB>path" per entry of the sources: list.
mm_sources() {
  local f; f=$(mm_sources_file)
  [ -f "$f" ] || mm_die "sources file not found: $f — copy config/sources.example.yaml to config/sources.yaml and fill it in"
  awk '
{ sub(/\r$/, "") }   # a CRLF sources.yaml parses like an LF one
/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
/^[A-Za-z_]+:/ { section = $1; sub(/:$/, "", section); next }
section == "sources" && /^[[:space:]]*-[[:space:]]+name:/ { if (name != "") emit(); sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, ""); name = clean($0); path = ""; next }
section == "sources" && /^[[:space:]]+path:/ { sub(/^[[:space:]]+path:[[:space:]]*/, ""); path = clean($0); next }
# clean — strip a trailing comment, surrounding blanks (CR included) and ONE
# matching pair of single or double quotes.
function clean(v,   q) { sub(/[[:space:]]+#.*$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
  q = substr(v, 1, 1)
  if (length(v) >= 2 && (q == "\"" || q == "\047") && substr(v, length(v), 1) == q) v = substr(v, 2, length(v) - 2)
  return v }
function emit() { if (name != "" && path != "") print name "\t" path; else printf "warning: source \"%s\" has no path — skipped\n", name > "/dev/stderr" }
END { if (name != "") emit() }' "$f"
}

# mm_candidate <field> — scalar from the candidate: block (with defaults).
mm_candidate() {
  local f v; f=$(mm_sources_file)
  [ -f "$f" ] || mm_die "sources file not found: $f — copy config/sources.example.yaml to config/sources.yaml and fill it in"
  v=$(awk -v want="$1" '
{ sub(/\r$/, "") }   # a CRLF sources.yaml parses like an LF one
/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
/^[A-Za-z_]+:/ { section = $1; sub(/:$/, "", section); next }
section == "candidate" && $1 == want ":" { sub(/^[[:space:]]*[A-Za-z_]+:[[:space:]]*/, ""); print clean($0); exit }
# clean — same rules as mm_sources: trailing comment, surrounding blanks (CR
# included) and ONE matching pair of single or double quotes.
function clean(v,   q) { sub(/[[:space:]]+#.*$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
  q = substr(v, 1, 1)
  if (length(v) >= 2 && (q == "\"" || q == "\047") && substr(v, length(v), 1) == q) v = substr(v, 2, length(v) - 2)
  return v }' "$f")
  if [ -z "$v" ]; then
    case "$1" in
      default_branch) v=main ;;
      branch_prefix) v=proposal/ ;;
      host) v="" ;;
      git_name | git_email) v="" ;;   # optional: identity for proposal commits
      remote) mm_die "candidate.remote is not set in $f" ;;
    esac
  fi
  printf '%s\n' "$v"
}

# mm_host <remote> [explicit] — github|gitlab.
mm_host() {
  local remote="${1:-}" explicit="${2:-}"
  if [ -n "$explicit" ]; then
    case "$explicit" in github | gitlab) printf '%s\n' "$explicit"; return 0 ;; *) mm_die "candidate.host '$explicit' must be github or gitlab" ;; esac
  fi
  case "$remote" in
    *github.*) printf 'github\n' ;;
    *gitlab.*) printf 'gitlab\n' ;;
    *) mm_die "cannot detect host for remote '$remote' — set candidate.host: github|gitlab in $(mm_sources_file)" ;;
  esac
}

mm_frontmatter_field() {
  [ -f "${1:-}" ] || return 1
  awk -v want="$2" '
NR == 1 { if ($0 !~ /^---[ \t\r]*$/) exit 1; next }
/^---[ \t\r]*$/ { exit (found ? 0 : 1) }
index($0, want ":") == 1 { v = substr($0, length(want) + 2); sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t\r]+$/, "", v); gsub(/^"|"$/, "", v); print v; found = 1; exit 0 }
END { exit (found ? 0 : 1) }' "$1"
}

mm_frontmatter_set() {
  [ $# -eq 3 ] || mm_die "mm_frontmatter_set: need <file> <field> <value>"
  local file="$1" want="$2" val="$3" tmp="$1.tmp.$$"
  [ -f "$file" ] || mm_die "mm_frontmatter_set: no such file: $file"
  if ! val="$val" awk -v want="$want" 'BEGIN { val = ENVIRON["val"] }
NR == 1 { print; if ($0 !~ /^---[ \t\r]*$/) bad = 1; next }
bad { print; next }
!closed && /^---[ \t\r]*$/ { if (!done) { print want ": " val; done = 1 }; closed = 1; print; next }
!closed && index($0, want ":") == 1 { if (!done) { print want ": " val; done = 1 }; next }
{ print }
END { if (bad || !closed) exit 1 }' "$file" >"$tmp"; then rm -f "$tmp"; mm_die "mm_frontmatter_set: $file has no frontmatter block"; fi
  mv "$tmp" "$file"
}

# mm_validate_proposal <file> — the proposal note contract (spec §6.4):
# required frontmatter fields, a legal status, the five sections, >= 3
# evidence lines, and the pr/harness_after/measured requirements implied by
# status. Prints "error: <file>: <message>" lines to stderr for each
# violation found; returns 0 when the note is clean, 1 otherwise. Never
# exits — callers (validate.sh workspace mode, candidate.sh pr) decide what
# a failure means for them.
mm_validate_proposal() {
  local f="$1" field status sec n pr ha me bad=0
  for field in title status created updated workspaces harness_before metric prediction harness_after measured pr; do
    mm_frontmatter_field "$f" "$field" >/dev/null 2>&1 || { printf "error: %s: missing frontmatter field '%s'\n" "$f" "$field" >&2; bad=1; }
  done
  status=$(mm_frontmatter_field "$f" status 2>/dev/null || printf '')
  case "$status" in
    proposed | implemented | measured | kept | reverted | withdrawn) : ;;
    *) printf "error: %s: illegal status '%s'\n" "$f" "$status" >&2; bad=1 ;;
  esac
  for sec in '## Evidence' '## Diagnosis' '## Proposal' '## Risk and rollback' '## Measurement'; do
    grep -q "^$sec" "$f" || { printf "error: %s: missing section '%s'\n" "$f" "$sec" >&2; bad=1; }
  done
  n=$(grep -Ec '^- [A-Za-z0-9._-]+/[^ ]+:[0-9]+ — ' "$f" || true)
  [ "${n:-0}" -ge 3 ] || { printf 'error: %s: at least 3 evidence lines required (got %s)\n' "$f" "${n:-0}" >&2; bad=1; }
  case "$status" in
    implemented | measured | kept | reverted)
      pr=$(mm_frontmatter_field "$f" pr 2>/dev/null || printf '')
      { [ -n "$pr" ] && [ "$pr" != null ]; } || { printf 'error: %s: %s requires pr (non-null)\n' "$f" "$status" >&2; bad=1; }
      ;;
  esac
  case "$status" in
    measured | kept | reverted)
      ha=$(mm_frontmatter_field "$f" harness_after 2>/dev/null || printf '')
      { [ -n "$ha" ] && [ "$ha" != null ]; } || { printf 'error: %s: %s requires harness_after (non-null)\n' "$f" "$status" >&2; bad=1; }
      me=$(mm_frontmatter_field "$f" measured 2>/dev/null || printf '')
      { [ -n "$me" ] && [ "$me" != null ]; } || { printf 'error: %s: %s requires measured (non-null)\n' "$f" "$status" >&2; bad=1; }
      ;;
  esac
  [ "$bad" -eq 0 ]
}

# mm_latest <ws-dir> scorecard|summary — newest snapshot path, or nothing at
# all when the workspace has no such snapshot yet (an export interrupted
# between the manifest and the snapshots leaves exactly that). ALWAYS returns
# 0: callers assign it in `f=$(mm_latest …)` under `set -e`, where a non-zero
# status would abort before their own `[ -n "$f" ] || continue` guard runs.
mm_latest() {
  # shellcheck disable=SC2012 # filenames are our own fixed <prefix>-<UTC-stamp>.tsv, never non-alphanumeric; ls sorts on the name, not stat metadata
  ls "$1"/"$2"-*.tsv 2>/dev/null | LC_ALL=C sort | tail -1 || true
}

# mm_json_escape — stdin → one JSON string body (no surrounding quotes).
mm_json_escape() {
  # Character loop instead of gsub: backslash handling in gsub replacement
  # strings differs between awk dialects (busybox drops one backslash).
  awk 'BEGIN { ORS = "" }
  {
    line = $0; out = ""; n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (c == "\\") out = out "\\\\"
      else if (c == "\"") out = out "\\\""
      else if (c == "\t") out = out "\\t"
      else if (c == "\r") out = out "\\r"
      else out = out c
    }
    if (NR > 1) print "\\n"
    print out
  }'
}
