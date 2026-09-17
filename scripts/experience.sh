#!/usr/bin/env bash
# experience.sh — the experience store: pull exports from registered workspaces
# (sync) and query them (read-only). Store layout v1 is written by the
# template's scripts/export-experience.sh.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: experience.sh [--store <dir>] [--sources <file>] <subcommand> [args]

  sync [<source> ...]           run each registered workspace's exporter into the store
  status [--hook claude|copilot] sources + last sync, harness versions, proposals by status
  versions                      harness versions present: items, workspaces, date range
  list [--workspace <ws>] [--harness <stamp|semver>] [--gaps] [--since <YYYY-MM-DD>]
                                docs_missing shows gate-doc gaps only; `source`
                                says events (recorded) or legacy (reconstructed)
  show <id>                     one item: scorecard row, events.log, trace files
  grep <ERE> [--in docs|events|briefs|reports|raw|sessions|all] [--workspace <ws>] [<id> ...]
  summary [--workspace <ws>]    latest summary snapshot per workspace; changes_requested,
                                blocked, corrections and reverted are EVENT counts, each
                                followed by items_cr/items_blocked/items_corr/items_rev,
                                the number of items contributing to it
  diff <harness-A> <harness-B>  summary metrics for two versions and their deltas

Store: --store, else $MM_STORE, else <repo>/experience. Sources: --sources,
else $MM_SOURCES, else <repo>/config/sources.yaml. Only sync writes.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --store) [ $# -ge 2 ] || mm_usage_error "--store requires a directory"; export MM_STORE="$2"; shift ;;
    --sources) [ $# -ge 2 ] || mm_usage_error "--sources requires a file"; export MM_SOURCES="$2"; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) mm_usage_error "unknown option: $1" ;;
    *) break ;;
  esac
  shift
