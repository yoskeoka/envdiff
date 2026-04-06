# Env File Format Specification

## Overview

Defines how `envdiff` parses environment variable files.

## Line Format

Each line is parsed independently. A valid env var line has the form:

```
KEY=VALUE
```

### Parsing Rules

1. Leading and trailing whitespace on the line is trimmed.
2. The line is split on the first `=` character.
3. The key (left side) and value (right side) are each trimmed of leading/trailing whitespace.
4. Lines without an `=` character are silently skipped.
5. Lines starting with `#` (after whitespace trimming) are treated as comments and skipped.

### Examples

| Input Line         | Parsed Key | Parsed Value | Valid? |
|--------------------|------------|--------------|--------|
| `KEY1=VAL1`        | `KEY1`     | `VAL1`       | Yes    |
| ` KEY1 = VAL1 `   | `KEY1`     | `VAL1`       | Yes    |
| `# KEY1=VAL1`      | —          | —            | No (comment) |
| ` # KEY1=VAL1`     | —          | —            | No (comment) |
| `KEY_ONLY`         | —          | —            | No (no `=`) |
| `KEY=`             | `KEY`      | (empty)      | Yes    |
| `KEY=A=B`          | `KEY`      | `A=B`        | Yes (split on first `=`) |

## Duplicate Keys

If a file contains duplicate keys, the last occurrence wins (standard map insertion behavior).
