//go:build !darwin

package local

import "github.com/rclone/rclone/lib/file"

var openFileForRead = file.Open
