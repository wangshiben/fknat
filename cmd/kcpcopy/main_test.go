package main

import (
	"bytes"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoopbackCopy(t *testing.T) {
	portProbe, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := portProbe.LocalAddr().(*net.UDPAddr).Port
	if err := portProbe.Close(); err != nil {
		t.Fatal(err)
	}

	sourceDirectory := t.TempDir()
	destinationDirectory := t.TempDir()
	sourcePath := filepath.Join(sourceDirectory, "payload.bin")
	payload := bytes.Repeat([]byte("fknat-kcp-copy\n"), 8192)
	if err := os.WriteFile(sourcePath, payload, 0600); err != nil {
		t.Fatal(err)
	}
	key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	address := fmt.Sprintf("127.0.0.1:%d", port)
	receiverOptions := options{
		mode: "receive", address: address, destination: destinationDirectory, keyHex: key,
		sendWindow: 256, receiveWindow: 1024, timeout: 10 * time.Second,
	}
	senderOptions := options{
		mode: "send", address: address, keyHex: key,
		sendWindow: 256, receiveWindow: 1024, timeout: 10 * time.Second,
	}
	receiverResult := make(chan error, 1)
	go func() { receiverResult <- run(receiverOptions, nil) }()
	time.Sleep(50 * time.Millisecond)
	if err := run(senderOptions, []string{sourcePath}); err != nil {
		t.Fatal(err)
	}
	if err := <-receiverResult; err != nil {
		t.Fatal(err)
	}
	actual, err := os.ReadFile(filepath.Join(destinationDirectory, "payload.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, payload) {
		t.Fatal("copied payload does not match source")
	}
}
