//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

// Windows job objects: every process started by a process inside a job joins
// that job. With KILL_ON_JOB_CLOSE, Windows kills everything in the job when
// the last handle to it closes, which happens when this wrapper exits or is
// killed. So if the client kills the wrapper, the game goes with it.

const (
	jobObjectExtendedLimitInformation = 9
	jobObjectLimitKillOnJobClose      = 0x2000
)

type ioCounters struct {
	ReadOperationCount  uint64
	WriteOperationCount uint64
	OtherOperationCount uint64
	ReadTransferCount   uint64
	WriteTransferCount  uint64
	OtherTransferCount  uint64
}

type jobBasicLimitInformation struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

type jobExtendedLimitInformation struct {
	BasicLimitInformation jobBasicLimitInformation
	IoInfo                ioCounters
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

var (
	kernel32                     = syscall.NewLazyDLL("kernel32.dll")
	procCreateJobObjectW         = kernel32.NewProc("CreateJobObjectW")
	procSetInformationJobObject  = kernel32.NewProc("SetInformationJobObject")
	procAssignProcessToJobObject = kernel32.NewProc("AssignProcessToJobObject")
)

// The job handle is kept for the life of the process and never closed by us.
var jobHandle uintptr

func killChildrenWithMe() error {
	h, _, err := procCreateJobObjectW.Call(0, 0)
	if h == 0 {
		return err
	}

	var info jobExtendedLimitInformation
	info.BasicLimitInformation.LimitFlags = jobObjectLimitKillOnJobClose
	r, _, err := procSetInformationJobObject.Call(
		h,
		jobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		unsafe.Sizeof(info),
	)
	if r == 0 {
		syscall.CloseHandle(syscall.Handle(h))
		return err
	}

	self, err := syscall.GetCurrentProcess()
	if err != nil {
		syscall.CloseHandle(syscall.Handle(h))
		return err
	}
	r, _, err = procAssignProcessToJobObject.Call(h, uintptr(self))
	if r == 0 {
		syscall.CloseHandle(syscall.Handle(h))
		return err
	}

	jobHandle = h
	return nil
}
