package surface

import "os"

func RuntimeSurface() string {
	value := os.Getenv("GOBITNODE_RUNTIME_SURFACE")
	if value == "" {
		return "host"
	}
	return value
}
