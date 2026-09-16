#!/usr/bin/env bash
# candidate.sh — the candidate clone of the template the proposer edits:
# init (clone/fetch), branch (fresh proposal branch), check (the template's own
# self-checks), pr (leakage gate, commit, push, PR/MR). Writes only under candidate/.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: candidate.sh init | branch <slug> | check | pr <proposal-file> (--dry-run | --yes)

  init              clone candidate.remote into candidate/ (or fetch when present)
  branch <slug>     refresh to origin/<default_branch> and create <branch_prefix><slug>
                    (slug: [a-z0-9-]+; refuses a dirty tree)
  check             run the candidate's scripts/validate.sh and --harness, plus the pinned
                    shellcheck container when Docker is available
  pr <note>         re-run check; leakage gate (no store ids, workspace or repo names,
                    source paths or MR URLs in the diff, the PR body, the note — title
                    and frontmatter included — or the commit subject); commit; push; open
                    the PR/MR (gh|glab); mark the note implemented.
                      --dry-run  commits locally, pushes nothing, and prints the push/PR
                                 commands instead of running them
                      --yes      the human's go-ahead: actually push and open the PR/MR
                    One of the two is required; plain `pr <note>` refuses.
Config: candidate.{remote,default_branch,host,branch_prefix} in config/sources.yaml.
Candidate dir: $MM_CANDIDATE_DIR or <repo>/candidate.
EOF
}
[ $# -ge 1 ] || mm_usage_error "missing subcommand"
cmd="$1"; shift
case "$cmd" in -h | --help) usage; exit 0 ;; esac
cand="${MM_CANDIDATE_DIR:-$(mm_root)/candidate}"
remote=$(mm_candidate remote); base=$(mm_candidate default_branch); prefix=$(mm_candidate branch_prefix)

git_c() { git -C "$cand" "$@"; }
require_clean() { [ -z "$(git_c status --porcelain)" ] || mm_die "candidate/ has uncommitted changes — commit them via 'pr' or discard them first"; }
# require_template — the clone at $cand is a morpheus-os template checkout.
require_template() {
  [ -f "$cand/VERSION" ] && [ -f "$cand/scripts/validate.sh" ] || mm_die "candidate: $cand is not a morpheus-os template checkout (missing VERSION or scripts/validate.sh)"
}

