//go:build darwin

package local

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/hash"
	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
)

func TestReadAheadForFilesystem(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data")
	require.NoError(t, os.WriteFile(path, make([]byte, 4096), 0600))
	t.Run("ordinary filesystem", func(t *testing.T) {
		checkReadAhead(t, path, false)
	})
	t.Run("exfat read-only integration", func(t *testing.T) {
		path := os.Getenv("RCLONE_TEST_EXFAT_READ_FILE")
		if path == "" {
			t.Skip("set RCLONE_TEST_EXFAT_READ_FILE to an existing exFAT file of at least 4096 bytes")
		}
		checkReadAhead(t, path, true)
	})
}

func checkReadAhead(t *testing.T, path string, wantDisabled bool) {
	t.Helper()
	control, err := os.Open(path)
	require.NoError(t, err)
	defer func() { require.NoError(t, control.Close()) }()
	before, err := control.Stat()
	require.NoError(t, err)
	var stat unix.Statfs_t
	require.NoError(t, unix.Fstatfs(int(control.Fd()), &stat))
	require.Equal(t, wantDisabled, unix.ByteSliceToString(stat.Fstypename[:]) == "exfat")

	originalFlags, err := unix.FcntlInt(control.Fd(), unix.F_GETFL, 0)
	require.NoError(t, err)
	_, err = unix.FcntlInt(control.Fd(), unix.F_RDAHEAD, 0)
	require.NoError(t, err)
	disabledFlags, err := unix.FcntlInt(control.Fd(), unix.F_GETFL, 0)
	require.NoError(t, err)
	noReadAheadFlag := originalFlags ^ disabledFlags
	require.NotZero(t, noReadAheadFlag)

	ctx := context.Background()
	f, err := NewFs(ctx, "local", filepath.Dir(path), configmap.Simple{})
	require.NoError(t, err)
	o, err := f.NewObject(ctx, filepath.Base(path))
	require.NoError(t, err)
	reader, err := o.Open(ctx, &fs.HashesOption{Hashes: hash.NewHashSet()})
	require.NoError(t, err)
	defer func() { require.NoError(t, reader.Close()) }()
	fd, ok := reader.(*os.File)
	require.True(t, ok)
	flags, err := unix.FcntlInt(fd.Fd(), unix.F_GETFL, 0)
	require.NoError(t, err)
	require.Equal(t, wantDisabled, flags&noReadAheadFlag != 0, "exFAT readers must not issue speculative read-ahead")
	require.Equal(t, unix.O_RDONLY, flags&unix.O_ACCMODE)

	want, got := make([]byte, 4096), make([]byte, 4096)
	_, err = io.ReadFull(control, want)
	require.NoError(t, err)
	_, err = io.ReadFull(reader, got)
	require.NoError(t, err)
	require.Equal(t, want, got)
	after, err := control.Stat()
	require.NoError(t, err)
	require.Equal(t, before.Size(), after.Size())
	require.Equal(t, before.ModTime(), after.ModTime())
}
