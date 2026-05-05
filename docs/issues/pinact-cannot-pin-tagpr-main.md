# pinact cannot pin `Songmu/tagpr@main`

## Summary

During the `pinact` rollout, `pinact run` failed on this step:

```text
.github/workflows/tagpr.yml:11
- uses: Songmu/tagpr@main
```

`pinact` still pinned the surrounding `actions/checkout` reference in `tagpr.yml` and the supported action references in the other workflow files.

## Impact

- The repository now follows the `pinact` operator path for supported action references.
- `Songmu/tagpr@main` remains mutable and outside the current rollout's automatic pinning.

## Follow-up

- Confirm whether `Songmu/tagpr` exposes a supported immutable release/tag strategy that `pinact` can manage.
- If not, decide whether this workflow should keep `@main`, switch to a different supported ref policy, or adopt an explicit exception mechanism.
