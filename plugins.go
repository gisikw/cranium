package main

import (
	"os"
	"path/filepath"
)

// resolvePluginDir returns the absolute path to the plugins directory,
// resolved relative to the running executable's location.
func resolvePluginDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "plugins"
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		return "plugins"
	}
	return filepath.Join(filepath.Dir(exe), "plugins")
}
