//go:build windows

package main

import "os"

func secretFileModeIsSecure(os.FileMode) bool {
	// Windows access is controlled by ACLs; FileMode permission bits are synthesized.
	return true
}
