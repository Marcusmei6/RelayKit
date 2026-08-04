//go:build !darwin

package launchsocket

import (
	"fmt"
	"net"
)

func Activate(name string) (net.Listener, error) {
	if name == "" {
		return nil, fmt.Errorf("launchd socket name is required")
	}
	return nil, fmt.Errorf("launchd socket activation is unavailable on this platform")
}
