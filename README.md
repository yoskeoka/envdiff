# envdiff
envfile diff tool

## Usage

Print environment variables that the file2 contains more.

```sh
envdiff file1 file2
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
