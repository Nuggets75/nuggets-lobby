//go:build windows && amd64

package main

import "unsafe"

// JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 144 bytes on 64-bit Windows.
// These two lines fail to compile if the Go struct ever drifts from that.
var _ [144 - unsafe.Sizeof(jobExtendedLimitInformation{})]byte
var _ [unsafe.Sizeof(jobExtendedLimitInformation{}) - 144]byte
