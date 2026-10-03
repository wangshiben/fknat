package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	sdk "github.com/wangshiben/natP2pSDK"
	"github.com/wangshiben/natP2pSDK/natserver"
	"github.com/wangshiben/natP2pSDK/tunnel"
)

func runServer(ctx context.Context, config appConfig, output io.Writer, logger *log.Logger) error {
	server, err := natserver.New(natserver.Config{
		IndexAddress:           config.IndexAddress,
		RelayAddress:           config.RelayAddress,
		RelayAddresses:         config.RelayAddresses,
		RelayCount:             config.RelayCount,
		Identity:               config.IdentityFile,
		BillingPrivateSnapshot: config.BillingSnapshotFile,
		CAURL:                  caURLForConfig(config),
		MaxSessions:            config.MaxSessions,
		AcceptQueue:            config.AcceptQueue,
	})
	if err != nil {
		return fmt.Errorf("创建 NatServer: %w", err)
	}
	listener, err := server.Listen(ctx)
	if err != nil {
		_ = server.Close()
		return fmt.Errorf("启动 NatServer: %w", err)
	}
	var sessions sync.WaitGroup
	streamSlots := make(chan struct{}, config.MaxStreams)
	defer func() {
		_ = listener.Close()
		_ = server.Close()
		sessions.Wait()
	}()

	snapshot := listener.Snapshot()
	fmt.Fprintln(output, "=== fknat Server 已就绪 ===")
	fmt.Fprintf(output, "本节点 ID: %s\n", server.NodeID())
	fmt.Fprintf(output, "实际 TCP 应用: %s\n", config.ForwardTarget)
	if len(config.RelayAddresses) != 0 {
		fmt.Fprintf(output, "服务 Relays: %s\n", strings.Join(config.RelayAddresses, ", "))
	} else if config.RelayAddress != "" {
		fmt.Fprintf(output, "服务 Relay: %s\n", config.RelayAddress)
	} else {
		fmt.Fprintf(output, "服务 Relay: %s\n", snapshot.RelayAddress)
	}
	fmt.Fprintf(output, "最大 NatClient 会话: %d\n", snapshot.MaxSessions)
	fmt.Fprintf(output, "最大并发逻辑流: %d（每会话 %d）\n", config.MaxStreams, config.MaxStreamsPerSession)
	fmt.Fprintln(output, "把上面的节点 ID 提供给 Client。按 Ctrl+C 退出。")

	for {
		connection, acceptErr := listener.Accept(ctx)
		if acceptErr != nil {
			if ctx.Err() != nil || errors.Is(acceptErr, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("接受 NatClient 会话: %w", acceptErr)
		}
		peer := connection.Peer()
		logger.Printf("NatClient %s 已连接", peer.ID)
		sessions.Add(1)
		go func(clientConnection sdk.Connection) {
			defer sessions.Done()
			serveClientConnectionWithRouting(ctx, clientConnection, config.ServerPorts, config.ForwardTarget, config.MaxStreamsPerSession, streamSlots, logger)
		}(connection)
	}
}

// serveClientConnectionWithRouting handles the current route-header protocol.
// The legacy serveClientConnection functions below remain available for older
// callers and tests that intentionally exercise a single fixed TCP target.
func serveClientConnectionWithRouting(ctx context.Context, connection sdk.Connection, ports []AllowedPort, fallback string, maxStreamsPerSession int, globalSlots chan struct{}, logger *log.Logger) {
	peer := connection.Peer()
	session, err := tunnel.NewServerSessionWithOptions(ctx, connection, tunnel.SessionOptions{AcceptQueue: maxStreamsPerSession})
	if err != nil {
		_ = connection.Close()
		logger.Printf("event=tunnel_error stage=session_create peer=%s err=%v", peer.ID, err)
		return
	}
	var streams sync.WaitGroup
	perSessionSlots := make(chan struct{}, maxStreamsPerSession)
	defer func() { _ = session.Close(); streams.Wait() }()
	for {
		stream, acceptErr := session.Accept()
		if acceptErr != nil {
			if ctx.Err() == nil && !errors.Is(acceptErr, tunnel.ErrSessionClosed) {
				logger.Printf("event=tunnel_error stage=stream_accept peer=%s err=%v", peer.ID, acceptErr)
			}
			return
		}
		select {
		case globalSlots <- struct{}{}:
		default:
			_ = writeRouteAck(stream, routeAck{Code: 3, Message: "服务器当前并发已满"})
			_ = stream.Close()
			continue
		}
		select {
		case perSessionSlots <- struct{}{}:
		default:
			<-globalSlots
			_ = writeRouteAck(stream, routeAck{Code: 4, Message: "当前会话并发已满"})
			_ = stream.Close()
			continue
		}
		streams.Add(1)
		go func(remoteStream *tunnel.Stream) {
			defer streams.Done()
			defer func() { <-perSessionSlots }()
			defer func() { <-globalSlots }()
			defer remoteStream.Close()
			header, headerErr := readRouteHeader(remoteStream)
			if headerErr != nil {
				_ = writeRouteAck(remoteStream, routeAck{Code: 10, Message: "路由请求格式错误"})
				return
			}
			target, allowed := resolveAllowedTarget(ports, fallback, header)
			if !allowed {
				_ = writeRouteAck(remoteStream, routeAck{Code: 11, Message: fmt.Sprintf("端口 %d 未被服务端允许", header.RemotePort)})
				logger.Printf("event=route_reject peer=%s connection=%d port=%d", peer.ID, header.ConnectionID, header.RemotePort)
				return
			}
			if header.Transport == transportUDP {
				if err := writeRouteAck(remoteStream, routeAck{Accepted: true}); err != nil {
					return
				}
				if err := serveRoutedUDP(ctx, remoteStream, target); err != nil && ctx.Err() == nil {
					logger.Printf("event=udp_forward_error peer=%s target=%s err=%v", peer.ID, target, err)
				}
				return
			}
			backend, dialErr := (&net.Dialer{}).DialContext(ctx, "tcp", target)
			if dialErr != nil {
				_ = writeRouteAck(remoteStream, routeAck{Code: 12, Message: "服务端目标端口不可达"})
				logger.Printf("event=route_reject peer=%s target=%s err=%v", peer.ID, target, dialErr)
				return
			}
			defer backend.Close()
			if err := writeRouteAck(remoteStream, routeAck{Accepted: true}); err != nil {
				return
			}
			if bridgeErr := compressedBridge(remoteStream, backend, compressionServerMode, tunnel.DefaultCopyOptions()); bridgeErr != nil && ctx.Err() == nil {
				logger.Printf("event=tunnel_error stage=bridge peer=%s target=%s err=%v", peer.ID, target, bridgeErr)
			}
		}(stream)
	}
}

func resolveAllowedTarget(ports []AllowedPort, fallback string, header routeHeader) (string, bool) {
	protocol := "tcp"
	if header.Transport == transportUDP {
		protocol = "udp"
	}
	matching := make([]AllowedPort, 0, len(ports))
	for _, port := range ports {
		if !port.Enabled || normalizeProtocol(port.Protocol) != protocol {
			continue
		}
		matching = append(matching, port)
	}
	// A single target is unambiguous, so a Client may use route key 0 and
	// the Server dispatches directly without asking for a target port.
	if header.RemotePort == 0 && len(matching) == 1 {
		target := matching[0].Target
		if target == "" {
			target = net.JoinHostPort("127.0.0.1", fmt.Sprintf("%d", matching[0].Port))
		}
		return target, true
	}
	for _, port := range matching {
		if port.Port != 0 && port.Port != header.RemotePort {
			continue
		}
		target := port.Target
		if target == "" {
			target = net.JoinHostPort("127.0.0.1", fmt.Sprintf("%d", port.Port))
		}
		return target, true
	}
	// ForwardTarget is a legacy single-port configuration. Once an explicit
	// ServerPorts list exists, it is the complete authorization list and the
	// legacy fallback must not re-open a deleted or unlisted port.
	if len(ports) == 0 && fallback != "" && protocol == "tcp" && (header.RemotePort == 0 || targetPort(fallback) == header.RemotePort) {
		return fallback, true
	}
	return "", false
}

func targetPort(target string) uint16 {
	_, port, err := net.SplitHostPort(target)
	if err != nil {
		return 0
	}
	parsed, err := strconv.ParseUint(port, 10, 16)
	if err != nil {
		return 0
	}
	return uint16(parsed)
}

func serveRoutedUDP(ctx context.Context, stream *tunnel.Stream, target string) error {
	var length [4]byte
	if _, err := io.ReadFull(stream, length[:]); err != nil {
		_ = writeRouteAck(stream, routeAck{Code: 13, Message: "UDP 数据报长度缺失"})
		return err
	}
	payloadLength := binary.BigEndian.Uint32(length[:])
	if payloadLength == 0 || payloadLength > 64*1024 {
		_ = writeRouteAck(stream, routeAck{Code: 14, Message: "UDP 数据报长度无效"})
		return errors.New("invalid UDP payload size")
	}
	payload := make([]byte, payloadLength)
	if _, err := io.ReadFull(stream, payload); err != nil {
		return err
	}
	backend, err := net.DialUDP("udp", nil, mustUDPAddr(target))
	if err != nil {
		return err
	}
	defer backend.Close()
	if _, err := backend.Write(payload); err != nil {
		return err
	}
	_ = backend.SetReadDeadline(time.Now().Add(2 * time.Second))
	response := make([]byte, 64*1024)
	read, _, err := backend.ReadFromUDP(response)
	if err != nil {
		read = 0
	}
	binary.BigEndian.PutUint32(length[:], uint32(read))
	if err := writeAll(stream, length[:]); err != nil {
		return err
	}
	if read > 0 {
		return writeAll(stream, response[:read])
	}
	return nil
}

func mustUDPAddr(target string) *net.UDPAddr {
	address, err := net.ResolveUDPAddr("udp", target)
	if err != nil {
		return &net.UDPAddr{}
	}
	return address
}

func serveClientConnection(ctx context.Context, connection sdk.Connection, target string, logger *log.Logger) {
	serveClientConnectionWithLimits(ctx, connection, target, 128, make(chan struct{}, 1024), logger)
}

func serveClientConnectionWithLimits(ctx context.Context, connection sdk.Connection, target string, maxStreamsPerSession int, globalSlots chan struct{}, logger *log.Logger) {
	peer := connection.Peer()
	session, err := tunnel.NewServerSessionWithOptions(ctx, connection, tunnel.SessionOptions{AcceptQueue: maxStreamsPerSession})
	if err != nil {
		_ = connection.Close()
		logger.Printf("event=tunnel_error stage=session_create peer=%s err=%v", peer.ID, err)
		return
	}
	var streams sync.WaitGroup
	perSessionSlots := make(chan struct{}, maxStreamsPerSession)
	defer func() {
		_ = session.Close()
		streams.Wait()
	}()
	for {
		stream, acceptErr := session.Accept()
		if acceptErr != nil {
			if ctx.Err() == nil && !errors.Is(acceptErr, tunnel.ErrSessionClosed) {
				logger.Printf("event=tunnel_error stage=stream_accept peer=%s err=%v", peer.ID, acceptErr)
			}
			return
		}
		select {
		case globalSlots <- struct{}{}:
		default:
			logger.Printf("event=tunnel_reject stage=global_stream_limit peer=%s limit=%d", peer.ID, cap(globalSlots))
			_ = stream.Close()
			continue
		}
		select {
		case perSessionSlots <- struct{}{}:
		default:
			<-globalSlots
			logger.Printf("event=tunnel_reject stage=session_stream_limit peer=%s limit=%d", peer.ID, cap(perSessionSlots))
			_ = stream.Close()
			continue
		}
		streams.Add(1)
		go func(remoteStream *tunnel.Stream) {
			defer streams.Done()
			defer func() { <-perSessionSlots }()
			defer func() { <-globalSlots }()
			defer remoteStream.Close()
			backend, dialErr := (&net.Dialer{}).DialContext(ctx, "tcp", target)
			if dialErr != nil {
				logger.Printf("event=tunnel_error stage=backend_dial peer=%s target=%s err=%v", peer.ID, target, dialErr)
				return
			}
			if bridgeErr := compressedBridge(remoteStream, backend, compressionServerMode, tunnel.DefaultCopyOptions()); bridgeErr != nil && ctx.Err() == nil {
				logger.Printf("event=tunnel_error stage=bridge peer=%s target=%s err=%v", peer.ID, target, bridgeErr)
			}
		}(stream)
	}
}