done
[ $# -ge 1 ] || mm_usage_error "missing subcommand"
cmd="$1"; shift
store=$(mm_store)

# workspaces — store subfolders that have a manifest. Consumers read it line
# by line (`while IFS= read -r`), never `for ws in $(workspaces)`: a workspace
# directory name may contain spaces or glob characters.
workspaces() { local d; for d in "$store"/*/; do [ -f "$d/manifest.tsv" ] && basename "$d"; done; return 0; }
# ws_of <id> — workspace holding the item (first match).
ws_of() {
  local ws found=""
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    if [ -d "$store/$ws/items/$1" ]; then found="$ws"; break; fi
  done <<EOF
$(workspaces)
EOF
  [ -n "$found" ] || mm_die "no item '$1' in the store"
  printf '%s\n' "$found"
}
# latest_rows — every workspace's latest scorecard rows, prefixed by "ws<TAB>"
# (header dropped), JOINED to that workspace's manifest: the exported set is
# the evaluation set (spec §6.2). The template's scorecard covers every item
# under work/ while the exporter copies only work/done/, so an unjoined row
# would count never-started items as items with zero friction.
latest_rows() {
  local ws f
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    f=$(mm_latest "$store/$ws" scorecard); [ -n "$f" ] || continue
    awk -F'\t' -v OFS='\t' -v ws="$ws" '
NR == FNR { if (FNR > 1) exported[$1] = 1; next }
FNR > 1 && ($1 in exported) { print ws, $0 }' "$store/$ws/manifest.tsv" "$f"
  done <<EOF
$(workspaces)
EOF
}
# Column indices below are the template HEADER shifted by one (col 1 = workspace):
# 4 harness, 7 status, 8 created, 10 lead_h, 11 g1_rounds, 14 g1_by, 17 g2_rounds,
# 20 g2_by, 23 changes_requested, 24 blocked, 25 corrections, 34 reverted,
# 35 docs_missing, 42 source.

# The awk helpers below are shared, verbatim, by every query that reads a
# scorecard row:
#   gate_gaps(v)  docs_missing with the `events` and `harness` tokens dropped.
#                 Those two say the item predates the run record (source
#                 legacy), not that a gate was skipped; items_with_gaps has
#                 always ignored them, so the displayed column now agrees
#                 with the count. The store's raw column is untouched.
#   nonzero(v)    a scorecard cell that carries a real, non-zero value —
#                 "-", "", "0" and "no" are all "nothing happened".
AWK_ROW_HELPERS='
function gate_gaps(v,   n, i, a, out) {
  if (v == "" || v == "-") return "-"
  n = split(v, a, /[, ]+/); out = ""
  for (i = 1; i <= n; i++) if (a[i] != "events" && a[i] != "harness" && a[i] != "") out = (out == "" ? a[i] : out "," a[i])
  return (out == "" ? "-" : out)
}
function nonzero(v) { return (v != "" && v != "-" && v != "0" && v != "no") }
'

cmd_versions() {
  printf 'harness\titems\tworkspaces\tfirst_created\tlast_created\n'
  latest_rows | awk -F'\t' -v OFS='\t' '
{ h = $4; n[h]++; if (!(h SUBSEP $1 in seen)) { seen[h SUBSEP $1] = 1; w[h] = (w[h] == "" ? $1 : w[h] "," $1) }
  d = substr($8, 1, 10)
  if (first[h] == "" || d < first[h]) first[h] = d; if (d > last[h]) last[h] = d }
END { for (h in n) print h, n[h], w[h], first[h], last[h] }' | LC_ALL=C sort
}

cmd_list() {
  local ws="" harness="" gaps=no since=""
  while [ $# -gt 0 ]; do case "$1" in
    --workspace) [ $# -ge 2 ] || mm_usage_error "list: --workspace requires a value"; ws="$2"; shift ;;
    --harness) [ $# -ge 2 ] || mm_usage_error "list: --harness requires a value"; harness="$2"; shift ;;
    --gaps) gaps=yes ;;
    --since) [ $# -ge 2 ] || mm_usage_error "list: --since requires a YYYY-MM-DD date"; since="$2"; shift ;;
    *) mm_usage_error "list: unknown argument $1" ;; esac; shift; done
  printf 'workspace\tid\tharness\tstatus\tg1_rounds\tg2_rounds\tchanges_requested\tblocked\tcorrections\treverted\tdocs_missing\tsource\tlead_h\n'
  latest_rows | awk -F'\t' -v OFS='\t' -v ws="$ws" -v h="$harness" -v gaps="$gaps" -v since="$since" "$AWK_ROW_HELPERS"'
ws != "" && $1 != ws { next }
h != "" && $4 != h && index($4, h "+") != 1 { next }
gaps == "yes" && $35 !~ /(plan-review|impl-review|verification|diff-review)/ { next }
since != "" && $8 < since { next }
{ print $1, $2, $4, $7, $11, $17, $23, $24, $25, $34, gate_gaps($35), ($42 == "" ? "-" : $42), $10 }' | LC_ALL=C sort
}

cmd_show() {
  [ $# -eq 1 ] || mm_usage_error "show needs exactly one <id>"
  local id="$1" ws f
  ws=$(ws_of "$id"); f=$(mm_latest "$store/$ws" scorecard)
  printf 'workspace: %s\n' "$ws"
  # docs_missing is shown as gate-doc gaps only; `source` right above it says
  # whether the row was recorded or reconstructed, which is what the dropped
  # `events`/`harness` tokens actually meant.
  [ -n "$f" ] && awk -F'\t' -v id="$id" "$AWK_ROW_HELPERS"'NR == 1 { for (i = 1; i <= NF; i++) h[i] = $i; next }
$1 == id { for (i = 1; i <= NF; i++) print h[i] ": " (h[i] == "docs_missing" ? gate_gaps($i) : $i) }' "$f"
  if [ -f "$store/$ws/items/$id/events.log" ]; then printf -- '--- events.log\n'; cut -f2- "$store/$ws/items/$id/events.log"; fi
  printf -- '--- trace files\n'
  [ -d "$store/$ws/items/$id/trace" ] && find "$store/$ws/items/$id/trace" -type f | LC_ALL=C sort | while IFS= read -r p; do printf '%s\t%s\n' "$(wc -c <"$p" | tr -d ' ')" "${p#"$store/$ws/items/$id/"}"; done
  return 0
}

cmd_grep() {
  [ $# -ge 1 ] || mm_usage_error "grep needs an <ERE>"
  local ere="$1" layer=all ws="" ids="" ws2 id paths; shift
  while [ $# -gt 0 ]; do case "$1" in
    --in) [ $# -ge 2 ] || mm_usage_error "grep: --in requires docs|events|briefs|reports|raw|sessions|all"; layer="$2"; shift ;;
    --workspace) [ $# -ge 2 ] || mm_usage_error "grep: --workspace requires a value"; ws="$2"; shift ;;
    -*) mm_usage_error "grep: unknown option $1" ;; *) ids="$ids $1" ;; esac; shift; done
  while IFS= read -r ws2; do
    [ -n "$ws2" ] || continue
    [ -z "$ws" ] || [ "$ws2" = "$ws" ] || continue
    if [ "$layer" = sessions ] || [ "$layer" = all ]; then
      if [ -d "$store/$ws2/sessions" ]; then
        grep -rIEn -- "$ere" "$store/$ws2/sessions" 2>/dev/null | while IFS= read -r line; do printf '%s\n' "${line#"$store/"}"; done || true
      fi
    fi
    [ "$layer" = sessions ] && continue
    for id in ${ids:-$(ls "$store/$ws2/items" 2>/dev/null)}; do
      [ -d "$store/$ws2/items/$id" ] || continue
      case "$layer" in
        docs) paths=$(find "$store/$ws2/items/$id" -maxdepth 1 -type f -name '*.md') ;;
        events) paths="$store/$ws2/items/$id/events.log" ;;
        briefs | reports | raw) paths="$store/$ws2/items/$id/trace/$layer" ;;
        all) paths="$store/$ws2/items/$id" ;;
        *) mm_usage_error "grep --in must be docs|events|briefs|reports|raw|sessions|all" ;;
      esac
      [ -n "$paths" ] || continue
      printf '%s\n' "$paths" | while IFS= read -r p; do [ -e "$p" ] && grep -rIEn -- "$ere" "$p" 2>/dev/null; done \
        | while IFS= read -r line; do printf '%s\n' "$ws2/$id:${line#"$store/$ws2/items/$id/"}"; done || true
    done
  done <<EOF
$(workspaces)
EOF
  return 0
}

# item_counts — "ws<TAB>harness<TAB>items_cr<TAB>items_blocked<TAB>items_corr<TAB>items_rev",
# one line per workspace/harness: how many ITEMS carry a non-zero value in
# each column the summary snapshot reports as a sum of EVENTS over items.
# Counted over the same manifest-joined rows every other query uses.
item_counts() {
  latest_rows | awk -F'\t' -v OFS='\t' "$AWK_ROW_HELPERS"'
{ k = $1 SUBSEP $4; ws[k] = $1; hv[k] = $4
  if (nonzero($23)) cr[k]++; if (nonzero($24)) bl[k]++; if (nonzero($25)) co[k]++; if (nonzero($34)) rv[k]++ }
END { for (k in ws) print ws[k], hv[k], cr[k] + 0, bl[k] + 0, co[k] + 0, rv[k] + 0 }'
}

cmd_summary() {
  local ws="" ws2 f counts
  while [ $# -gt 0 ]; do case "$1" in
    --workspace) [ $# -ge 2 ] || mm_usage_error "summary: --workspace requires a value"; ws="$2"; shift ;;
    *) mm_usage_error "summary: unknown argument $1" ;;
  esac; shift; done
  # changes_requested/blocked/corrections/reverted are EVENT counts summed over
  # items; each is followed by its item count (how many items contributed), so
  # a signal concentrated in one item cannot read as a broad one.
  printf 'workspace\tharness\titems\tauto_approve_rate\tmean_g1_rounds\tmean_g2_rounds\tchanges_requested\titems_cr\tblocked\titems_blocked\tcorrections\titems_corr\treverted\titems_rev\titems_with_gaps\tmean_lead_h\n'
  counts=$(item_counts)
  while IFS= read -r ws2; do
    [ -n "$ws2" ] || continue
    [ -z "$ws" ] || [ "$ws2" = "$ws" ] || continue
    f=$(mm_latest "$store/$ws2" summary); [ -n "$f" ] || continue
    # counts travels through the environment, not -v: awk's -v runs escape
    # processing on the value and BWK awk rejects the embedded newlines.
    counts="$counts" awk -F'\t' -v OFS='\t' -v ws="$ws2" '
BEGIN { icr[""] = 0; ibl[""] = 0; ico[""] = 0; irv[""] = 0   # make them arrays even when counts is empty
  n = split(ENVIRON["counts"], L, "\n")
  for (i = 1; i <= n; i++) { split(L[i], c, "\t"); if (c[1] == ws) { icr[c[2]] = c[3]; ibl[c[2]] = c[4]; ico[c[2]] = c[5]; irv[c[2]] = c[6] } } }
function got(a, h) { return (h in a) ? a[h] : 0 }
NR > 1 { print ws, $1, $2, $3, $4, $5, $6, got(icr, $1), $7, got(ibl, $1), $8, got(ico, $1), $9, got(irv, $1), $10, $11 }' "$f"
  done <<EOF
$(workspaces)
EOF
}

# summary_metrics <ere-on-harness> — "metric<TAB>value" lines over latest rows matching the harness
# (per workspace prefixed "ws<TAB>", plus "all<TAB>").
summary_metrics() {
  latest_rows | awk -F'\t' -v OFS='\t' -v want="$1" "$AWK_ROW_HELPERS"'
function num(v) { return (v ~ /^-?[0-9.]+$/) ? v + 0 : 0 } function isnum(v) { return v ~ /^-?[0-9.]+$/ }
$4 != want && index($4, want "+") != 1 { next }
{ for (k = 1; k <= 2; k++) { s = (k == 1 ? $1 : "all")
    n[s]++; if ($14 != "-") { appr[s]++; if ($14 == "auto") auto[s]++ } if ($20 != "-") { appr[s]++; if ($20 == "auto") auto[s]++ }
    if (isnum($11)) { g1[s] += $11; g1n[s]++ } if (isnum($17)) { g2[s] += $17; g2n[s]++ }
    cr[s] += num($23); bl[s] += num($24); co[s] += num($25); if ($34 == "yes") rv[s]++
    if (nonzero($23)) icr[s]++; if (nonzero($24)) ibl[s]++; if (nonzero($25)) ico[s]++; if (nonzero($34)) irv[s]++
    if ($35 ~ /(plan-review|impl-review|verification|diff-review)/) gaps[s]++
    if (isnum($10)) { lead[s] += $10; leadn[s]++ } } }
END { for (s in n) {
  print s, "items", n[s]; print s, "auto_approve_rate", (appr[s] ? sprintf("%.2f", auto[s] / appr[s]) : "-")
  print s, "mean_g1_rounds", (g1n[s] ? sprintf("%.1f", g1[s] / g1n[s]) : "-"); print s, "mean_g2_rounds", (g2n[s] ? sprintf("%.1f", g2[s] / g2n[s]) : "-")
  print s, "changes_requested", cr[s] + 0; print s, "items_cr", icr[s] + 0
  print s, "blocked", bl[s] + 0; print s, "items_blocked", ibl[s] + 0
  print s, "corrections", co[s] + 0; print s, "items_corr", ico[s] + 0
  print s, "reverted", rv[s] + 0; print s, "items_rev", irv[s] + 0
  print s, "items_with_gaps", gaps[s] + 0; print s, "mean_lead_h", (leadn[s] ? sprintf("%.1f", lead[s] / leadn[s]) : "-") } }'
}

cmd_diff() {
  [ $# -eq 2 ] || mm_usage_error "diff needs <harness-A> <harness-B>"
  local a="$1" b="$2"
  printf 'scope\tmetric\t%s\t%s\tdelta\n' "$a" "$b"
  { summary_metrics "$a" | sed $'s/^/A\t/'; summary_metrics "$b" | sed $'s/^/B\t/'; } | awk -F'\t' -v OFS='\t' '
{ key = $2 SUBSEP $3; scopes[$2] = 1; metrics[$3] = 1; v[$1 SUBSEP key] = $4 }
END {
  order = "items auto_approve_rate mean_g1_rounds mean_g2_rounds changes_requested items_cr blocked items_blocked corrections items_corr reverted items_rev items_with_gaps mean_lead_h"
  nm = split(order, m, " ")
  for (s in scopes) for (i = 1; i <= nm; i++) { key = s SUBSEP m[i]; av = ("A" SUBSEP key in v) ? v["A" SUBSEP key] : "-"; bv = ("B" SUBSEP key in v) ? v["B" SUBSEP key] : "-"
    if (av ~ /^-?[0-9.]+$/ && bv ~ /^-?[0-9.]+$/) { d = bv - av; d = (d > 0 ? "+" : "") (index(av bv, ".") ? sprintf("%.1f", d) : sprintf("%d", d)) } else d = "-"
    print s, m[i], av, bv, d } }' | LC_ALL=C sort -t '	' -k1,1 -k2,2
}

cmd_status() {
  local hook="" name path last ex stale body
  while [ $# -gt 0 ]; do case "$1" in
    --hook) [ $# -ge 2 ] || mm_usage_error "--hook requires claude|copilot"; hook="$2"; shift ;;
    *) mm_usage_error "status: unknown argument $1" ;;
  esac; shift; done
  body=$(
    printf 'sources:\n'
    mm_sources | while IFS='	' read -r name path; do
      if [ -f "$store/$name/sync.tsv" ]; then last=$(tail -1 "$store/$name/sync.tsv" | cut -f1); ex=$(tail -1 "$store/$name/sync.tsv" | cut -f2)
        stale=""; [ -d "$path/work/done" ] && [ -n "$(find "$path/work/done" -type f -name task.md -newer "$store/$name/sync.tsv" 2>/dev/null | head -1)" ] && stale=" (stale: newer done items)"
        printf '%s\t%s\tlast sync %s exit %s%s\n' "$name" "$path" "$last" "$ex" "$stale"
      else printf '%s\t%s\tnever synced\n' "$name" "$path"; fi
    done
    printf '\nharness versions:\n'; cmd_versions | tail -n +2
    printf '\nproposals:\n'
    # Grouped with a trailing `true` (same convention as workspaces()'s
    # `return 0`): under set -o pipefail, an unmatched proposals/*.md glob
    # leaves the for loop's last exit status at the failing `[ -f "$f" ]`,
    # which would otherwise fail the whole pipeline and abort the script.
    { for f in "$(mm_root)"/proposals/*.md; do [ -f "$f" ] && [ "$(basename "$f")" != README.md ] && printf '%s\t%s\n' "$(mm_frontmatter_field "$f" status || echo '?')" "$(basename "$f")"; done; true; } | LC_ALL=C sort | awk -F'\t' '{ c[$1]++; l[$1] = l[$1] " " $2; n++ } END { for (s in c) print s "\t" c[s] "\t" l[s]; if (!n) print "(none)" }'
  )
  case "$hook" in
    '') printf '%s\n' "$body" ;;
    claude) printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$(printf 'meta-morpheus-os status (scripts/experience.sh status, read-only). Relay to the human, then continue.\n\n%s\n' "$body" | mm_json_escape)" ;;
    copilot) printf '{"additionalContext":"%s"}\n' "$(printf '%s\n' "$body" | mm_json_escape)" ;;
    *) mm_usage_error "status --hook expects claude or copilot" ;;
  esac
}

cmd_sync() {
  local only="$*" name path exporter out rc failed=0 ran=0
  mkdir -p "$store"
  while IFS='	' read -r name path; do
    [ -n "$name" ] || continue
    [ -z "$only" ] || case " $only " in *" $name "*) : ;; *) continue ;; esac
    ran=$((ran + 1)); exporter="$path/scripts/export-experience.sh"
    # The name becomes a directory under the store: reject anything that could
    # escape it (path separators, traversal) BEFORE creating a single file.
    case "$name" in
      . | .. | *[!A-Za-z0-9._-]*)
        printf 'error: %s: source name must match [A-Za-z0-9._-]+ (and not "." or "..") — skipped\n' "$name" >&2
        failed=$((failed + 1)); continue ;;
    esac
    mkdir -p "$store/$name"
    [ -f "$store/$name/sync.tsv" ] || printf 'last_sync\texit\tsummary\n' >"$store/$name/sync.tsv"
    if [ ! -x "$exporter" ]; then
      printf 'error: %s: no %s — update that workspace'"'"'s harness (morpheus-os >= 1.1.0)\n' "$name" "$exporter" >&2
      printf '%s\t%s\t%s\n' "$(mm_now_iso)" 2 "exporter missing" >>"$store/$name/sync.tsv"; failed=$((failed + 1)); continue
    fi
    rc=0; out=$("$exporter" --dest "$store" --workspace-name "$name" 2>&1) || rc=$?
    printf '%s\t%s\t%s\n' "$(mm_now_iso)" "$rc" "$(printf '%s' "$out" | tail -1 | tr '\t' ' ')" >>"$store/$name/sync.tsv"
    printf '%s: %s\n' "$name" "$(printf '%s' "$out" | tail -1)"
    [ "$rc" -eq 0 ] || { failed=$((failed + 1)); printf '%s\n' "$out" >&2; }
  done <<EOF
$(mm_sources)
EOF
  [ "$ran" -gt 0 ] || mm_die "no matching sources in $(mm_sources_file)"
  [ "$failed" -eq 0 ] || exit 1
}

case "$cmd" in
  versions) cmd_versions "$@" ;;
  list) cmd_list "$@" ;;
  show) cmd_show "$@" ;;
  grep) cmd_grep "$@" ;;
  summary) cmd_summary "$@" ;;
  diff) cmd_diff "$@" ;;
  status) cmd_status "$@" ;;
  sync) cmd_sync "$@" ;;
  *) mm_usage_error "unknown subcommand '$cmd'" ;;
esac
