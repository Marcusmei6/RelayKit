package launchsocket

import "testing"

func TestActivateRejectsEmptyName(t *testing.T) {
	if listener, err := Activate(""); err == nil || listener != nil {
		t.Fatal("empty launchd socket name was accepted")
	}
}
