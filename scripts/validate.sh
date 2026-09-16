#!/usr/bin/env bash
# validate.sh — structural checks over this workspace, plus a --self-check
# harness that exercises scripts/lib.sh and friends against the fixture
# store under scripts/fixtures/store/ (never touches config/sources.yaml or
# any real workspace).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: validate.sh [--self-check]

Default (workspace mode): check this workspace for structural mistakes —
  config/sources.yaml   parses via mm_sources, when present
  <store>/*/manifest.tsv  has exactly the 10-column store manifest header
                        (store: $MM_STORE, default experience/)
  proposals/*.md        (except README.md) satisfy the proposal note
                        contract: frontmatter fields, legal status, the
                        five sections, >= 3 evidence lines, and the
                        pr/harness_after/measured requirements per status

Errors print to stderr and exit 1.

Options:
  -h, --help     show this help
  --self-check   run this harness's own self-check instead of the
                 workspace: scripts/lib.sh and friends, exercised against
                 the fixture store (scripts/fixtures/store/) in a throwaway
                 copy. Never touches config/sources.yaml.
EOF
}

mode=workspace
case "${1:-}" in
  '') : ;;
  --self-check) mode=self-check ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) mm_usage_error "unexpected argument: $1" ;;
esac
[ $# -le 1 ] || mm_usage_error "validate.sh takes at most one option"

root=$(mm_root)
errors=0
checks=0

v_error() {
  printf 'error: %s\n' "$*" >&2
  errors=$((errors + 1))
}

check() {
  checks=$((checks + 1))
}

MANIFEST_HEADER='id	type	status	harness	parent	source_path	exported_at	sessions_copied	sessions_missing	store_version'

# --- self-check helpers (assertions against the fixture store) -------------

sc_failed=0

sc_fail() {
  printf 'self-check: FAIL — %s\n' "$*" >&2
  sc_failed=1
}

sc_eq() {
  check
  [ "$1" = "$2" ] || sc_fail "$3: expected '$2', got '$1'"
}

sc_file() {
  check
  [ -f "$1" ] || sc_fail "expected file: $1"
}

# sc_grep <file> <ere> — the file exists and matches the ERE.
sc_grep() {
  check
  grep -Eq -- "$2" "$1" 2>/dev/null || sc_fail "expected /$2/ in $1"
}

# sc_grep_str <string> <ere> <label> — the string matches the ERE.
sc_grep_str() {
  check
  printf '%s' "$1" | grep -Eq -- "$2" || sc_fail "$3: expected /$2/, got: $1"
}

# sc_workspace — build a throwaway copy of scripts/ + config/ (so tests
# never touch the real config/sources.yaml), plus a throwaway copy of the
# fixture store with __STORE__ substituted, and export MM_STORE at it.
# Sets $SC (throwaway root) and $SC_TEMPLATE (the template checkout, when
# MM_TEMPLATE_PATH or ./candidate has scripts/validate.sh — else empty).
sc_workspace() {
  SC=$(mktemp -d "${TMPDIR:-/tmp}/mm-selfcheck.XXXXXX")
  SC=$(cd "$SC" && pwd -P)
  trap 'rm -rf "$SC"' EXIT
  mkdir -p "$SC/repo/config" "$SC/store"
  cp -R "$root/scripts" "$SC/repo/"
  cp "$root/config/sources.example.yaml" "$SC/repo/config/"
  cp -R "$root/scripts/fixtures/store/." "$SC/store/"
  find "$SC/store" -name sessions.tsv | while IFS= read -r f; do
    sed "s|__STORE__|$SC/store|g" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  done
  export MM_STORE="$SC/store"
  SC_TEMPLATE="${MM_TEMPLATE_PATH:-$root/candidate}"
  [ -f "$SC_TEMPLATE/scripts/validate.sh" ] || SC_TEMPLATE=""
}

# run_self_check — the self-check assertion blocks. Append new blocks ABOVE
# the trailing bare `:` — see the note there for why it must stay last.
run_self_check() {
  sc_workspace
  local out rc

  # --- lib.sh (Task 1) ---
  out=$(cd "$SC/repo" && bash -c '. scripts/lib.sh; MM_SOURCES=config/sources.example.yaml mm_sources')
  sc_eq "$out" "my-workspace	/absolute/path/to/my-morpheus-os" "mm_sources parses the example"
  out=$(cd "$SC/repo" && bash -c '. scripts/lib.sh; MM_SOURCES=config/sources.example.yaml mm_candidate remote')
  sc_eq "$out" "git@github.com:you/morpheus-os.git" "mm_candidate remote"
  out=$(cd "$SC/repo" && bash -c '. scripts/lib.sh; MM_SOURCES=config/sources.example.yaml mm_candidate branch_prefix')
  sc_eq "$out" "proposal/" "mm_candidate branch_prefix"
  out=$(cd "$SC/repo" && bash -c '. scripts/lib.sh; MM_SOURCES=config/sources.example.yaml mm_candidate host')
  sc_eq "$out" "" "mm_candidate host unset (commented out)"
  out=$(cd "$SC/repo" && bash -c '. scripts/lib.sh; mm_host ssh://git@gitlab.example.internal:1234/g/r.git')
  sc_eq "$out" gitlab "mm_host detects gitlab"
  out=$(cd "$SC/repo" && bash -c '. scripts/lib.sh; mm_host https://code.example.internal/g/r.git github')
  sc_eq "$out" github "mm_host explicit wins"
  out=$(cd "$SC/repo" && bash -c '. scripts/lib.sh; mm_host https://code.example.internal/g/r.git' 2>&1) || true
  sc_grep_str "$out" "cannot detect host" "mm_host dies on unknown host"
  printf -- '---\ntitle: "x"\nstatus: proposed\n---\nbody\n' >"$SC/fm.md"
  (cd "$SC/repo" && bash -c ". scripts/lib.sh; mm_frontmatter_set '$SC/fm.md' status implemented; mm_frontmatter_set '$SC/fm.md' pr https://example.invalid/pr/1")
  sc_grep "$SC/fm.md" '^status: implemented$'
  sc_grep "$SC/fm.md" '^pr: https://example.invalid/pr/1$'
  sc_eq "$(cd "$SC/repo" && bash -c ". scripts/lib.sh; mm_frontmatter_field '$SC/fm.md' pr")" "https://example.invalid/pr/1" "mm_frontmatter_field"
  out=$(cd "$SC/repo" && bash -c ". scripts/lib.sh; mm_latest '$MM_STORE/alpha' scorecard")
  sc_eq "$(basename "$out")" "scorecard-20260101T000000Z.tsv" "mm_latest scorecard"
  out=$(printf 'a"b\\c\td\n' | bash -c '. scripts/lib.sh; mm_json_escape')
  # NOTE (task-1 brief discrepancy, reported in task-1-report.md): the brief's
  # verbatim assertion expects 'a\"b\\c\td\n' (with a trailing literal \n).
  # The brief's own verbatim mm_json_escape only emits "\n" BETWEEN records
  # (`if (NR > 1) print "\\n"`); this single-line input (one trailing
  # newline, no second record) produces no trailing "\n" under that
  # implementation. Corrected to the value the specified code actually (and
  # sensibly — a lone terminating newline is not an extra blank line)
  # produces; verified byte-for-byte with `od -c`.
  sc_eq "$out" 'a\"b\\c\td' "mm_json_escape"

  # --- validate.sh (workspace mode): rejects a manifest header that isn't
  # exactly the 10-column store header (Task 1 fix round 1) ---
  mkdir -p "$SC/store/gamma"
  printf '%s\textra\n' "$MANIFEST_HEADER" >"$SC/store/gamma/manifest.tsv"
  out=$(cd "$SC/repo" && MM_STORE="$SC/store" ./scripts/validate.sh 2>&1; echo "rc=$?")
  rm -rf "$SC/store/gamma"
  sc_grep_str "$out" '^rc=[1-9][0-9]*$' "validate.sh (workspace mode) exits non-zero on a bad manifest header"
  sc_grep_str "$out" "10-column" "validate.sh (workspace mode) names the 10-column requirement"

  # --- experience.sh queries (Task 2) ---
  X="$SC/repo/scripts/experience.sh"
  out=$("$X" versions)
  sc_eq "$(printf '%s\n' "$out" | head -1)" "harness	items	workspaces	first_created	last_created" "versions header"
  sc_grep_str "$out" "^1\.0\.0\+aaaaaaa	2	alpha,beta	2026-01-01	2026-01-03$" "versions row 1.0.0"
  sc_grep_str "$out" "^1\.1\.0\+bbbbbbb	1	alpha	2026-01-02	2026-01-02$" "versions row 1.1.0"
  out=$("$X" list)
  sc_eq "$(printf '%s\n' "$out" | head -1)" "workspace	id	harness	status	g1_rounds	g2_rounds	changes_requested	blocked	corrections	reverted	docs_missing	lead_h" "list header"
  sc_eq "$(printf '%s\n' "$out" | grep -c .)" 4 "list: header + 3 items"
  sc_grep_str "$out" "^alpha	T-20260102-a2	1\.1\.0\+bbbbbbb	done	2	1	1	1	1	-	diff-review	6\.0$" "list row a2"
  sc_eq "$("$X" list --workspace beta | grep -c .)" 2 "list --workspace"
  sc_eq "$("$X" list --harness 1.0.0 | grep -c .)" 3 "list --harness semver matches both stamps"
  sc_eq "$("$X" list --gaps | grep -c .)" 2 "list --gaps: only a2"
  sc_eq "$("$X" list --since 2026-01-02 | grep -c .)" 3 "list --since"
  out=$("$X" show T-20260101-a1)
  sc_grep_str "$out" "^harness: 1\.0\.0\+aaaaaaa$" "show prints key: value"
  sc_grep_str "$out" "^merged	mr=https://example.invalid/mr/1$" "show prints events.log lines"
  sc_grep_str "$out" "trace/briefs/01-explorer-1.md" "show lists trace files"
  out=$("$X" grep 'needle-in-session' --in sessions)
  sc_grep_str "$out" "^alpha/sessions/sess-1\.jsonl:2:" "grep sessions prefix"
  out=$("$X" grep 'explore the widget' --in briefs)
  sc_grep_str "$out" "^alpha/T-20260101-a1:trace/briefs/01-explorer-1\.md:1:" "grep briefs prefix"
  sc_eq "$("$X" grep 'changes-requested' --in events | grep -c .)" 1 "grep events"
  sc_eq "$("$X" grep 'explore the widget' --in briefs --workspace beta | grep -c .)" 0 "grep --workspace filter"
  out=$("$X" summary)
  sc_grep_str "$out" "^alpha	1\.1\.0\+bbbbbbb	" "summary is prefixed by workspace"
  out=$("$X" bogus 2>&1 || true); sc_grep_str "$out" "unknown subcommand" "unknown subcommand is a usage error"

  # --- experience.sh Fix round 1 (review): cmd_grep path safety on a store
  # path containing spaces; cmd_summary usage errors and header-always ---
  mkdir -p "$SC/store with spaces"
  cp -R "$root/scripts/fixtures/store/." "$SC/store with spaces/"
  find "$SC/store with spaces" -name sessions.tsv | while IFS= read -r f; do
    sed "s|__STORE__|$SC/store with spaces|g" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  done
  out=$(MM_STORE="$SC/store with spaces" "$X" grep 'explore the widget' --in briefs)
  sc_grep_str "$out" "^alpha/T-20260101-a1:trace/briefs/01-explorer-1\.md:1:" "grep briefs prefix survives a store path with spaces"
  out=$("$X" summary --workspace nope)
  sc_eq "$(printf '%s\n' "$out" | grep -c .)" 1 "summary --workspace <nonexistent>: header only, no data rows"
  sc_eq "$(printf '%s\n' "$out" | head -1)" "workspace	harness	items	auto_approve_rate	mean_g1_rounds	mean_g2_rounds	changes_requested	blocked	corrections	reverted	items_with_gaps	mean_lead_h" "summary header text"
  out=$("$X" summary --bogus 2>&1; echo "rc=$?")
  sc_grep_str "$out" '^rc=2$' "summary --bogus is a usage error (exit 2)"

  # --- experience.sh diff/status/sync (Task 3) ---
  out=$("$X" diff 1.0.0 1.1.0)
  sc_eq "$(printf '%s\n' "$out" | head -1)" "scope	metric	1.0.0	1.1.0	delta" "diff header"
  sc_grep_str "$out" "^all	items	2	1	-1$" "diff items"
  sc_grep_str "$out" "^all	changes_requested	0	1	\+1$" "diff changes_requested"
  sc_grep_str "$out" "^all	mean_lead_h	18\.0	6\.0	-12\.0$" "diff mean_lead_h"
  sc_grep_str "$out" "^alpha	items	1	1	0$" "diff per workspace"
  sc_grep_str "$out" "^all	items_with_gaps	0	1	\+1$" "diff items_with_gaps"
  # status (fixture sources file pointing at a fake workspace path → never synced)
  printf 'sources:\n  - name: alpha\n    path: %s/fake-alpha\ncandidate:\n  remote: git@github.com:you/morpheus-os.git\n' "$SC" >"$SC/sources.yaml"
  out=$("$X" --sources "$SC/sources.yaml" status)
  sc_grep_str "$out" "^alpha	.*never synced" "status shows never-synced source"
  sc_grep_str "$out" "^1\.0\.0\+aaaaaaa	2" "status lists versions"
  sc_grep_str "$out" '\(none\)' "status proposals section: no proposals/ dir -> (none) fallback"
  # proposals aggregation: two neutral fixture notes, distinct statuses
  mkdir -p "$SC/repo/proposals"
  printf -- '---\ntitle: "Example proposal A"\nstatus: proposed\n---\nplaceholder body A\n' >"$SC/repo/proposals/proposal-a.md"
  printf -- '---\ntitle: "Example proposal B"\nstatus: implemented\n---\nplaceholder body B\n' >"$SC/repo/proposals/proposal-b.md"
  out=$("$X" --sources "$SC/sources.yaml" status)
  sc_grep_str "$out" $'^proposed\t1\t proposal-a\\.md$' "status proposals: proposed count and note listed"
  sc_grep_str "$out" $'^implemented\t1\t proposal-b\\.md$' "status proposals: implemented count and note listed"
  out=$("$X" --sources "$SC/sources.yaml" status --hook claude)
  sc_grep_str "$out" '^\{"hookSpecificOutput":\{"hookEventName":"SessionStart","additionalContext":"' "status --hook claude JSON"
  # status: unknown/malformed arguments are usage errors (exit 2), not silent plain-text fallback
  rc=0; out=$("$X" --sources "$SC/sources.yaml" status --bogus 2>&1) || rc=$?
  sc_eq "$rc" 2 "status --bogus is a usage error (exit 2)"
  rc=0; out=$("$X" --sources "$SC/sources.yaml" status --hook 2>&1) || rc=$?
  sc_eq "$rc" 2 "status --hook with no value is a usage error (exit 2)"
  rc=0; out=$("$X" --sources "$SC/sources.yaml" status --hook claude extra 2>&1) || rc=$?
  sc_eq "$rc" 2 "status --hook claude extra is a usage error (exit 2)"
  # sync: a source without the exporter is reported, exit 1; nothing written
  mkdir -p "$SC/fake-alpha/scripts"
  rc=0; out=$("$X" --sources "$SC/sources.yaml" sync 2>&1) || rc=$?
  sc_eq "$rc" 1 "sync exits 1 when a source lacks the exporter"
  sc_grep_str "$out" "update that workspace's harness" "sync names the fix"
  sc_eq "$(test -f "$SC/store/alpha/sync.tsv" && grep -c . "$SC/store/alpha/sync.tsv" || echo 0)" 2 "sync.tsv records the failed attempt (header + 1)"
  if [ -n "$SC_TEMPLATE" ]; then
    # real sync against a temp workspace built from the template checkout
    tw="$SC/tw"; git clone -q "$SC_TEMPLATE" "$tw"   # a full template checkout acts as the live workspace
    twid=$(cd "$tw" && scripts/new-work.sh task "sync smoke" | sed 's/^created: //' | xargs dirname)
    # drive the item to done under work/done/ so the default export scope picks it up
    (cd "$tw" && scripts/event.sh "$twid" status from=intake to=context >/dev/null && mkdir -p work/active && mv "$twid" work/active/ && twid="work/active/$(basename "$twid")" \
      && scripts/event.sh "$twid" delivered mode=human mr=https://example.invalid/mr/1 >/dev/null && scripts/event.sh "$twid" merged mr=https://example.invalid/mr/1 >/dev/null \
      && mkdir -p work/done && mv "$twid" work/done/)
    printf 'sources:\n  - name: tw\n    path: %s\ncandidate:\n  remote: git@github.com:you/morpheus-os.git\n' "$tw" >"$SC/sources2.yaml"
    rc=0; out=$("$X" --sources "$SC/sources2.yaml" sync 2>&1) || rc=$?
    sc_eq "$rc" 0 "sync against a template workspace exits 0 (output: $out)"
    sc_file "$SC/store/tw/manifest.tsv"
    sc_grep "$SC/store/tw/sync.tsv" "^[0-9T:Z-]+	0	"
    sc_eq "$(find "$SC/store/tw" -maxdepth 1 -name 'scorecard-*' | grep -c .)" 1 "sync produced a scorecard snapshot"
  else
    printf 'self-check: sync-against-template skipped (no MM_TEMPLATE_PATH / candidate/)\n'
  fi

  # --- candidate.sh init/branch/check (Task 4) ---
  if [ -n "$SC_TEMPLATE" ]; then
    # SC_TEMPLATE must be a git checkout of the template: its --harness asserts on many tracked files,
    # so the candidate fixture is a full clone at HEAD (uncommitted template changes are not included).
    bare="$SC/bare.git"; src="$SC/src"
    git clone -q "$SC_TEMPLATE" "$src" && git -C "$src" checkout -q -B main
    git clone -q --bare "$src" "$bare"
    printf 'sources: []\ncandidate:\n  remote: %s\n  default_branch: main\n  host: github\n  branch_prefix: proposal/\n' "$bare" >"$SC/sources3.yaml"
    C="$SC/repo/scripts/candidate.sh"; export MM_CANDIDATE_DIR="$SC/candidate"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" init 2>&1)
    sc_file "$SC/candidate/scripts/validate.sh"
    sc_grep_str "$out" "cloned" "init clones on first run"
    head1=$(git -C "$SC/candidate" rev-parse HEAD)
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" init 2>&1)
    head2=$(git -C "$SC/candidate" rev-parse HEAD)
    sc_grep_str "$out" "fetched" "init is idempotent: second run fetches, not clones"
    sc_eq "$head2" "$head1" "init idempotency: HEAD unchanged across repeated init"
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch fix-something >/dev/null)
    sc_eq "$(git -C "$SC/candidate" rev-parse --abbrev-ref HEAD)" "proposal/fix-something" "branch creates proposal/<slug>"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch 'Bad Slug' 2>&1 || true); sc_grep_str "$out" "slug" "branch rejects a bad slug"
    rc=0; out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" check 2>&1) || rc=$?
    sc_eq "$rc" 0 "check passes on a clean candidate (output tail: $(printf '%s' "$out" | tail -1))"
    printf 'echo broken (\n' >>"$SC/candidate/scripts/lib.sh"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" check 2>&1 || true); sc_grep_str "$out" "check: FAILED" "check fails on a broken candidate"
    git -C "$SC/candidate" checkout -q -- scripts/lib.sh
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch other 2>&1 || true); sc_grep_str "$out" "proposal/other" "branch from a clean tree again"
    printf 'x\n' >>"$SC/candidate/README.md" 2>/dev/null || printf 'x\n' >"$SC/candidate/DIRTY"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch third 2>&1 || true); sc_grep_str "$out" "uncommitted" "branch refuses a dirty tree"
    git -C "$SC/candidate" checkout -q -- . 2>/dev/null; rm -f "$SC/candidate/DIRTY"

    # --- branch re-run on an existing slug switches, never discards commits (fix round 1, Critical) ---
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch existing-slug >/dev/null)
    printf 'marker\n' >"$SC/candidate/marker-file.txt"
    git -C "$SC/candidate" -c user.name="Meta Harness" -c user.email="meta@example.invalid" add marker-file.txt
    git -C "$SC/candidate" -c user.name="Meta Harness" -c user.email="meta@example.invalid" commit -q -m "self-check marker commit"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch existing-slug 2>&1)
    sc_grep_str "$out" "\(existing\)" "branch re-run on an existing slug reports (existing)"
    sc_grep_str "$(git -C "$SC/candidate" log --oneline -1)" "self-check marker commit" "branch re-run on an existing slug preserves the commit"
    git -C "$SC/candidate" checkout -q "proposal/other"
    git -C "$SC/candidate" branch -q -D "proposal/existing-slug"

    # --- init routes a clone failure through mm_die (fix round 1, Important) ---
    printf 'sources: []\ncandidate:\n  remote: %s\n  default_branch: main\n  host: github\n  branch_prefix: proposal/\n' "$SC/does-not-exist.git" >"$SC/sources4.yaml"
    rc=0; out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources4.yaml" MM_CANDIDATE_DIR="$SC/candidate2" "$C" init 2>&1) || rc=$?
    sc_eq "$rc" 1 "init on a nonexistent remote fails (exit 1)"
    sc_grep_str "$out" "^error:" "init on a nonexistent remote prints an error: line"
    rm -rf "$SC/candidate2"

    # --- init verifies the clone is a morpheus-os template (fix round 1, Important) ---
    nontemplate_src="$SC/nontemplate-src"; nontemplate_bare="$SC/nontemplate.git"
    mkdir -p "$nontemplate_src"
    git -C "$nontemplate_src" init -q
    git -C "$nontemplate_src" -c user.name="Meta Harness" -c user.email="meta@example.invalid" commit -q --allow-empty -m "empty"
    git clone -q --bare "$nontemplate_src" "$nontemplate_bare"
    printf 'sources: []\ncandidate:\n  remote: %s\n  default_branch: main\n  host: github\n  branch_prefix: proposal/\n' "$nontemplate_bare" >"$SC/sources5.yaml"
    rc=0; out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources5.yaml" MM_CANDIDATE_DIR="$SC/candidate3" "$C" init 2>&1) || rc=$?
    sc_eq "$rc" 1 "init on a non-template clone fails (exit 1)"
    sc_grep_str "$out" "is not a morpheus-os template checkout" "init on a non-template clone names the reason"
    rm -rf "$SC/candidate3"
  else
    printf 'self-check: candidate checks skipped (no MM_TEMPLATE_PATH / candidate/)\n'
  fi

  # --- proposal validation + candidate.sh pr (Task 5) ---
  V="$SC/repo/scripts/validate.sh"
  # Task 3's status-aggregation block above left minimal placeholder notes
  # (proposal-a.md / proposal-b.md, only title+status) in $SC/repo/proposals —
  # clear them so this block's workspace-mode validate() runs is not
  # contaminated by fixtures that fail the full proposal note contract.
  rm -f "$SC/repo"/proposals/*.md
  mkdir -p "$SC/repo/proposals"; cp "$root/scripts/fixtures/proposals/2026-01-01-good.md" "$SC/repo/proposals/"
  out=$(cd "$SC/repo" && "$V" 2>&1); rc=$?; sc_eq "$rc" 0 "a good proposal validates (out: $out)"
  cp "$root/scripts/fixtures/proposals/2026-01-01-bad.md" "$SC/repo/proposals/"
  out=$(cd "$SC/repo" && "$V" 2>&1 || true)
  sc_grep_str "$out" "implemented requires pr" "bad: implemented without pr"
  sc_grep_str "$out" "at least 3 evidence" "bad: evidence count"
  sc_grep_str "$out" "missing section '## Risk and rollback'" "bad: missing section"
  rm "$SC/repo/proposals/2026-01-01-bad.md"
  if [ -n "$SC_TEMPLATE" ]; then
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch conventions-pointer >/dev/null)
    printf '\n<!-- proposal smoke edit -->\n' >>"$SC/candidate/workflow/implementer.md"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/2026-01-01-good.md --dry-run 2>&1); rc=$?
    sc_eq "$rc" 0 "pr --dry-run succeeds (out tail: $(printf '%s' "$out" | tail -2 | tr '\n' ' '))"
    sc_grep_str "$out" "would run: gh pr create --base main --head proposal/conventions-pointer" "pr --dry-run prints the gh command"
    sc_eq "$(git -C "$SC/candidate" log --oneline origin/main..HEAD | grep -c .)" 1 "pr --dry-run still commits locally"
    sc_grep_str "$(git -C "$SC/candidate" log -1 --format=%s)" "^proposal: Implementer brief lacks" "commit subject from the note title"
    sc_eq "$(git -C "$bare" branch --list 'proposal/*' | grep -c .)" 0 "pr --dry-run pushes nothing"
    sc_eq "$(mm_frontmatter_field "$SC/repo/proposals/2026-01-01-good.md" status)" proposed "dry-run leaves the note status"
    # pr --dry-run again on the SAME branch: nothing new to stage, but the
    # branch is already ahead of origin/$base from the commit above — must
    # not die with "nothing to commit", just skip straight to gate/push/PR.
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/2026-01-01-good.md --dry-run 2>&1); rc=$?
    sc_eq "$rc" 0 "pr --dry-run again on the same branch succeeds (ahead of origin, nothing new to stage)"
    sc_grep_str "$out" "would run: gh pr create --base main --head proposal/conventions-pointer" "pr --dry-run (repeat) prints the gh command"
    # leakage: a store id in the diff is refused
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch leaky >/dev/null)
    printf '\nsee T-20260102-a2\n' >>"$SC/candidate/README.md" 2>/dev/null || printf 'see T-20260102-a2\n' >"$SC/candidate/LEAK.md"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/2026-01-01-good.md --dry-run 2>&1 || true)
    sc_grep_str "$out" "leakage: T-20260102-a2" "pr refuses a store id in the diff"
    git -C "$SC/candidate" checkout -q -- . ; rm -f "$SC/candidate/LEAK.md"
    # leakage: a store id ONLY in the PR body (Diagnosis section, not Evidence) is
    # refused even with a clean candidate tree — the gate scans the note body too,
    # not just the diff.
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch body-leak >/dev/null)
    printf -- '---\ntitle: "Body leak test"\nstatus: proposed\ncreated: 2026-01-01\nupdated: 2026-01-01\nworkspaces: [alpha]\nharness_before: 1.0.0+aaaaaaa\nmetric: changes_requested\nprediction: "down"\nharness_after: null\nmeasured: null\npr: null\n---\n# Body leak test\n\n## Evidence\n- alpha/T-20260101-a1:trace/briefs/01-explorer-1.md:1 — "brief: explore the widget"\n- alpha/T-20260102-a2:events.log:3 — "changes-requested gate=1 by=human"\n- beta/T-20260103-b1:events.log:2 — "status from=intake to=context"\n\n## Diagnosis\nSee T-20260102-a2 in the trace for detail.\n\n## Proposal\nNothing to change.\n\n## Risk and rollback\nNone.\n\n## Measurement\nTBD.\n' >"$SC/repo/proposals/body-leak.md"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/body-leak.md --dry-run 2>&1 || true)
    sc_grep_str "$out" "leakage: T-20260102-a2" "pr refuses a store id in the PR body even on a clean tree (not just the diff)"
    rm -f "$SC/repo/proposals/body-leak.md"

    # leakage: a store id that is only STAGED (git add, not committed) is
    # caught too — git_c diff HEAD covers staged + unstaged, not just
    # unstaged like plain `git diff` did.
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch staged-leak >/dev/null)
    printf 'T-20260102-a2\n' >"$SC/candidate/STAGED-LEAK.md"
    git -C "$SC/candidate" add STAGED-LEAK.md
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/2026-01-01-good.md --dry-run 2>&1 || true)
    sc_grep_str "$out" "leakage: T-20260102-a2" "pr refuses a store id that is only staged, not committed"
    git -C "$SC/candidate" reset -q; rm -f "$SC/candidate/STAGED-LEAK.md"

    # a longer token that merely contains a store id as a prefix is not a
    # false-positive hit (whole-token match via grep -w).
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch no-false-positive >/dev/null)
    printf 'T-20260102-a2x\n' >"$SC/candidate/NOTALEAK.md"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/2026-01-01-good.md --dry-run 2>&1); rc=$?
    sc_eq "$rc" 0 "pr --dry-run is not fooled by a longer token containing a store id as a prefix"
    sc_grep_str "$out" "would run: gh pr create" "pr --dry-run (no false positive) still prints the gh command"

    # an empty/unsynced store must not abort the leak-gate corpus build under
    # set -e (an unmatched glob) — it must yield an empty ids file and let
    # the pr proceed normally.
    mkdir -p "$SC/emptystore"
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch empty-store-check >/dev/null)
    printf '\n<!-- empty store smoke -->\n' >>"$SC/candidate/README.md" 2>/dev/null || printf 'x\n' >"$SC/candidate/EMPTYSTORE.md"
    out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" MM_STORE="$SC/emptystore" "$C" pr proposals/2026-01-01-good.md --dry-run 2>&1); rc=$?
    sc_eq "$rc" 0 "pr --dry-run succeeds against an empty store"
    sc_grep_str "$out" "would run: gh pr create" "pr --dry-run (empty store) still prints the gh command"

    # a proposal note that fails mm_validate_proposal is refused before any
    # commit: no "would run:" line, no new commit on the branch.
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch bad-note-check >/dev/null)
    cp "$root/scripts/fixtures/proposals/2026-01-01-bad.md" "$SC/repo/proposals/"
    rc=0; out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/2026-01-01-bad.md --dry-run 2>&1) || rc=$?
    sc_eq "$rc" 1 "pr refuses a proposal note that fails validation"
    sc_grep_str "$out" "at least 3 evidence" "pr's validation failure names a specific violation"
    sc_grep_str "$out" "proposal note failed validation" "pr names the failing note"
    has_would_run=no
    case "$out" in *"would run:"*) has_would_run=yes ;; esac
    sc_eq "$has_would_run" no "pr (invalid note) prints no would run: line"
    sc_eq "$(git -C "$SC/candidate" log --oneline origin/main..HEAD | grep -c .)" 0 "pr (invalid note) makes no new commit"
    rm -f "$SC/repo/proposals/2026-01-01-bad.md"

    # --- Fix round 2, C1: the note's TITLE becomes the public PR title and the
    # commit subject, so the gate scans the whole note (frontmatter included)
    # and the commit subject string — an otherwise valid note is refused ---
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch title-leak >/dev/null)
    sed 's|^title: .*|title: "Fix T-20260102-a2 in the implementer brief"|' \
      "$SC/repo/proposals/2026-01-01-good.md" >"$SC/repo/proposals/title-leak.md"
    rc=0; out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/title-leak.md --dry-run 2>&1) || rc=$?
    sc_eq "$rc" 1 "pr refuses a store id in the note title (it becomes the PR title and the commit subject)"
    sc_grep_str "$out" "leakage: T-20260102-a2" "pr's title-leak refusal names the leaked id"
    has_would_run=no
    case "$out" in *"would run:"*) has_would_run=yes ;; esac
    sc_eq "$has_would_run" no "pr (title leak) prints no would run: line"
    sc_eq "$(git -C "$SC/candidate" log --oneline origin/main..HEAD | grep -c .)" 0 "pr (title leak) makes no commit"
    rm -f "$SC/repo/proposals/title-leak.md"

    # --- Fix round 2, I4: the corpus also holds workspace names and the
    # scorecard's repos column — both are refused in the diff ---
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch store-name-leak >/dev/null)
    printf 'seen in the alpha workspace, in the demo repo\n' >"$SC/candidate/STORE-NAME-LEAK.md"
    rc=0; out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/2026-01-01-good.md --dry-run 2>&1) || rc=$?
    sc_eq "$rc" 1 "pr refuses a store workspace/repo name in the diff"
    sc_grep_str "$out" "leakage:.*alpha" "pr's refusal names the leaked workspace name"
    sc_grep_str "$out" "leakage:.*demo" "pr's refusal names the leaked repos value"
    rm -f "$SC/candidate/STORE-NAME-LEAK.md"

    # --- Fix round 2, C2: a missing origin/<default_branch> fails the gate
    # CLOSED (the corpus diff would silently be empty otherwise) ---
    printf 'sources: []\ncandidate:\n  remote: %s\n  default_branch: nonexistent\n  host: github\n  branch_prefix: proposal/\n' "$bare" >"$SC/sources6.yaml"
    rc=0; out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources6.yaml" "$C" pr proposals/2026-01-01-good.md --dry-run 2>&1) || rc=$?
    sc_eq "$rc" 1 "pr fails closed when origin/<default_branch> does not exist"
    sc_grep_str "$out" "default_branch" "pr names candidate.default_branch when origin/<base> is missing"
    has_would_run=no
    case "$out" in *"would run:"*) has_would_run=yes ;; esac
    sc_eq "$has_would_run" no "pr (missing origin/<base>) prints no would run: line"

    # --- Fix round 2, I5: the live path is opt-in; plain `pr <note>` refuses ---
    (cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" branch needs-yes >/dev/null)
    head_before=$(git -C "$SC/candidate" rev-parse HEAD)
    rc=0; out=$(cd "$SC/repo" && MM_SOURCES="$SC/sources3.yaml" "$C" pr proposals/2026-01-01-good.md 2>&1) || rc=$?
    sc_eq "$rc" 1 "pr with neither --dry-run nor --yes refuses"
    sc_grep_str "$out" -- "--yes" "pr's refusal names the --yes flag"
    sc_eq "$(git -C "$SC/candidate" rev-parse HEAD)" "$head_before" "pr without --yes makes no commit"
    sc_eq "$(git -C "$bare" branch --list 'proposal/*' | grep -c .)" 0 "pr without --yes pushes nothing"
  fi

  # --- Task 6: proposer texts, commands, hook, README, CI (presence +
  # key phrases, checked against the REAL repo files under $root — these
  # are fixed authored files, not fixture-store-derived, so there is no
  # value in copying them into the throwaway $SC tree) ---
  sc_grep "$root/AGENTS.md" 'experience\.sh grep'
  sc_grep "$root/AGENTS.md" 'candidate\.sh pr'
  sc_grep "$root/AGENTS.md" '[Nn]ever write into a source workspace'
  sc_grep "$root/AGENTS.md" '^## Proposal note'
  sc_file "$root/.claude/commands/harness-review.md"
  sc_file "$root/.claude/commands/sync.md"
  sc_file "$root/.claude/commands/status.md"
  sc_grep "$root/.claude/settings.json" 'experience\.sh\\" status --hook claude'
  # The probe for python3 and the parse itself must stay separate: folding
  # them into one `out=$(…) || out="skip"` lets a real parse failure overwrite
  # itself with the skip string and pass. When python3 is missing the check is
  # not counted at all, and says so.
  if command -v python3 >/dev/null 2>&1; then
    check
    rc=0; out=$(python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$root/.claude/settings.json" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || sc_fail ".claude/settings.json is not valid JSON: $out"
  else
    printf 'self-check: settings.json parse skipped (no python3)\n'
  fi
  sc_grep "$root/README.md" 'sources\.example\.yaml'
  sc_file "$root/.github/workflows/validate.yml"
  sc_grep "$root/.github/workflows/validate.yml" '\-\-self-check'
  sc_file "$root/.github/prompts/harness-review.prompt.md"
  sc_file "$root/.github/prompts/sync.prompt.md"

  # --- Fix round 2 (whole-tree review): store-query robustness and YAML
  # scalar hygiene. None of these need a template checkout. ---

  # C3: an export interrupted between the manifest and the snapshots leaves a
  # workspace with a manifest and no scorecard/summary. mm_latest must return
  # nothing AND exit 0 there, so every query keeps working on the rest.
  list_lines_before=$("$X" list | grep -c .)
  mkdir -p "$SC/store/aaa"
  cp "$SC/store/alpha/manifest.tsv" "$SC/store/aaa/manifest.tsv"
  rc=0; out=$("$X" versions) || rc=$?
  sc_eq "$rc" 0 "versions survives a workspace with a manifest but no snapshot"
  sc_grep_str "$out" "^1\.0\.0\+aaaaaaa	2	alpha,beta	2026-01-01	2026-01-03$" "versions still reports the other workspaces (snapshot-less workspace)"
  rc=0; out=$("$X" list) || rc=$?
  sc_eq "$rc" 0 "list survives a workspace with a manifest but no snapshot"
  sc_eq "$(printf '%s\n' "$out" | grep -c .)" "$list_lines_before" "list output is unchanged by a snapshot-less workspace"
  rc=0; out=$("$X" summary) || rc=$?
  sc_eq "$rc" 0 "summary survives a workspace with a manifest but no snapshot"
  sc_grep_str "$out" "^alpha	1\.1\.0\+bbbbbbb	" "summary still reports alpha (snapshot-less workspace)"
  rc=0; out=$("$X" --sources "$SC/sources.yaml" status) || rc=$?
  sc_eq "$rc" 0 "status survives a workspace with a manifest but no snapshot"
  sc_grep_str "$out" "^1\.0\.0\+aaaaaaa	2" "status still lists versions (snapshot-less workspace)"
  rm -rf "$SC/store/aaa"

  # I6: the exported set (manifest) is the evaluation set — a scorecard row
  # for an item that was never exported must not reach any query.
  cp "$SC/store/alpha/scorecard-20260101T000000Z.tsv" "$SC/scorecard-alpha.bak"
  versions_before=$("$X" versions); summary_before=$("$X" summary); list_before=$("$X" list | grep -c .)
  awk -F'\t' -v OFS='\t' 'NR == 2 { $1 = "T-20269999-ghost"; print }' "$SC/scorecard-alpha.bak" \
    >>"$SC/store/alpha/scorecard-20260101T000000Z.tsv"
  out=$("$X" list); has_ghost=no
  case "$out" in *T-20269999-ghost*) has_ghost=yes ;; esac
  sc_eq "$has_ghost" no "list drops a scorecard row whose id is not in the manifest"
  sc_eq "$(printf '%s\n' "$out" | grep -c .)" "$list_before" "list row count unchanged by an unexported scorecard row"
  sc_eq "$("$X" versions)" "$versions_before" "versions counts unchanged by an unexported scorecard row"
  sc_eq "$("$X" summary)" "$summary_before" "summary unchanged by an unexported scorecard row"
  mv "$SC/scorecard-alpha.bak" "$SC/store/alpha/scorecard-20260101T000000Z.tsv"

  # M1: YAML scalars lose trailing blanks and ONE matching pair of quotes.
  printf 'sources:\n  - name: ws-one   \n    path: /tmp/ws one   \ncandidate:\n  remote: %s   \n  default_branch: "main"   \n  branch_prefix: proposal/\n' \
    "'git@github.com:you/morpheus-os.git'" >"$SC/scalars.yaml"
  sc_eq "$(MM_SOURCES="$SC/scalars.yaml" bash -c ". $SC/repo/scripts/lib.sh; mm_sources")" \
    "ws-one	/tmp/ws one" "mm_sources trims trailing blanks from name and path"
  sc_eq "$(MM_SOURCES="$SC/scalars.yaml" bash -c ". $SC/repo/scripts/lib.sh; mm_candidate remote")" \
    "git@github.com:you/morpheus-os.git" "mm_candidate strips single quotes and trailing blanks"
  sc_eq "$(MM_SOURCES="$SC/scalars.yaml" bash -c ". $SC/repo/scripts/lib.sh; mm_candidate default_branch")" \
    main "mm_candidate strips double quotes and trailing blanks"
  # M2: a CRLF sources.yaml parses exactly like an LF one.
  awk '{ printf "%s\r\n", $0 }' "$SC/scalars.yaml" >"$SC/scalars-crlf.yaml"
  sc_eq "$(MM_SOURCES="$SC/scalars-crlf.yaml" bash -c ". $SC/repo/scripts/lib.sh; mm_sources")" \
    "ws-one	/tmp/ws one" "mm_sources parses a CRLF sources.yaml"
  sc_eq "$(MM_SOURCES="$SC/scalars-crlf.yaml" bash -c ". $SC/repo/scripts/lib.sh; mm_candidate remote")" \
    "git@github.com:you/morpheus-os.git" "mm_candidate parses a CRLF sources.yaml"

  # M3: an option whose value is missing is a usage error (exit 2), never a
  # raw "$2: unbound variable" from bash.
  rc=0; out=$("$X" list --workspace 2>&1) || rc=$?
  sc_eq "$rc" 2 "list --workspace with no value is a usage error (exit 2)"
  rc=0; out=$("$X" list --harness 2>&1) || rc=$?
  sc_eq "$rc" 2 "list --harness with no value is a usage error (exit 2)"
  rc=0; out=$("$X" list --since 2>&1) || rc=$?
  sc_eq "$rc" 2 "list --since with no value is a usage error (exit 2)"
  rc=0; out=$("$X" grep pattern --in 2>&1) || rc=$?
  sc_eq "$rc" 2 "grep --in with no value is a usage error (exit 2)"
  rc=0; out=$("$X" grep pattern --workspace 2>&1) || rc=$?
  sc_eq "$rc" 2 "grep --workspace with no value is a usage error (exit 2)"
  rc=0; out=$("$X" summary --workspace 2>&1) || rc=$?
  sc_eq "$rc" 2 "summary --workspace with no value is a usage error (exit 2)"

  # M4: sync writes only under the store — an illegal source name is rejected
  # BEFORE any directory is created.
  printf 'sources:\n  - name: ../../pwned\n    path: %s/fake-alpha\ncandidate:\n  remote: git@github.com:you/morpheus-os.git\n' "$SC" >"$SC/sources-badname.yaml"
  # Two levels deep, so the traversal target ($SC/pwned) is inside this run's
  # own mktemp dir and cannot pre-exist.
  mkdir -p "$SC/deep/store"
  rc=0; out=$("$X" --store "$SC/deep/store" --sources "$SC/sources-badname.yaml" sync 2>&1) || rc=$?
  sc_eq "$rc" 1 "sync exits 1 on an illegal source name"
  sc_grep_str "$out" "source name must match" "sync names the source-name rule"
  escaped=no
  if [ -e "$SC/pwned" ] || [ -e "$SC/deep/store/../../pwned" ]; then escaped=yes; fi
  sc_eq "$escaped" no "sync creates nothing outside the store for an illegal source name"

  # M11 / I7: workspace names are read line by line (a name with a space is
  # queryable), and the tracked/untracked split is documented.
  mkdir -p "$SC/store/two words"
  cp "$SC/store/beta/manifest.tsv" "$SC/store/two words/"
  cp "$SC/store/beta/scorecard-20260101T000000Z.tsv" "$SC/store/two words/"
  out=$("$X" list --workspace "two words")
  sc_grep_str "$out" "^two words	T-20260103-b1	" "list handles a workspace name containing a space"
  rm -rf "$SC/store/two words"
  sc_grep "$root/.gitignore" '^experience/\*/config/$'
  sc_grep "$root/README.md" '^What is tracked: .manifest\.tsv'
  sc_grep "$root/README.md" 'run record, and .config/'

  : # Keep this bare `:` as the LAST statement of run_self_check. Some
    # assertions above are "should die" checks whose expected failure exits
    # non-zero; whichever ends up last would otherwise become
    # run_self_check's return status and trip the caller's `set -e`. Append
    # new self-check blocks ABOVE this line.
}

