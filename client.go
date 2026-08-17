package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
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

func runClient(ctx context.Context, config appConfig, output io.Writer, logger *log.Logger) error {
	target, err := parseServerNodeID(config.ServerNodeID)
	if err != nil {
		return err
	}
	runContext, cancel := context.WithCancel(ctx)

	client, err := natclient.New(natclient.Config{
		IndexAddress: config.IndexAddress,
		RelayAddress: config.RelayAddress,
		Identity:     config.IdentityFile,
		CAURL:        config.CAURL,
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

	listener, err := net.Listen("tcp", config.ListenAddress)
	if err != nil {
		cancel()
		_ = client.Close()
		return fmt.Errorf("监听 %s: %w", config.ListenAddress, err)
	}

	manager := &clientSessionManager{
		dialer: client, target: target, reconnectDelay: config.ReconnectDelay, logger: logger,
	}
	var connections sync.WaitGroup
	defer func() {
		cancel()
		_ = listener.Close()
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
			_ = listener.Close()
		case backgroundError, ok := <-client.Errors():
			if ok && backgroundError != nil {
				logger.Printf("NatClient 后台注册失效: %v", backgroundError)
				cancel()
				_ = listener.Close()
			}
		}
	}()

	fmt.Fprintln(output, "=== fknat Client 已就绪 ===")
	fmt.Fprintf(output, "本节点 ID: %s\n", client.NodeID())
	fmt.Fprintf(output, "目标 Server: %s\n", target)
	fmt.Fprintf(output, "入口 Relay: %s\n", client.EntryRelay())
	fmt.Fprintf(output, "本地 TCP 监听: %s\n", listener.Addr())
	fmt.Fprintln(output, "该端口接受的所有 TCP 连接都会转发到目标 NatServer。按 Ctrl+C 退出。")

	for {
		localConnection, acceptErr := listener.Accept()
		if acceptErr != nil {
			if runContext.Err() != nil || errors.Is(acceptErr, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("接受本地 TCP 连接: %w", acceptErr)
		}
		connections.Add(1)
		go func(local net.Conn) {
			defer connections.Done()
			defer local.Close()
			stream, streamErr := manager.OpenStream(runContext)
			if streamErr != nil {
				if runContext.Err() == nil {
					logger.Printf("为本地连接 %s 打开隧道失败: %v", local.RemoteAddr(), streamErr)
				}
				return
			}
			if bridgeErr := tunnel.Bridge(stream, local, tunnel.DefaultCopyOptions()); bridgeErr != nil && runContext.Err() == nil {
				logger.Printf("本地连接 %s 转发结束: %v", local.RemoteAddr(), bridgeErr)
			}
		}(localConnection)
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
