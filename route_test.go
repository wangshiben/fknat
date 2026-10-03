package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	sdk "github.com/wangshiben/natP2pSDK"
	"github.com/wangshiben/natP2pSDK/tunnel"
)

func TestRouteHeaderRoundTrip(t *testing.T) {
	wire := encodeRouteHeader(routeHeader{ConnectionID: 123, Transport: transportUDP, RemotePort: 5353})
	got, err := decodeRouteHeader(wire)
	if err != nil {
		t.Fatal(err)
	}
	if got.ConnectionID != 123 || got.Transport != transportUDP || got.RemotePort != 5353 {
		t.Fatalf("decoded route header = %+v", got)
	}
}

func TestRouteAckRoundTrip(t *testing.T) {
	var buffer bytes.Buffer
	if err := writeRouteAck(&buffer, routeAck{Accepted: false, Code: 11, Message: "端口被拒绝"}); err != nil {
		t.Fatal(err)
	}
	got, err := readRouteAck(&buffer)
	if err != nil {
		t.Fatal(err)
	}
	if got.Accepted || got.Code != 11 || got.Message != "端口被拒绝" {
		t.Fatalf("decoded route ack = %+v", got)
	}
}

func TestResolveAllowedTarget(t *testing.T) {
	ports := []AllowedPort{{ID: "http", Protocol: "tcp", Port: 8080, Target: "127.0.0.1:18080", Enabled: true}, {ID: "dns", Protocol: "udp", Port: 53, Target: "127.0.0.1:5353", Enabled: true}}
	if target, ok := resolveAllowedTarget(ports, "", routeHeader{Transport: transportTCP, RemotePort: 8080}); !ok || target != "127.0.0.1:18080" {
		t.Fatalf("target=%q ok=%v", target, ok)
	}
	if _, ok := resolveAllowedTarget(ports, "", routeHeader{Transport: transportTCP, RemotePort: 9000}); ok {
		t.Fatal("unexpectedly allowed unlisted port")
	}
	if target, ok := resolveAllowedTarget(ports, "", routeHeader{Transport: transportUDP, RemotePort: 53}); !ok || target != "127.0.0.1:5353" {
		t.Fatalf("udp target=%q ok=%v", target, ok)
	}
	defaultPorts := []AllowedPort{{ID: "default", Protocol: "tcp", Target: "127.0.0.1:19080", Enabled: true}}
	if target, ok := resolveAllowedTarget(defaultPorts, "", routeHeader{Transport: transportTCP, RemotePort: 0}); !ok || target != "127.0.0.1:19080" {
		t.Fatalf("default target=%q ok=%v", target, ok)
	}
	derivedSingleTarget := []AllowedPort{{ID: "derived", Protocol: "tcp", Port: 19080, Target: "127.0.0.1:19080", Enabled: true}}
	if target, ok := resolveAllowedTarget(derivedSingleTarget, "", routeHeader{Transport: transportTCP, RemotePort: 0}); !ok || target != "127.0.0.1:19080" {
		t.Fatalf("single target with implicit route=%q ok=%v", target, ok)
	}
	if target, ok := resolveAllowedTarget(defaultPorts, "", routeHeader{Transport: transportTCP, RemotePort: 9999}); !ok || target != "127.0.0.1:19080" {
		t.Fatalf("default target with ignored route key=%q ok=%v", target, ok)
	}
	if _, ok := resolveAllowedTarget(ports, "127.0.0.1:9999", routeHeader{Transport: transportTCP, RemotePort: 9999}); ok {
		t.Fatal("legacy fallback reopened a port alongside an explicit allow-list")
	}
	if target, ok := resolveAllowedTarget(nil, "127.0.0.1:8080", routeHeader{Transport: transportTCP, RemotePort: 8080}); !ok || target != "127.0.0.1:8080" {
		t.Fatalf("legacy fallback target=%q ok=%v", target, ok)
	}
}

func TestRouteHeaderRejectsReservedBytes(t *testing.T) {
	payload := encodeRouteHeader(routeHeader{ConnectionID: 1, Transport: transportTCP, RemotePort: 80})
	payload[18] = 1
	if _, err := decodeRouteHeader(payload); err == nil || !strings.Contains(err.Error(), "保留") {
		t.Fatalf("error=%v", err)
	}
}

