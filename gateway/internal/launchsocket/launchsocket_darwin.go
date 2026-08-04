//go:build darwin

package launchsocket

/*
#include <launch.h>
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"net"
	"os"
	"unsafe"
)

func Activate(name string) (net.Listener, error) {
	if name == "" {
		return nil, fmt.Errorf("launchd socket name is required")
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))

	var descriptors *C.int
	var count C.size_t
	if code := C.launch_activate_socket(cName, &descriptors, &count); code != 0 {
		return nil, fmt.Errorf("launchd socket activation failed: %d", int(code))
	}
	defer C.free(unsafe.Pointer(descriptors))
	if count != 1 || descriptors == nil {
		closeDescriptors(descriptors, count)
		return nil, fmt.Errorf("launchd socket activation returned %d descriptors", uint64(count))
	}

	fd := int(*descriptors)
	file := os.NewFile(uintptr(fd), "relaykit-launchd-listener")
	if file == nil {
		_ = closeFileDescriptor(fd)
		return nil, fmt.Errorf("launchd socket descriptor is invalid")
	}
	listener, err := net.FileListener(file)
	_ = file.Close()
	if err != nil {
		return nil, fmt.Errorf("launchd socket listener failed: %w", err)
	}
	return listener, nil
}

func closeDescriptors(descriptors *C.int, count C.size_t) {
	if descriptors == nil || count == 0 {
		return
	}
	for _, descriptor := range unsafe.Slice(descriptors, int(count)) {
		_ = closeFileDescriptor(int(descriptor))
	}
}

func closeFileDescriptor(descriptor int) error {
	return os.NewFile(uintptr(descriptor), "relaykit-launchd-listener").Close()
}
