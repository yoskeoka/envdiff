# envdiff — envfile diff tool

## Build & Test

```bash
make build    # Build binary with version info
go test ./... # Run all tests
```

## Project Structure

```
main.go           # CLI entry point and core diff logic
main_test.go      # Tests
docs/specs/       # Behavioral specs (no implementation details)
docs/exec-plan/   # Execution plans (todo/ and done/)
docs/issues/      # Known issues
```

## Workflow

This project follows the AI-Centered Development workflow defined in the parent workspace:

1. **Spec first**: Update `docs/specs/` before changing code.
2. **Plan first**: Non-trivial changes need an execution plan in `docs/exec-plan/todo/`, using active filenames of the form `<sequence>-<name>.md`.
3. **Log issues**: Unrelated problems found during work go in `docs/issues/` using active filenames of the form `<sequence>-<name>.md`.
4. **PR for everything**: All changes go through GitHub PR review.
5. **GitHub Actions pinning**: When editing GitHub Actions workflows or composite actions, use `pinact` to pin or update `uses:` references rather than hand-editing version tags.