cmd_init() {
  if [ -d "$cand/.git" ]; then
    require_clean
    git_c fetch -q origin || mm_die "candidate: git fetch failed for $remote"
    require_template
    printf 'candidate: fetched %s\n' "$remote"
  else
    git clone -q "$remote" "$cand" || mm_die "candidate: git clone failed for $remote"
    require_template
    printf 'candidate: cloned %s into %s\n' "$remote" "$cand"
  fi
}
cmd_branch() {
  [ $# -eq 1 ] || mm_usage_error "branch needs exactly one <slug>"
  case "$1" in '' | *[!a-z0-9-]*) mm_die "slug '$1' must match [a-z0-9-]+" ;; esac
  [ -d "$cand/.git" ] || mm_die "no candidate/ — run 'candidate.sh init' first"
  require_template
  require_clean
  git_c fetch -q origin || mm_die "candidate: git fetch failed for $remote"
  local branch="$prefix$1"
  if git_c show-ref --verify --quiet "refs/heads/$branch"; then
    git_c checkout -q "$branch" || mm_die "candidate: git checkout failed for $branch"
    printf 'candidate: on %s (existing)\n' "$branch"
  else
    git_c checkout -q -B "$branch" "origin/$base" || mm_die "candidate: git checkout failed for $branch"
    printf 'candidate: on %s (from origin/%s)\n' "$branch" "$base"
  fi
}
cmd_check() {
  require_template
  local rc=0
  (cd "$cand" && scripts/validate.sh) || rc=1
  (cd "$cand" && scripts/validate.sh --harness) || rc=1
  if docker info >/dev/null 2>&1; then
    (cd "$cand" && docker run --rm -e LANG=C.UTF-8 -v "$PWD":/w -w /w koalaman/shellcheck:stable scripts/*.sh) || rc=1
  else printf 'check: shellcheck container skipped (Docker not running)\n'; fi
  if [ "$rc" -eq 0 ]; then printf 'check: OK\n'; else printf 'check: FAILED\n' >&2; return 1; fi
}
cmd_pr() {
  # prbody/ids_file/leakfile are deliberately NOT local: the EXIT trap below
  # fires when the whole script process exits (after cmd_pr has already
  # returned to the dispatcher and its locals would be gone), so these must
  # stay in scope at the script level for the trap to clean them up under
  # `set -u`.
  local note="" dry=no yes=no title body branch host hits url ahead d ws sc
  prbody=""; ids_file=""; leakfile=""
  while [ $# -gt 0 ]; do case "$1" in --dry-run) dry=yes ;; --yes) yes=yes ;; -*) mm_usage_error "pr: unknown option $1" ;; *) note="$1" ;; esac; shift; done
  [ -n "$note" ] && [ -f "$note" ] || mm_usage_error "pr needs an existing <proposal-file>"
  # Spec §6.3 marks the push [confirm]: the live path is opt-in, never the
  # default, so a dropped flag or a retry cannot open a public PR by itself.
  [ "$dry" = yes ] || [ "$yes" = yes ] || mm_die "pr: pushing and opening the PR needs the human's go-ahead — re-run with --yes (or preview with --dry-run)"
  mm_validate_proposal "$note" || mm_die "proposal note failed validation: $note"
  branch=$(git_c branch --show-current)
  case "$branch" in "$prefix"*) : ;; *) mm_die "candidate/ is on '$branch' — run 'candidate.sh branch <slug>' first" ;; esac
  # The gate's diff is taken against origin/<default_branch>: if that ref is
  # missing (typo in candidate.default_branch, renamed branch, no fetch yet)
  # the diff would fail and the gate would see nothing — fail closed instead.
  git_c rev-parse --verify --quiet "origin/$base" >/dev/null || mm_die "origin/$base not found — check candidate.default_branch or run candidate.sh init"
  cmd_check >/dev/null || mm_die "check failed — fix the candidate before opening a PR"
  title=$(mm_frontmatter_field "$note" title)
  body=$(awk '/^## Proposal/ { p = 1; next } /^## / { p = 0 } p' "$note")
  # PR body: the note without frontmatter and without its Evidence section (store ids stay private)
  prbody=$(mktemp "${TMPDIR:-/tmp}/mm-prbody.XXXXXX")
  trap 'rm -f "${prbody:-}" "${ids_file:-}" "${leakfile:-}"' EXIT
  awk 'NR == 1 && /^---/ { fm = 1; next } fm && /^---/ { fm = 0; next } fm { next } /^## Evidence/ { skip = 1; next } /^## / { skip = 0 } !skip' "$note" >"$prbody"
  # Leakage gate corpus: everything the store knows that must not become
  # public — item ids, workspace names, repo names, source paths, MR URLs.
  # Every glob/command here is guarded (if/fi or || true): an empty or
  # unsynced store must yield an empty ids file, not abort under `set -e`.
  # Workspace and repo names are only collected from 4 characters up: shorter
  # ones ("tw", "os") are too collision-prone as whole-word matches.
  ids_file=$(mktemp "${TMPDIR:-/tmp}/mm-leak.XXXXXX")
  { for d in "$(mm_store)"/*/; do
      if [ -f "$d/manifest.tsv" ]; then
        ws=$(basename "$d")
        if [ "${#ws}" -ge 4 ]; then printf '%s\n' "$ws"; fi
        awk -F'\t' 'NR > 1 { print $1 }' "$d/manifest.tsv"
        sc=$(mm_latest "$d" scorecard)
        # scorecard column 5 is `repos` (comma-joined in the template's scorecard.sh)
        if [ -n "$sc" ]; then
          awk -F'\t' 'NR > 1 { n = split($5, r, /[,; ]+/); for (i = 1; i <= n; i++) if (r[i] != "-" && length(r[i]) >= 4) print r[i] }' "$sc"
        fi
      fi
    done
    mm_sources 2>/dev/null | cut -f2 || true
    if [ -d "$(mm_store)" ]; then
      # every mr: URL in every item doc (task.md, story.md, epic.md)
      find "$(mm_store)" -type f -name '*.md' -path '*/items/*' 2>/dev/null | while IFS= read -r p; do
        awk '/^mr:[ \t]/ { if ($2 != "" && $2 != "null" && $2 != "-") print $2 }' "$p"
      done
    fi
  } | grep -v '^$' | LC_ALL=C sort -u >"$ids_file" || true
  if [ -s "$ids_file" ]; then
    # The scanned corpus is everything that can become public: the branch diff
    # against origin/<base>, staged AND unstaged changes (`diff HEAD`),
    # untracked files, the PR body, the WHOLE note (its title becomes the PR
    # title and the commit subject; only the `workspaces:` field and the
    # Evidence section legitimately name the store) and the commit subject
    # itself. No stage may fail silently — a failing corpus stage aborts.
    leakfile=$(mktemp "${TMPDIR:-/tmp}/mm-leakcorpus.XXXXXX")
    { git_c diff "origin/$base...HEAD" || mm_die "leakage gate: 'git diff origin/$base...HEAD' failed in $cand"
      git_c diff HEAD || mm_die "leakage gate: 'git diff HEAD' failed in $cand"
      git_c ls-files --others --exclude-standard | while IFS= read -r f; do if [ -f "$cand/$f" ]; then cat "$cand/$f"; fi; done
      cat "$prbody"
      awk 'NR == 1 && /^---/ { fm = 1; print; next }
fm && /^---/ { fm = 0; print; next }
fm && index($0, "workspaces:") == 1 { next }
/^## Evidence/ { skip = 1; next }
/^## / { skip = 0 }
!skip' "$note"
      printf 'proposal: %s\n' "$title"
    } >"$leakfile"
    hits=$(grep -owF -f "$ids_file" "$leakfile" | LC_ALL=C sort -u || true)
    if [ -n "$hits" ]; then
      printf 'error: leakage: %s\n' "$hits" | tr '\n' ' ' >&2
      printf '\n' >&2
      mm_die "the diff, the note or the commit subject names store ids, workspaces, repos, source paths or MR URLs — proposals must be generic"
    fi
  fi
  git_c add -A
  if git_c diff --cached --quiet; then
    # nothing staged: fine only when the branch already carries commits ahead
    # of origin/$base (e.g. a previous --dry-run already committed) — then we
    # just skip straight to the gate/push/PR below.
    ahead=$(git_c rev-list --count "origin/$base..HEAD")
    [ "$ahead" -gt 0 ] || mm_die "nothing to commit in candidate/"
  elif [ -n "$(git_c config user.email 2>/dev/null)" ]; then
    git_c commit -q -m "proposal: $title" -m "$body" || mm_die "commit failed in candidate/"
  else
    git_c -c user.name='Meta Harness' -c user.email='meta@example.invalid' commit -q -m "proposal: $title" -m "$body" || mm_die "commit failed in candidate/"
  fi
  host=$(mm_host "$remote" "$(mm_candidate host)")
  if [ "$dry" = yes ]; then
    printf 'would run: git -C %s push -u origin %s\n' "$cand" "$branch"
    # shellcheck disable=SC2016 # the gitlab branch's format string is literal text (shows the glab command as it would run), not meant to expand
    case "$host" in
      github) printf 'would run: gh pr create --base %s --head %s --title "proposal: %s" --body-file %s\n' "$base" "$branch" "$title" "$prbody" ;;
      gitlab) printf 'would run: glab mr create --source-branch %s --target-branch %s --title "proposal: %s" --description "$(cat %s)" --yes\n' "$branch" "$base" "$title" "$prbody" ;;
    esac
    return 0
  fi
  git_c push -q -u origin "$branch"
  case "$host" in
    github) url=$(cd "$cand" && gh pr create --base "$base" --head "$branch" --title "proposal: $title" --body-file "$prbody" | tail -1) ;;
    gitlab) url=$(cd "$cand" && glab mr create --source-branch "$branch" --target-branch "$base" --title "proposal: $title" --description "$(cat "$prbody")" --yes | tail -1) ;;
  esac
  mm_frontmatter_set "$note" status implemented
  mm_frontmatter_set "$note" pr "$url"
  mm_frontmatter_set "$note" updated "$(mm_today)"
  printf 'opened %s; %s marked implemented\n' "$url" "$note"
}

case "$cmd" in
  init) cmd_init "$@" ;;
  branch) cmd_branch "$@" ;;
  check) cmd_check "$@" ;;
  pr) cmd_pr "$@" ;;
  *) mm_usage_error "unknown subcommand '$cmd'" ;;
esac
