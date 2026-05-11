---
name: Debug targeted, don't brute-force
description: When investigating flaky tests, analyze the code and fix — don't brute-force with repeated full suite runs
type: feedback
---

If you already know which test is failing and why, fix it. Don't waste time running the full suite 20 times hoping to capture output.

**Why:** It's slow, wasteful, and avoids thinking. Analyze the code, understand the race, fix it.

**How to apply:** When a test fails, read the test, understand what it does, identify the root cause, and fix it. Only re-run to verify the fix, not to gather more data you already have.
