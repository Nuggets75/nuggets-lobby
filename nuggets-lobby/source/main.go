// Nuggets custom lobby launcher.
//
// The FAF client starts this program instead of the game, passing the game's
// path followed by the game's arguments. Set it up in the client:
//
//	Rust client: settings.json, "game": { "launchWrapper": "<path>\\wrapper.exe" }
//	Java client: Settings > Forged Alliance > executable decorator: "<path>\wrapper.exe" %s
//
// The wrapper:
//
//   - when init_nuggets.lua sits next to the game, writes init_nuggets_launch.lua
//     there (the client's init file, then init_nuggets.lua) and starts the game
//     with that instead; everything else is passed through unchanged
//     (see planLaunch);
//   - starts the game and waits for it, so the client sees the game as running
//     for exactly as long as it really is;
//   - takes the game down with it if the client kills the wrapper;
//   - returns the game's exit code to the client;
//   - writes what it did to wrapper.log next to itself, overwritten each launch.
//
// To undo everything, clear the setting again.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	logFile := openLog()
	logf := func(format string, a ...any) {
		if logFile != nil {
			fmt.Fprintf(logFile, time.Now().Format("15:04:05 ")+format+"\n", a...)
		}
	}

	if len(os.Args) < 2 {
		logf("no game executable passed: the client setting should be the path to wrapper.exe")
		os.Exit(2)
	}

	exe := os.Args[1]
	original := os.Args[2:]
	args := original
	logf("game: %s", exe)
	logf("client args: %s", strings.Join(original, " "))

	planned, base, ok := planLaunch(exe, original, fileExists)
	if ok {
		launchPath := filepath.Join(filepath.Dir(exe), launchName)
		if err := os.WriteFile(launchPath, []byte(launchScript(base)), 0o644); err != nil {
			logf("custom lobby: off, could not write %s: %v", launchPath, err)
		} else {
			args = planned
			logf("custom lobby: ON (%s runs %s, then %s)", launchName, base, markerName)
		}
	} else {
		logf("custom lobby: off (no %s next to the game, or no client init file in the arguments)", markerName)
	}

	if err := killChildrenWithMe(); err != nil {
		logf("warning: could not tie the game to the wrapper (%v); killing the game from the client may leave it running", err)
	}

	// No stdin/stdout/stderr: the game logs to the file passed with /log.
	// The working directory is inherited from the client.
	cmd := exec.Command(exe, args...)
	if err := cmd.Start(); err != nil {
		logf("failed to start the game: %v", err)
		os.Exit(1)
	}
	logf("game started, pid %d, args: %s", cmd.Process.Pid, strings.Join(args, " "))

	err := cmd.Wait()
	code := 0
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	} else if err != nil {
		logf("error while waiting for the game: %v", err)
		code = 1
	}
	logf("game exited with code %d", code)
	if logFile != nil {
		logFile.Close()
	}
	os.Exit(code)
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

func openLog() *os.File {
	self, err := os.Executable()
	if err != nil {
		return nil
	}
	f, err := os.Create(filepath.Join(filepath.Dir(self), "wrapper.log"))
	if err != nil {
		return nil
	}
	return f
}
