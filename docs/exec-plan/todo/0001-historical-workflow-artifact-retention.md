# Historical workflow artifact retention

> **Execution**: Use `/execute-task` to implement this plan. After implementation is complete, use `/review-task` to prepare and create the PR.

## Objective

Keep completed execution plans and local issues out of the checked-out tree so
ordinary search returns only active trackers. Plan PRs, implementation PRs, and
Git history retain the audit trail; commit messages remain concise summaries.

## Changes

- (MODIFY) `AGENTS.md`, `docs/exec-plan/todo/README.md`, `docs/issues/README.md`, and workflow documentation to replace move-to-`done/` guidance with deletion after verified completion.
- (MODIFY) `tools/workflow-lint.sh` and its tests: require an active matching plan before implementation, then validate closeout from the deleted plan in the diff base and require deletion of linked local issues; preserve external GitHub closure checks.
- (DELETE) `docs/exec-plan/done/**`, `docs/issues/done/**`, and empty directories.

## Verification

Exercise active-plan, compliant deletion, missing-linked-issue, and external-issue cases; run `go test ./...`, `make build`, the workflow linter, `git diff --check`, and confirm removed records remain discoverable with `git log --all -- docs/exec-plan`.
