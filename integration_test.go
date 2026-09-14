package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	sdk "github.com/wangshiben/natP2pSDK"
	"github.com/wangshiben/natP2pSDK/tunnel"
)

type memoryConnection struct {
	peer      sdk.Peer
	incoming  <-chan sdk.Message
	outgoing  chan<- sdk.Message
	closed    chan struct{}
	closeOnce *sync.Once
}

func newMemoryConnectionPair() (*memoryConnection, *memoryConnection) {
	clientToServer := make(chan sdk.Message, 256)
	serverToClient := make(chan sdk.Message, 256)
	closed := make(chan struct{})
	closeOnce := &sync.Once{}
	clientID := sdk.NodeID(strings.Repeat("a", 64))
	serverID := sdk.NodeID(strings.Repeat("b", 64))
	return &memoryConnection{
			peer: sdk.Peer{ID: serverID}, incoming: serverToClient, outgoing: clientToServer,
			closed: closed, closeOnce: closeOnce,
		}, &memoryConnection{
			peer: sdk.Peer{ID: clientID}, incoming: clientToServer, outgoing: serverToClient,
			closed: closed, closeOnce: closeOnce,
		}
}

func (connection *memoryConnection) Peer() sdk.Peer { return connection.peer }

func (connection *memoryConnection) Send(ctx context.Context, message sdk.Message) error {
	message.Payload = append([]byte(nil), message.Payload...)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-connection.closed:
		return net.ErrClosed
	case connection.outgoing <- message:
		return nil
	}
}

func (connection *memoryConnection) Receive(ctx context.Context) (sdk.Message, error) {
	select {
	case <-ctx.Done():
		return sdk.Message{}, ctx.Err()
	case <-connection.closed:
		return sdk.Message{}, net.ErrClosed
	case message := <-connection.incoming:
		message.Payload = append([]byte(nil), message.Payload...)
		return message, nil
	}
}

func (connection *memoryConnection) Close() error {
	connection.closeOnce.Do(func() { close(connection.closed) })
	return nil
}

type singleConnectionDialer struct {
	connection sdk.Connection
	mu         sync.Mutex
	used       bool
}

func (dialer *singleConnectionDialer) Dial(context.Context, sdk.NodeID) (sdk.Connection, error) {
	dialer.mu.Lock()
	defer dialer.mu.Unlock()
	if dialer.used {
		return nil, errors.New("test connection already used")
	}
	dialer.used = true
	return dialer.connection, nil
}

func TestClientSessionManagerToServerTCPForwarding(t *testing.T) {
	backend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	backendDone := make(chan struct{})
	go func() {
		defer close(backendDone)
		connection, acceptErr := backend.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		_, _ = io.Copy(connection, connection)
	}()

	clientConnection, serverConnection := newMemoryConnectionPair()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	logger := log.New(io.Discard, "", 0)
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		serveClientConnection(ctx, serverConnection, backend.Addr().String(), logger)
	}()

	target := sdk.NodeID(strings.Repeat("b", 64))
	manager := &clientSessionManager{
		dialer: &singleConnectionDialer{connection: clientConnection},
		target: target, reconnectDelay: time.Millisecond, logger: logger,
	}
	if err := manager.Connect(ctx); err != nil {
		t.Fatalf("Connect: %v", err)
	}
	stream, err := manager.OpenStream(ctx)
	if err != nil {
		t.Fatalf("OpenStream: %v", err)
	}
	localTunnel, localApplication := net.Pipe()
	bridgeDone := make(chan error, 1)
	go func() {
		bridgeDone <- compressedBridge(localApplication, stream, compressionClientMode, tunnel.DefaultCopyOptions())
	}()
	payload := []byte("fknat tunnel integration\n")
	if _, err := localTunnel.Write(payload); err != nil {
		t.Fatalf("Write: %v", err)
	}
	response := make(chan []byte, 1)
	readError := make(chan error, 1)
	go func() {
		buffer := make([]byte, len(payload))
		_, readErr := io.ReadFull(localTunnel, buffer)
		if readErr != nil {
			readError <- readErr
			return
		}
		response <- buffer
	}()
	select {
	case actual := <-response:
		if string(actual) != string(payload) {
			t.Fatalf("response = %q, want %q", actual, payload)
		}
	case readErr := <-readError:
		t.Fatalf("ReadFull: %v", readErr)
	case <-ctx.Done():
		t.Fatalf("timed out waiting for forwarded response: %v", ctx.Err())
	}

	_ = localTunnel.Close()
	_ = localApplication.Close()
	select {
	case <-bridgeDone:
	case <-time.After(time.Second):
		t.Fatal("compressed bridge did not stop")
	}
	_ = manager.Close()
	cancel()
	_ = backend.Close()
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("server forwarding goroutine did not stop")
	}
	select {
	case <-backendDone:
	case <-time.After(time.Second):
		t.Fatal("backend goroutine did not stop")
	}
}

func TestServeClientConnectionEnforcesPerSessionStreamLimit(t *testing.T) {
	backend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	acceptedBackend := make(chan net.Conn, 1)
	go func() {
		connection, acceptErr := backend.Accept()
		if acceptErr == nil {
			acceptedBackend <- connection
		}
	}()

	clientConnection, serverConnection := newMemoryConnectionPair()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var logs bytes.Buffer
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		serveClientConnectionWithLimits(ctx, serverConnection, backend.Addr().String(), 1, make(chan struct{}, 2), log.New(&logs, "", 0))
	}()

	clientSession, err := tunnel.NewClientSession(ctx, clientConnection)
	if err != nil {
		t.Fatal(err)
	}
	first, err := clientSession.OpenStream(ctx)
	if err != nil {
		t.Fatalf("open first stream: %v", err)
	}
	var backendConnection net.Conn
	select {
	case backendConnection = <-acceptedBackend:
	case <-ctx.Done():
		t.Fatalf("first stream did not occupy backend: %v", ctx.Err())
	}

	second, err := clientSession.OpenStream(ctx)
	if err != nil {
		t.Fatalf("open second stream: %v", err)
	}
	readDone := make(chan error, 1)
	go func() {
		var buffer [1]byte
		_, readErr := second.Read(buffer[:])
		readDone <- readErr
	}()
	select {
	case readErr := <-readDone:
		if readErr == nil {
			t.Fatal("rejected stream read unexpectedly succeeded")
		}
	case <-ctx.Done():
		t.Fatalf("rejected stream was not closed: %v", ctx.Err())
	}
	if !strings.Contains(logs.String(), "stage=session_stream_limit") {
		t.Fatalf("missing structured rejection log: %s", logs.String())
	}

	_ = second.Close()
	_ = first.Close()
	_ = backendConnection.Close()
	_ = clientSession.Close()
	cancel()
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("limited server did not stop")
	}
}

var _ sdk.Connection = (*memoryConnection)(nil)
