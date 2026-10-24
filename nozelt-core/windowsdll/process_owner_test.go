//go:build windows

package main

import (
	"github.com/metacubex/mihomo/component/process"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWindowsLoopbackSocketProcessOwner(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	connection, err := net.Dial("tcp4", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	accepted, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer accepted.Close()
	source := connection.LocalAddr().(*net.TCPAddr)
	_, path, err := process.FindProcessName("tcp", netip.MustParseAddr(source.IP.String()), source.Port)
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.EqualFold(filepath.Base(path), filepath.Base(executable)) {
		t.Fatal("wrong TCP process owner")
	}
}

func TestWindowsUDPSocketProcessOwner(t *testing.T) {
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	source := socket.LocalAddr().(*net.UDPAddr)
	_, path, err := process.FindProcessName("udp", netip.MustParseAddr(source.IP.String()), source.Port)
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil || !strings.EqualFold(filepath.Base(path), filepath.Base(executable)) {
		t.Fatal("wrong UDP process owner", err)
	}
}
