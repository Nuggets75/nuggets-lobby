//go:build !windows

package main

// Only Windows needs the job object; other builds exist so the argument
// logic can be tested on any machine.
func killChildrenWithMe() error { return nil }
