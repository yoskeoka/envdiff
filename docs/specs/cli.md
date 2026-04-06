# CLI Specification

## Overview

`envdiff` is a command-line tool that compares two environment variable files and outputs the variables present in the second file but missing from (or different in) the first file.

## Usage

```
envdiff [flags] <file1> <file2>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `file1`  | Yes      | Path to the base env file |
| `file2`  | Yes      | Path to the env file to compare against |

## Flags

| Flag       | Type    | Default | Description |
|------------|---------|---------|-------------|
| `-help`    | bool    | false   | Print usage message and exit with code 1 |
| `-version` | bool    | false   | Print version and git commit, exit with code 0 |
| `-check`   | bool    | false   | Exit with code 1 if any diff is found |
| `-cmpval`  | bool    | false   | Compare values in addition to keys |
| `-filter`  | string  | (none)  | Only include keys matching this wildcard pattern. May be specified multiple times. |
| `-ignore`  | string  | (none)  | Exclude keys matching this wildcard pattern. May be specified multiple times. |

## Behavior

### Default mode (key-only comparison)

1. Parse both files into lists of environment variables.
2. Apply `-filter` patterns to both lists (keep only matching keys). If no filter is specified, all keys pass.
3. Apply `-ignore` patterns to both lists (remove matching keys).
4. For each key in `file2` that does NOT exist in `file1`, output `KEY=VALUE` (using `file2`'s value).
5. Keys present in `file1` but not in `file2` are silently ignored (not reported).

### Value comparison mode (`-cmpval`)

In addition to missing keys, also output keys where the value in `file2` differs from `file1`.

### Exit codes

| Code | Condition |
|------|-----------|
| 0    | No diff found, or diff found but `-check` not set |
| 1    | `-check` is set and diff was found |
| 1    | `-help` flag or insufficient arguments |
| 1    | File open error or parse error |

### Output format

Each diff entry is printed as one line to stdout:

```
KEY=VALUE
```

Output order is non-deterministic (map iteration order).

## Wildcard Patterns

The `-filter` and `-ignore` flags accept wildcard patterns with the following syntax:

| Wildcard | Matches |
|----------|---------|
| `*`      | Zero or more of any character |
| `?`      | Exactly one of any character |

Patterns are anchored: they must match the entire key (equivalent to `^pattern$` in regex).

Multiple `-filter` flags are OR-combined: a key passes if it matches ANY filter.
Multiple `-ignore` flags are OR-combined: a key is excluded if it matches ANY ignore pattern.

When both `-filter` and `-ignore` are specified, filter is applied first, then ignore.
