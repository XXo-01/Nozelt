//go:build tools
// +build tools

// Package tools_anchor keeps build-only dependencies discoverable in go.mod.
//
// gomobile/gobind generate the JNI glue for our .aar by importing
// golang.org/x/mobile/bind from a temporary workspace they spin up at build
// time. They locate that import via `go list` against *our* module, so the
// dependency must appear in go.mod even though our runtime code never
// references it directly. Without this anchor file, `go mod tidy` removes
// the require line and gomobile bind fails with
//
//	"golang.org/x/mobile/bind" is not found; run go get golang.org/x/mobile/bind
//
// The `tools` build tag means the file is skipped during normal builds
// (including `go build ./...` and `go test ./...`) — it only feeds the
// dependency graph.
package nozeltcoretools

import (
	_ "golang.org/x/mobile/bind"
)
