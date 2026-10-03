package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"

	sdk "github.com/wangshiben/natP2pSDK"
	"github.com/wangshiben/natP2pSDK/natclient"
	"github.com/wangshiben/natP2pSDK/tunnel"
)

type clientDialer interface {
	Dial(context.Context, sdk.NodeID) (sdk.Connection, error)
}

type clientSessionManager struct {
	dialer         clientDialer
	target         sdk.NodeID
	reconnectDelay time.Duration
	logger         *log.Logger

	mu      sync.Mutex
	session *tunnel.Session
	closed  bool
}

func runClient(ctx context.Context, config appConfig, output io.Writer, logger *log.Logger, reportRouteError ...func(error)) error {
	target, err := parseServerNodeID(config.ServerNodeID)
	if err != nil {
		return err
	}
	runContext, cancel := context.WithCancel(ctx)

	client, err := natclient.New(natclient.Config{
		IndexAddress: config.IndexAddress,
		RelayAddress: config.RelayAddress,
		Identity:     config.IdentityFile,
		CAURL:        caURLForConfig(config),
		DialAttempts: config.DialAttempts,
		RetryDelay:   config.RetryDelay,
	})
	if err != nil {
		cancel()
		return fmt.Errorf("创建 NatClient: %w", err)
	}
	if err := client.Start(runContext); err != nil {
		cancel()
		_ = client.Close()
		return fmt.Errorf("启动 NatClient: %w", err)
	}

	manager := &clientSessionManager{
		dialer: client, target: target, reconnectDelay: config.ReconnectDelay, logger: logger,
	}
	var connections sync.WaitGroup
	defer func() {
		cancel()
		_ = manager.Close()
		connections.Wait()
		_ = client.Close()
	}()
	if err := manager.Connect(runContext); err != nil {
		return fmt.Errorf("连接 NatServer %s: %w", target, err)
	}

	go func() {
		select {
		case <-runContext.Done():
		case backgroundError, ok := <-client.Errors():
			if ok && backgroundError != nil {
				logger.Printf("NatClient 后台注册失效: %v", backgroundError)
				cancel()
			}
		}
	}()

	fmt.Fprintln(output, "=== fknat Client 已就绪 ===")
	fmt.Fprintf(output, "本节点 ID: %s\n", client.NodeID())
	fmt.Fprintf(output, "目标 Server: %s\n", target)
	fmt.Fprintf(output, "入口 Relay: %s\n", client.EntryRelay())
	mappings := append([]PortMapping(nil), config.ClientMappings...)
	if len(mappings) == 0 {
		mappings = []PortMapping{{ID: "client-1", Protocol: "tcp", Listen: config.ListenAddress, RemotePort: config.RemotePort, Enabled: true}}
	}
	fmt.Fprintf(output, "客户端映射数量: %d\n", len(mappings))
	fmt.Fprintln(output, "按 Ctrl+C 退出。")
	var nextID atomic.Uint64
	listeners := make([]io.Closer, 0, len(mappings))
	defer func() {
		for _, listener := range listeners {
			_ = listener.Close()
		}
	}()
	for _, mapping := range mappings {
		if !mapping.Enabled {
			continue
		}
		mapping.Protocol = normalizeProtocol(mapping.Protocol)
		if mapping.Listen == "" {
			return fmt.Errorf("Client 映射 %s 缺少本地监听地址", mapping.ID)
		}
		if mapping.Protocol == "udp" {
			address, listenErr := net.ResolveUDPAddr("udp", mapping.Listen)
			if listenErr != nil {
				return listenErr
			}
			udpListener, listenErr := net.ListenUDP("udp", address)
			if listenErr != nil {
				return fmt.Errorf("监听 UDP %s: %w", mapping.Listen, listenErr)
			}
			listeners = append(listeners, udpListener)
			fmt.Fprintf(output, "本地 UDP 监听: %s -> Server UDP %d\n", udpListener.LocalAddr(), mapping.RemotePort)
			connections.Add(1)
			go func(listener *net.UDPConn, mapping PortMapping) {
				defer connections.Done()
				serveClientUDP(runContext, listener, manager, mapping, &nextID, logger, reportRouteError...)
			}(udpListener, mapping)
			continue
		}
		tcpListener, listenErr := net.Listen("tcp", mapping.Listen)
		if listenErr != nil {
			return fmt.Errorf("监听 TCP %s: %w", mapping.Listen, listenErr)
		}
		listeners = append(listeners, tcpListener)
		fmt.Fprintf(output, "本地 TCP 监听: %s -> Server TCP %d\n", tcpListener.Addr(), mapping.RemotePort)
		connections.Add(1)
		go func(listener net.Listener, mapping PortMapping) {
			defer connections.Done()
			for {
				localConnection, acceptErr := listener.Accept()
				if acceptErr != nil {
					if runContext.Err() != nil || errors.Is(acceptErr, net.ErrClosed) {
						return
					}
					logger.Printf("event=local_accept_error mapping=%s err=%v", mapping.ID, acceptErr)
					return
				}
				connections.Add(1)
				go func(local net.Conn) {
					defer connections.Done()
					defer local.Close()
					stream, streamErr := openRoutedStream(runContext, manager, &nextID, mapping, logger)
					if streamErr != nil {
						if len(reportRouteError) > 0 && reportRouteError[0] != nil {
							reportRouteError[0](fmt.Errorf("映射 %s 连接被 Server 拒绝: %w", mapping.ID, streamErr))
						}
						if runContext.Err() == nil {
							logger.Printf("event=route_rejected mapping=%s err=%v", mapping.ID, streamErr)
						}
						return
					}
					if bridgeErr := compressedBridge(local, stream, compressionClientMode, tunnel.DefaultCopyOptions()); bridgeErr != nil && runContext.Err() == nil {
						logger.Printf("event=tunnel_error stage=bridge mapping=%s err=%v", mapping.ID, bridgeErr)
					}
				}(localConnection)
			}
		}(tcpListener, mapping)
	}
	<-runContext.Done()
	return nil
}

