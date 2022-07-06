package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"regexp"
	"sort"
	"strings"
)

func main() {
	code := mainRealm()
	os.Exit(code)
}

func mainRealm() int {
	fset := flag.NewFlagSet("envdiff", flag.ExitOnError)

	check := fset.Bool("check", false, "If the result has diff, it exits with code 1.")

	compareValue := fset.Bool("cmpval", false, "compare value (default: off)")
	var filterPatterns []*regexp.Regexp
	fset.Func("filter", `Filter by env key pattern. Multi filters may be specified. e.g: -filter="KEY_*"`, func(v string) error {
		re, err := regexp.Compile(WildcardToRegexStr(v))
		if err != nil {
			return err
		}
		filterPatterns = append(filterPatterns, re)
		return nil
	})

	var ignorePatterns []*regexp.Regexp
	fset.Func("ignore", `Ignore by env key pattern. Multi ignores may be specified. e.g: -ignore="FOO_*"`, func(v string) error {
		re, err := regexp.Compile(WildcardToRegexStr(v))
		if err != nil {
			return err
		}
		ignorePatterns = append(ignorePatterns, re)
		return nil
	})

	err := fset.Parse(os.Args[1:])
	if err != nil {
		return 1
	}

	if len(fset.Args()) < 2 {
		fset.Usage()
		fmt.Println()
		fmt.Println("Example: envdiff envfile1 envfile2")
		return 1
	}

	file1name := fset.Arg(0)
	file2name := fset.Arg(1)

	// catch remaining flags
	err = fset.Parse(fset.Args()[2:])
	if err != nil {
		return 1
	}

	file1, err := os.Open(file1name)
	if err != nil {
		log.Println(err)
		return 1
	}
	file2, err := os.Open(file2name)
	if err != nil {
		log.Println(err)
		return 1
	}

	evf1, err := ReadEnvFile(file1)
	if err != nil {
		log.Println(err)
		return 1
	}

	evf2, err := ReadEnvFile(file2)
	if err != nil {
		log.Println(err)
		return 1
	}

	evf1 = filterEnvVar(evf1, filterPatterns)
	evf1 = ignoreEnvVar(evf1, ignorePatterns)
	evf2 = filterEnvVar(evf2, filterPatterns)
	evf2 = ignoreEnvVar(evf2, ignorePatterns)

	d := Diff(evf1, evf2,
		DiffOptionCompareValue(*compareValue),
	)

	if len(d) == 0 {
		return 0
	}

	for _, item := range d {
		fmt.Println(item)
	}

	if *check {
		return 1
	}

	return 0
}

func WildcardToRegexStr(wc string) string {
	re := wc

	// TODO: validate env var key valid chars + wildcard chars `?*`

	// TODO: support standard wildcard

	// replace
	re = strings.ReplaceAll(re, "?", ".")
	re = strings.ReplaceAll(re, "*", ".*")

	re = "^" + re + "$"
	return re
}

// EnvVar represents an environment variable.
type EnvVar struct {
	Key string
	Val string
}

func (ev EnvVar) String() string {
	return fmt.Sprintf("%s=%v", ev.Key, ev.Val)
}

func ReadEnvFile(file io.Reader) ([]EnvVar, error) {

	envVars := make([]EnvVar, 0, 256)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		ev, ok := ParseEnvLine(scanner.Text())
		if ok {
			envVars = append(envVars, ev)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return envVars, nil
}

// ParseEnvLine parses a line as an env var, then return env var and true as ok.
// If the line is not an env var, e.g: comment or wrong format, then return false as ok.
func ParseEnvLine(line string) (ev EnvVar, ok bool) {
	trimed := strings.TrimSpace(line)
	if strings.HasPrefix(trimed, "#") {
		return ev, false
	}

	ss := strings.SplitN(trimed, "=", 2)
	if len(ss) < 2 {
		return ev, false
	}

	return EnvVar{Key: strings.TrimSpace(ss[0]), Val: strings.TrimSpace(ss[1])}, true
}

func listToMap(list []EnvVar) map[string]string {
	r := make(map[string]string, len(list))
	for _, v := range list {
		r[v.Key] = v.Val
	}
	return r
}

func sortEnvVar(list []EnvVar) {
	sort.SliceStable(list, func(i, j int) bool {
		return list[i].Key < list[j].Key
	})
}

func filterEnvVar(list []EnvVar, filterPatterns []*regexp.Regexp) []EnvVar {
	results := make([]EnvVar, 0, len(list))
	for _, v := range list {
		if matchOr(v.Key, filterPatterns) {
			results = append(results, v)
		}
	}

	return results
}

func ignoreEnvVar(list []EnvVar, ignorePatterns []*regexp.Regexp) []EnvVar {
	results := make([]EnvVar, 0, len(list))
	for _, v := range list {
		if len(ignorePatterns) == 0 || !matchOr(v.Key, ignorePatterns) {
			results = append(results, v)
		}
	}

	return results
}

func matchOr(s string, patterns []*regexp.Regexp) bool {
	if len(patterns) == 0 {
		return true
	}

	for _, re := range patterns {
		if re.MatchString(s) {
			return true
		}
	}

	return false
}

type diffOpts struct {
	CompareValue bool
}

func newDiffOpts(opts []DiffOption) diffOpts {
	do := diffOpts{}
	for _, o := range opts {
		o(&do)
	}
	return do
}

type DiffOption func(*diffOpts)

func DiffOptionCompareValue(cmp bool) DiffOption {
	return func(do *diffOpts) {
		do.CompareValue = cmp
	}
}

func Diff(a, b []EnvVar, opts ...DiffOption) []EnvVar {

	dopts := newDiffOpts(opts)

	am := listToMap(a)
	bm := listToMap(b)

	d := make([]EnvVar, 0, len(b))

	for bk, bv := range bm {
		av, aHasB := am[bk]
		if !aHasB {
			d = append(d, EnvVar{Key: bk, Val: bv})
			continue
		}

		if dopts.CompareValue && !compareEnvVar(av, bv, dopts) {
			d = append(d, EnvVar{Key: bk, Val: bv})
		}
	}
	return d
}

func compareEnvVar(av, bv string, opts diffOpts) bool {
	return av == bv
}
