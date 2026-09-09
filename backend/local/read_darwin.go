//go:build darwin

package local

import (
	"os"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/lib/file"
	"golang.org/x/sys/unix"
)

func openFileForRead(name string) (*os.File, error) {
	fd, err := file.Open(name)
	if err != nil {
		return nil, err
	}
	var stat unix.Statfs_t
	if err := unix.Fstatfs(int(fd.Fd()), &stat); err != nil {
		fs.Debugf(name, "Failed to inspect filesystem for read advice: %v", err)
		return fd, nil
	}
	if unix.ByteSliceToString(stat.Fstypename[:]) == "exfat" {
		// Parallel exFAT readers can generate excessive speculative I/O.
		if _, err := unix.FcntlInt(fd.Fd(), unix.F_RDAHEAD, 0); err != nil {
			fs.Debugf(name, "Failed to disable exFAT read-ahead: %v", err)
		}
	}
	return fd, nil
}
