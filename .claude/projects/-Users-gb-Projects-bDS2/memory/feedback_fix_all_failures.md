---
name: Fix all test failures including flaky ones
description: Never dismiss test failures as pre-existing or flaky — investigate root cause and stabilize
type: feedback
---

All test failures must be fixed, even if they appear unrelated to current changes. The test suite was clean before, so any failure is my responsibility.

Flaky tests are deeper problems waiting to surface. Running a test in isolation and seeing it pass is never enough — must find out why it was flaky in the full suite run and make it stable.

**Why:** Dismissing failures as "pre-existing" or "flaky" is wrong. Flaky tests indicate real issues (race conditions, test pollution, shared state) that will bite harder later.

**How to apply:** After making changes, if any test fails: investigate the root cause, fix it, and verify it passes reliably in the full suite. Never stash, never skip, never re-run and hope. Never dismiss ordering-dependent failures — find and fix the shared state or race condition.
