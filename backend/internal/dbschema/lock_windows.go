//go:build windows

package dbschema

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

// Windows has no flock; LockFileEx over the first byte gives the same
// process-exclusive lock and is released when the handle closes.
const lockFileRangeLow, lockFileRangeHigh = 1, 0

// tryLockFile takes an exclusive lock without blocking. It reports false
// when another process holds the lock.
func tryLockFile(file *os.File) (bool, error) {
	overlapped := new(windows.Overlapped)
	err := windows.LockFileEx(
		windows.Handle(file.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0,
		lockFileRangeLow,
		lockFileRangeHigh,
		overlapped,
	)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, windows.ERROR_LOCK_VIOLATION) || errors.Is(err, windows.ERROR_IO_PENDING) {
		return false, nil
	}
	return false, err
}

func unlockFile(file *os.File) error {
	return windows.UnlockFileEx(windows.Handle(file.Fd()), 0, lockFileRangeLow, lockFileRangeHigh, new(windows.Overlapped))
}
