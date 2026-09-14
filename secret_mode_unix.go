//go:build !windows

package main

import "os"

func secretFileModeIsSecure(mode os.FileMode) bool {
	return mode.Perm()&0o077 == 0
}
