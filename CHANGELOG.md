# Changelog

## 1.1.0 — 2026-09-17

- `candidate.sh check`: the shell gate no longer passes silently — with Docker down and no shellcheck it says so, and FAILS when the change touches `scripts/`.
- `candidate.sh check`: falls back to the on-PATH `shellcheck --severity=warning` when the pinned container cannot run, and says that is what ran.
- `candidate.sh pr`: shows the check re-run's summary lines under a header instead of swallowing them, with the candidate's own `warning:` lines prefixed `candidate: `.
- `experience.sh summary`/`diff`: item counts `items_cr`, `items_blocked`, `items_corr`, `items_rev` beside the event counts they qualify.
- `experience.sh list`/`show`: `docs_missing` displays gate-doc gaps only (`events`/`harness` dropped, raw column untouched) and `list` gained a `source` column.
- `AGENTS.md`: a "Reading the store" subsection — `source`, event counts vs item counts, `docs_missing` vs `items_with_gaps`, and which items have traces.

## 1.0.0 — 2026-09-16

Initial toolkit: experience.sh, candidate.sh, validate.sh, proposer instructions.
