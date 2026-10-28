package main

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestPlanLaunch(t *testing.T) {
	bin := filepath.Join("C:", "ProgramData", "FAForever", "bin")
	exe := filepath.Join(bin, "ForgedAlliance.exe")
	marker := filepath.Join(bin, "init_nuggets.lua")
	present := func(p string) bool { return p == marker }
	absent := func(string) bool { return false }

	rust := []string{"/windowed", "/size", "1920", "1080", "/init", "init_faf.lua", "/nobugreport", "/gpgnet", "127.0.0.1:1234", "/log", `C:\Users\joshu\AppData\Roaming\FAForever\FAForever Client\data\logs\game_1.log`}
	rustSwapped := append([]string{}, rust...)
	rustSwapped[5] = "init_nuggets_launch.lua"

	java := []string{"/init", "init.lua", "/nobugreport"}

	cases := []struct {
		name   string
		exe    string
		args   []string
		exists func(string) bool
		want   []string
		base   string
		ok     bool
	}{
		{"rust client", exe, rust, present, rustSwapped, "init_faf.lua", true},
		{"java client", exe, java, present, []string{"/init", "init_nuggets_launch.lua", "/nobugreport"}, "init.lua", true},
		{"fafdevelop", exe, []string{"/init", "init_fafdevelop.lua"}, present, []string{"/init", "init_nuggets_launch.lua"}, "init_fafdevelop.lua", true},
		{"case-insensitive", exe, []string{"/INIT", "Init_FAF.lua"}, present, []string{"/INIT", "init_nuggets_launch.lua"}, "Init_FAF.lua", true},
		{"marker missing", exe, rust, absent, rust, "", false},
		{"replay folder", filepath.Join("C:", "ProgramData", "FAForever", "replaydata", "bin", "ForgedAlliance.exe"), rust, present, rust, "", false},
		{"already ours", exe, []string{"/init", "init_nuggets.lua"}, present, []string{"/init", "init_nuggets.lua"}, "", false},
		{"odd name", exe, []string{"/init", "../evil.lua"}, present, []string{"/init", "../evil.lua"}, "", false},
		{"quote in name", exe, []string{"/init", "init_a'.lua"}, present, []string{"/init", "init_a'.lua"}, "", false},
		{"dangling /init", exe, []string{"/nobugreport", "/init"}, present, []string{"/nobugreport", "/init"}, "", false},
		{"no args", exe, []string{}, present, []string{}, "", false},
	}

	for _, c := range cases {
		got, base, ok := planLaunch(c.exe, c.args, c.exists)
		if ok != c.ok || base != c.base || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v base=%q ok=%v, want %v base=%q ok=%v", c.name, got, base, ok, c.want, c.base, c.ok)
		}
	}

	orig := []string{"/init", "init_faf.lua"}
	planLaunch(exe, orig, present)
	if orig[1] != "init_faf.lua" {
		t.Errorf("input slice was modified: %v", orig)
	}
}

func TestLaunchScript(t *testing.T) {
	s := launchScript("init_faf.lua")
	for _, want := range []string{"dofile(InitFileDir .. '/init_faf.lua')", "dofile(InitFileDir .. '/init_nuggets.lua')"} {
		if !strings.Contains(s, want) {
			t.Errorf("launch script missing %q:\n%s", want, s)
		}
	}
	if strings.Index(s, "init_faf.lua") > strings.Index(s, "/init_nuggets.lua") {
		t.Errorf("client init must run before init_nuggets.lua:\n%s", s)
	}
}
