package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"sort"
	"strings"
)

func main() {
	code := mainRealm()
	os.Exit(code)
}

func mainRealm() int {
	fs := flag.NewFlagSet("envdiff", flag.ExitOnError)
	err := fs.Parse(os.Args)
	if err != nil {
		return 1
	}

	if len(fs.Args()) < 3 {
		fs.Usage()
		fmt.Println("Example: envdiff envfile1 envfile2")
		return 1
	}

	file1name := fs.Arg(1)
	file2name := fs.Arg(2)

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

	d := Diff(evf1, evf2)

	if len(d) == 0 {
		return 0
	}

	for _, item := range d {
		fmt.Printf("%s=%v", item.Key, item.Val)
	}

	return 1
}

// EnvVar represents an environment variable.
type EnvVar struct {
	Key string
	Val string
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

func Diff(a, b []EnvVar) []EnvVar {
	am := listToMap(a)
	bm := listToMap(b)

	d := make([]EnvVar, 0, len(b))

	for bk, bv := range bm {
		if _, aHasB := am[bk]; !aHasB {
			d = append(d, EnvVar{Key: bk, Val: bv})
		}
	}
	return d
}
