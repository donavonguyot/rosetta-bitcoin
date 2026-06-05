package repo

import (
	"errors"
	"os"
	"path/filepath"
)

func Root() (string, error) {
	if cwd, err := os.Getwd(); err == nil {
		for dir := cwd; ; dir = filepath.Dir(dir) {
			if exists(filepath.Join(dir, "Nodes", "Shared")) && exists(filepath.Join(dir, "Nodes", "Go")) {
				return dir, nil
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
		}
	}
	return "", errors.New("could not locate repository root")
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func Rel(path string) string {
	root, err := Root()
	if err != nil {
		return path
	}
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return path
	}
	return rel
}