if [ "$mode" = self-check ]; then
  run_self_check
  if [ "$sc_failed" -ne 0 ]; then
    printf 'self-check: FAILED — %s checks, failures above\n' "$checks" >&2
    exit 1
  fi
  printf 'self-check: OK (%s checks)\n' "$checks"
  exit 0
fi

# --- workspace mode ----------------------------------------------------------

if [ -f "$root/config/sources.yaml" ]; then
  check
  if ! (MM_SOURCES="$root/config/sources.yaml" mm_sources >/dev/null); then
    v_error "config/sources.yaml: failed to parse (mm_sources)"
  fi
fi

store=$(mm_store)
if [ -d "$store" ]; then
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    check
    [ "$(head -1 "$manifest")" = "$MANIFEST_HEADER" ] || v_error "$manifest: expected exactly the 10-column store manifest header"
  done < <(find "$store" -mindepth 2 -maxdepth 2 -name manifest.tsv | LC_ALL=C sort)
fi

if [ -d "$root/proposals" ]; then
  while IFS= read -r note; do
    [ -n "$note" ] || continue
    case "$(basename "$note")" in README.md) continue ;; esac
    check
    mm_validate_proposal "$note" || v_error "$note: proposal note failed validation"
  done < <(find "$root/proposals" -maxdepth 1 -name '*.md' | LC_ALL=C sort)
fi

if [ "$errors" -gt 0 ]; then
  printf 'validate: FAILED — %s error(s), %s checks\n' "$errors" "$checks" >&2
  exit 1
fi

printf 'validate: OK (%s checks)\n' "$checks"
