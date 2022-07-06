# envdiff
envfile diff tool

## Installation

```sh
go install github.com/yoskeoka/envdiff@latest
```

## Usage

Print environment variables that the file2 contains more.

```sh
envdiff file1 file2
```

```sh
$ envdiff -help
Usage of envdiff:
  -cmpval
        compare value (default: off)
  -filter value
        Filter by env key pattern. Multi filters may be specified. e.g: -filter="KEY_*"
  -ignore value
        Ignore by env key pattern. Multi ignores may be specified. e.g: -ignore="FOO_*"

Example: envdiff envfile1 envfile2
```

## Example

file1

```env
KEY1=VAL1
```

file2

```env
KEY1=VAL1
KEY2=VAL2
```

```sh
$ envdiff file1 file2
KEY2=VAL2
```