func openRoutedStream(ctx context.Context, manager *clientSessionManager, nextID *atomic.Uint64, mapping PortMapping, logger *log.Logger) (*tunnel.Stream, error) {
	stream, err := manager.OpenStream(ctx)
	if err != nil {
		return nil, err
	}
	transport := transportTCP
	if normalizeProtocol(mapping.Protocol) == "udp" {
		transport = transportUDP
	}
	if err := writeRouteHeader(stream, routeHeader{ConnectionID: nextID.Add(1), Transport: transport, RemotePort: mapping.RemotePort}); err != nil {
		_ = stream.Close()
		return nil, err
	}
	ack, err := readRouteAck(stream)
	if err != nil {
		_ = stream.Close()
		return nil, err
	}
	if !ack.Accepted {
		_ = stream.Close()
		return nil, fmt.Errorf("server rejected route code=%d: %s", ack.Code, ack.Message)
	}
	return stream, nil
}

func serveClientUDP(ctx context.Context, listener *net.UDPConn, manager *clientSessionManager, mapping PortMapping, nextID *atomic.Uint64, logger *log.Logger, reportRouteError ...func(error)) {
	buffer := make([]byte, 64*1024)
	for {
		_ = listener.SetReadDeadline(time.Now().Add(time.Second))
		read, source, err := listener.ReadFromUDP(buffer)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			logger.Printf("event=udp_read_error mapping=%s err=%v", mapping.ID, err)
			return
		}
		payload := append([]byte(nil), buffer[:read]...)
		go func(source *net.UDPAddr, payload []byte) {
			stream, err := openRoutedStream(ctx, manager, nextID, mapping, logger)
			if err != nil {
				if ctx.Err() == nil {
					if len(reportRouteError) > 0 && reportRouteError[0] != nil {
						reportRouteError[0](fmt.Errorf("UDP 映射 %s 连接被 Server 拒绝: %w", mapping.ID, err))
					}
					logger.Printf("event=udp_route_rejected mapping=%s err=%v", mapping.ID, err)
				}
				return
			}
			defer stream.Close()
			var length [4]byte
			binary.BigEndian.PutUint32(length[:], uint32(len(payload)))
			if err := writeAll(stream, length[:]); err != nil || writeAll(stream, payload) != nil {
				return
			}
			if _, err := io.ReadFull(stream, length[:]); err != nil {
				return
			}
			responseLength := binary.BigEndian.Uint32(length[:])
			if responseLength > 64*1024 {
				return
			}
			response := make([]byte, responseLength)
			if _, err := io.ReadFull(stream, response); err != nil {
				return
			}
			_, _ = listener.WriteToUDP(response, source)
		}(source, payload)
	}
}

func (manager *clientSessionManager) Connect(ctx context.Context) error {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if manager.closed {
		return errors.New("Client 隧道管理器已关闭")
	}
	return manager.connectLocked(ctx)
}

func (manager *clientSessionManager) OpenStream(ctx context.Context) (*tunnel.Stream, error) {
	for {
		manager.mu.Lock()
		if manager.closed {
			manager.mu.Unlock()
			return nil, errors.New("Client 隧道管理器已关闭")
		}
		if manager.session == nil {
			if err := manager.connectLocked(ctx); err != nil {
				manager.mu.Unlock()
				manager.logger.Printf("重连 NatServer %s 失败，等待 %s: %v", manager.target, manager.reconnectDelay, err)
				if err := waitForContext(ctx, manager.reconnectDelay); err != nil {
					return nil, err
				}
				continue
			}
		}
		stream, err := manager.session.OpenStream(ctx)
		if err == nil {
			manager.mu.Unlock()
			return stream, nil
		}
		failedSession := manager.session
		manager.session = nil
		manager.mu.Unlock()
		_ = failedSession.Close()
		manager.logger.Printf("P2P 隧道已失效，等待 %s 后重连: %v", manager.reconnectDelay, err)
		if err := waitForContext(ctx, manager.reconnectDelay); err != nil {
			return nil, err
		}
	}
}

func (manager *clientSessionManager) connectLocked(ctx context.Context) error {
	if manager.session != nil {
		return nil
	}
	connection, err := manager.dialer.Dial(ctx, manager.target)
	if err != nil {
		return err
	}
	session, err := tunnel.NewClientSession(ctx, connection)
	if err != nil {
		_ = connection.Close()
		return err
	}
	manager.session = session
	manager.logger.Printf("已连接 NatServer %s", manager.target)
	return nil
}

func (manager *clientSessionManager) Close() error {
	manager.mu.Lock()
	manager.closed = true
	session := manager.session
	manager.session = nil
	manager.mu.Unlock()
	if session != nil {
		return session.Close()
	}
	return nil
}

func waitForContext(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func parseServerNodeID(value string) (sdk.NodeID, error) {
	target, err := sdk.ParseNodeID(value)
	if err != nil {
		return "", fmt.Errorf("目标 NatServer NodeID 无效: %w", err)
	}
	return target, nil
}