func TestRouteWireUsesNetworkByteOrder(t *testing.T) {
	payload := encodeRouteHeader(routeHeader{ConnectionID: 0x0102030405060708, Transport: transportTCP, RemotePort: 0x1234})
	if binary.BigEndian.Uint64(payload[8:16]) != 0x0102030405060708 || binary.BigEndian.Uint16(payload[16:18]) != 0x1234 {
		t.Fatal("route header is not network byte order")
	}
}

func TestRoutedTCPForwardingAndPortRejection(t *testing.T) {
	backend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	_, backendPortText, _ := net.SplitHostPort(backend.Addr().String())
	var backendPort uint16
	parsed, _ := strconv.ParseUint(backendPortText, 10, 16)
	backendPort = uint16(parsed)
	go func() {
		for {
			connection, acceptErr := backend.Accept()
			if acceptErr != nil {
				return
			}
			go func(c net.Conn) { defer c.Close(); _, _ = io.Copy(c, c) }(connection)
		}
	}()
	clientConnection, serverConnection := newMemoryConnectionPair()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		serveClientConnectionWithRouting(ctx, serverConnection, []AllowedPort{{ID: "echo", Protocol: "tcp", Port: backendPort, Target: backend.Addr().String(), Enabled: true}}, "", 8, make(chan struct{}, 8), log.New(io.Discard, "", 0))
	}()
	manager := &clientSessionManager{dialer: &singleConnectionDialer{connection: clientConnection}, target: sdk.NodeID(strings.Repeat("b", 64)), reconnectDelay: time.Millisecond, logger: log.New(io.Discard, "", 0)}
	if err := manager.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	var next atomic.Uint64
	stream, err := openRoutedStream(ctx, manager, &next, PortMapping{Protocol: "tcp", RemotePort: backendPort, Enabled: true}, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	left, right := net.Pipe()
	bridgeDone := make(chan error, 1)
	go func() {
		bridgeDone <- compressedBridge(left, stream, compressionClientMode, tunnel.DefaultCopyOptions())
	}()
	payload := []byte("routed tcp")
	go func() { _, _ = right.Write(payload) }()
	response := make([]byte, len(payload))
	if _, err := io.ReadFull(right, response); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(response, payload) {
		t.Fatalf("response=%q", response)
	}
	_ = right.Close()
	select {
	case <-bridgeDone:
	case <-time.After(time.Second):
		t.Fatal("bridge did not stop")
	}
	_ = manager.Close()
	cancel()
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("server did not stop")
	}
}

func TestRoutedUDPRequestResponse(t *testing.T) {
	backend, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	_, portText, _ := net.SplitHostPort(backend.LocalAddr().String())
	portNumber, _ := strconv.ParseUint(portText, 10, 16)
	go func() {
		var buffer [2048]byte
		for {
			read, source, readErr := backend.ReadFromUDP(buffer[:])
			if readErr != nil {
				return
			}
			_, _ = backend.WriteToUDP(buffer[:read], source)
		}
	}()
	clientConnection, serverConnection := newMemoryConnectionPair()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		serveClientConnectionWithRouting(ctx, serverConnection, []AllowedPort{{ID: "dns", Protocol: "udp", Port: uint16(portNumber), Target: backend.LocalAddr().String(), Enabled: true}}, "", 8, make(chan struct{}, 8), log.New(io.Discard, "", 0))
	}()
	manager := &clientSessionManager{dialer: &singleConnectionDialer{connection: clientConnection}, target: sdk.NodeID(strings.Repeat("b", 64)), reconnectDelay: time.Millisecond, logger: log.New(io.Discard, "", 0)}
	if err := manager.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	var next atomic.Uint64
	stream, err := openRoutedStream(ctx, manager, &next, PortMapping{Protocol: "udp", RemotePort: uint16(portNumber), Enabled: true}, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	payload := []byte("routed udp")
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(payload)))
	if err := writeAll(stream, length[:]); err != nil {
		t.Fatal(err)
	}
	if err := writeAll(stream, payload); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(stream, length[:]); err != nil {
		t.Fatal(err)
	}
	responseLength := binary.BigEndian.Uint32(length[:])
	response := make([]byte, responseLength)
	if _, err := io.ReadFull(stream, response); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(response, payload) {
		t.Fatalf("response=%q", response)
	}
	_ = manager.Close()
	cancel()
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("server did not stop")
	}
}
