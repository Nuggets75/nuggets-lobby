package main

import (
	"path/filepath"
	"regexp"
	"strings"
)

// Must sit next to the game executable for the custom lobby to switch on.
// It holds the custom lobby's additions to the game's init.
const markerName = "init_nuggets.lua"

// Written next to the game before every launch. It runs the init file the
// client asked for, then init_nuggets.lua.
const launchName = "init_nuggets_launch.lua"

// The init files clients pass: the Java client uses "init.lua" (a copy it
// makes before each launch), the Rust client "init_<featured mod>.lua" such
// as init_faf.lua. Letters and digits only, so the name can be written into
// a Lua string without escaping.
var baseInitPattern = regexp.MustCompile(`(?i)^init(_[a-z0-9]+)?\.lua$`)

// planLaunch decides whether this launch gets the custom lobby.
//
// It does when init_nuggets.lua sits next to the game and the arguments
// contain "/init <one of the client init files>". Replays run from a
// different folder (replaydata\bin) where init_nuggets.lua does not exist, so
// they pass through unchanged.
//
// Returns the arguments to start the game with, the client's init file name,
// and whether the custom lobby applies. The input slice is never modified.
// The caller must write the launch file before using the new arguments.
func planLaunch(exe string, args []string, exists func(string) bool) ([]string, string, bool) {
	out := make([]string, len(args))
	copy(out, args)

	if !exists(filepath.Join(filepath.Dir(exe), markerName)) {
		return out, "", false
	}
	for i := 0; i+1 < len(out); i++ {
		if !strings.EqualFold(out[i], "/init") {
			continue
		}
		base := out[i+1]
		if !baseInitPattern.MatchString(base) || strings.EqualFold(base, markerName) {
			return out, "", false
		}
		out[i+1] = launchName
		return out, base, true
	}
	return out, "", false
}

// launchScript is the content of init_nuggets_launch.lua for a given client
// init file. base has already passed baseInitPattern.
func launchScript(base string) string {
	return "-- Written by nuggets-lobby\\wrapper.exe before every launch. Edits are overwritten.\n" +
		"-- Runs the init file the client asked for, then the custom lobby's additions.\n" +
		"dofile(InitFileDir .. '/" + base + "')\n" +
		"dofile(InitFileDir .. '/" + markerName + "')\n"
}
