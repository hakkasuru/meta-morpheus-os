---
id: T-20260102-a3
type: task
title: "Fixture item a3 (legacy: no run record)"
status: done
repos: [demo]
epic: null
created: 2026-01-02
updated: 2026-01-03
mr: https://example.invalid/mr/4
harness: 1.1.0+bbbbbbb
workspace_rev: abcdef1
---

## Request

Fixture request for a3. This item predates the run record: no events.log and
no trace/, so its scorecard row is reconstructed (source: legacy) and its
docs_missing names `events` alongside the gate doc it really lacks.

## Acceptance Criteria

- [x] fixture

## Activity

- 2026-01-02 — created
- 2026-01-02 — plan review round 1: changes requested
- 2026-01-02 — plan review round 2: changes requested
- 2026-01-03 — merged: https://example.invalid/mr/4
