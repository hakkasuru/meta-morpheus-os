# meta-morpheus-os

> Agents: read [`AGENTS.md`](AGENTS.md) instead of this file — it is the
> canonical instruction set (also served as `CLAUDE.md` via a symlink).
> This README is for humans.

meta-morpheus-os is the proposer harness for [morpheus-os](https://github.com/hakkasuru/morpheus-os):
it reads the run record your morpheus-os workspaces already produce, looks
for the harness decisions behind your recurring friction, and proposes
small, additive changes back to the template as a PR/MR.

## The loop

1. Sync each registered workspace's run record into a local experience
   store (`scripts/experience.sh sync`).
2. Query it for a failure class with evidence: changes requested, blocked
   items, corrections, reverts, gate gaps, long lead time
   (`scripts/experience.sh list --gaps`, `summary`, `grep`).
3. Diagnose which harness rule, brief, template or script is behind it, and
   check that items following the same rule did NOT fail (a confound
   check).
4. Write a proposal note (`proposals/<date>-<slug>.md`) with evidence,
   diagnosis, the proposed change, risk/rollback and how it will be
   measured, then edit the candidate clone of the template to match.
5. Open a PR/MR against the template: `scripts/candidate.sh pr <note>
   --dry-run` previews it (it commits locally, pushes nothing, and prints the
   push/PR commands), and `scripts/candidate.sh pr <note> --yes` — your
   explicit go-ahead after reading that preview — actually pushes and opens
   it. Once it lands, a later iteration measures the metric it predicted and
   you decide whether to keep it.

See `AGENTS.md` for the full instructions the proposer agent follows,
including the `/harness-review` iteration and the proposal note contract.

## Make it yours

This is a public template; you run your own private instance against your
own workspaces.

1. Fork or clone the public repo, then create your own private repo and
   repoint remotes so the public template becomes `upstream` (fetch-only)
   and your private repo becomes `origin`:

   ```sh
   git remote rename origin upstream
   git remote set-url --push upstream DISABLED
   git remote add origin <your-private-repo-url>
   ```

2. Copy the sources template and fill in your workspaces and the template
   you want to propose changes to:

   ```sh
   cp config/sources.example.yaml config/sources.yaml
   $EDITOR config/sources.yaml
   ```

3. Clone the candidate (the template you'll propose changes to):

   ```sh
   scripts/candidate.sh init
   ```

   `init` prints the identity proposal commits will carry (`candidate:
   commits as …`). If it is not the one you want on the public template,
   set `candidate.git_name` / `candidate.git_email` in `config/sources.yaml`
   and run `init` again.

4. Pull in your first experience export:

   ```sh
   scripts/experience.sh sync
   ```

5. Check your instance: that `config/sources.yaml` parses, the manifests just
   synced have the expected shape and your proposals satisfy the note
   contract:

   ```sh
   scripts/validate.sh
   ```

6. Restart the session so the `SessionStart` hook picks up the store.

Optional, for developers changing these scripts: `scripts/validate.sh
--self-check` runs the toolkit's own fixture-driven test suite (it touches
neither your `config/sources.yaml` nor your store).

## Requirements

- bash 3.2+ (macOS's shipped bash works as-is)
- git
- `gh` (GitHub) or `glab` (GitLab), matching `candidate.host`
- Docker, optional — used for the pinned shellcheck container in CI and by
  `candidate.sh check`; scripts run fine without it

## Store layout

`experience/<workspace>/` holds `manifest.tsv`, `sync.tsv`, dated
`scorecard-*.tsv` / `summary-*.tsv` snapshots, `config/preferences.md`,
`items/<id>/` (docs, events.log, trace) and `sessions/<sid>.jsonl`.
What is tracked: `manifest.tsv`, the `scorecard-*` / `summary-*` snapshots,
`sync.tsv` and your `proposals/` — so the evidence trail behind a kept or
reverted proposal survives in your private repo's history. What stays local
(gitignored): `items/` and `sessions/`, exported verbatim from a workspace's
run record, and `config/` — the copy of that workspace's own preferences
document the exporter takes along.
