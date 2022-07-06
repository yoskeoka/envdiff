package main

import (
	"reflect"
	"regexp"
	"testing"

	"github.com/google/go-cmp/cmp"
)

func TestDiff(t *testing.T) {
	type args struct {
		a    []EnvVar
		b    []EnvVar
		opts []DiffOption
	}
	tests := []struct {
		name string
		args args
		want []EnvVar
	}{
		{
			name: "no diff",
			args: args{
				[]EnvVar{{"ENV1", "KEY1"}},
				[]EnvVar{{"ENV1", "KEY1"}},
				[]DiffOption{},
			},
			want: []EnvVar{},
		},
		{
			name: "a has more",
			args: args{
				[]EnvVar{
					{"ENV1", "KEY1"},
					{"ENV2", "KEY2"},
				},
				[]EnvVar{
					{"ENV1", "KEY1"},
				},
				[]DiffOption{},
			},
			want: []EnvVar{},
		},
		{
			name: "b has more",
			args: args{
				[]EnvVar{{"ENV1", "KEY1"}},
				[]EnvVar{
					{"ENV1", "KEY1"},
					{"ENV2", "KEY2"},
				},
				[]DiffOption{},
			},
			want: []EnvVar{
				{"ENV2", "KEY2"},
			},
		},
		{name: "b has diff value",
			args: args{
				[]EnvVar{
					{"ENV1", "KEY1"},
					{"ENV2", "KEY2"},
				},
				[]EnvVar{
					{"ENV1", "KEY1"},
					{"ENV2", "KEY33"},
				},
				[]DiffOption{DiffOptionCompareValue(true)},
			},
			want: []EnvVar{
				{"ENV2", "KEY33"},
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Diff(tt.args.a, tt.args.b, tt.args.opts...)
			sortEnvVar(tt.want)
			sortEnvVar(got)

			if d := cmp.Diff(tt.want, got); d != "" {
				t.Errorf("Diff(a, b) got wrong result: \n%s", d)
			}
		})
	}
}

func TestParseEnvLine(t *testing.T) {

	tests := []struct {
		name   string
		line   string
		wantEv EnvVar
		wantOk bool
	}{
		{"env var",
			"KEY1=VAL1",
			EnvVar{Key: "KEY1", Val: "VAL1"},
			true,
		},
		{"env var with space",
			" KEY1 = VAL1 ",
			EnvVar{Key: "KEY1", Val: "VAL1"},
			true,
		},
		{"line comment",
			" # KEY1 = VAL1 ",
			EnvVar{},
			false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotEv, gotOk := ParseEnvLine(tt.line)
			if !reflect.DeepEqual(gotEv, tt.wantEv) {
				t.Errorf("ParseEnvLine() gotEv = %v, want %v", gotEv, tt.wantEv)
			}
			if gotOk != tt.wantOk {
				t.Errorf("ParseEnvLine() gotOk = %v, want %v", gotOk, tt.wantOk)
			}
		})
	}
}

func TestWildcardToRegexStr(t *testing.T) {

	tests := []struct {
		wc   string
		want string
	}{
		{"", `^$`},
		{"*", `^.*$`},
		{"?", `^.$`},
		{"ab?", `^ab.$`},
		{"FOO_*", `^FOO_.*$`},
	}
	for _, tt := range tests {
		t.Run(tt.wc, func(t *testing.T) {
			got := WildcardToRegexStr(tt.wc)
			if got != tt.want {
				t.Errorf("WildcardToRegexStr() = %v, want %v", got, tt.want)
			}
			if _, regExErr := regexp.Compile(got); regExErr != nil {
				t.Errorf("WildcardToRegexStr() returns an invalid regexp pattern: %s", got)
			}
		})
	}
}
