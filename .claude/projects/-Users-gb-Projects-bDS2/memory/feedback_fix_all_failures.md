---
name: Fix all test failures
description: Never dismiss test failures as pre-existing — if tests fail after changes, fix them
type: feedback
---

All test failures after changes must be fixed, even if they appear unrelated. The test suite was clean before, so any failure is the responsibility of the current change.

**Why:** The user confirmed the suite was green before. Dismissing failures as "pre-existing" is wrong and wastes time.

**How to apply:** After making changes, if any test fails, investigate and fix it before reporting the task as done. Never stash/skip/ignore failures.
