# GitHub Actions Pinning

GitHub Actions workflow files and composite actions in this repository must manage `uses:` references through `pinact`.

## Operator Contract

- When editing `.github/workflows/*.yml` or `.github/actions/**`, use `pinact` to pin new `uses:` references and to update existing pinned references.
- Do not hand-edit floating version tags such as `@v2` when the change is intended to pin or refresh an action dependency; run `pinact` instead and review the resulting diff.
- It is acceptable to scope a rollout by passing explicit file paths to `pinact run` when only part of the repository should be updated.
- `.pinact.yaml` is optional and should be added only when explicit file arguments are insufficient to avoid out-of-scope workflow files.
