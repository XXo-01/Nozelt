//go:build windows

package main

import (
	"strings"
	"testing"
)

func TestNativeLogsDoNotExportCredentials(t *testing.T) {
	for _, line := range []string{
		`invalid configuration {"password":"do-not-export"}`,
		`privateKey: do-not-export`,
		`fetch https://user:do-not-export@example.test/sub/do-not-export?token=do-not-export`,
		`invalid vless://do-not-export@example.test:443?security=tls`,
	} {
		if strings.Contains(privateLogMessage(line), "do-not-export") {
			t.Fatal("credential reached desktop log", line)
		}
	}
	if privateLogMessage("xray: transport failed: connection refused") != "xray: transport failed: connection refused" {
		t.Fatal("ordinary error hidden")
	}
}
