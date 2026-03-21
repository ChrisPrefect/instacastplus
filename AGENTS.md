## Agent Instructions

- Run builds/tests only for larger changes.
- For small changes, do not run builds/tests; the user verifies directly.
- If build/test verification is needed but not executed, provide exact commands for the user.
- When I report a bug, don't start by trying to fix it. Instead, start by writing a test that reproduces the bug. Then, have subagents try to fix the bug and prove it with a passing test.
