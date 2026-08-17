package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"

	sdk "github.com/wangshiben/natP2pSDK"
	"github.com/wangshiben/natP2pSDK/natserver"
	"github.com/wangshiben/natP2pSDK/tunnel"
)

func runServer(ctx context.Context, config appConfig, output io.Writer, logger *log.Logger) error {
	server, err := natserver.New(natserver.Config{
		IndexAddress:   config.IndexAddress,
		RelayAddress:   config.RelayAddress,
		RelayAddresses: config.RelayAddresses,
		RelayCount:     config.RelayCount,
		Identity:       config.IdentityFile,
		CAURL:          config.CAURL,
		MaxSessions:    config.MaxSessions,
		AcceptQueue:    config.AcceptQueue,
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
			serveClientConnection(ctx, clientConnection, config.ForwardTarget, logger)
		}(connection)
	}
}

func serveClientConnection(ctx context.Context, connection sdk.Connection, target string, logger *log.Logger) {
	peer := connection.Peer()
	session, err := tunnel.NewServerSession(ctx, connection)
	if err != nil {
		_ = connection.Close()
		logger.Printf("为 NatClient %s 创建隧道会话失败: %v", peer.ID, err)
		return
	}
	var streams sync.WaitGroup
	defer func() {
		_ = session.Close()
		streams.Wait()
	}()
	for {
		stream, acceptErr := session.Accept()
		if acceptErr != nil {
			if ctx.Err() == nil && !errors.Is(acceptErr, tunnel.ErrSessionClosed) {
				logger.Printf("NatClient %s 隧道会话结束: %v", peer.ID, acceptErr)
			}
			return
		}
		streams.Add(1)
		go func(remoteStream *tunnel.Stream) {
			defer streams.Done()
			defer remoteStream.Close()
			backend, dialErr := (&net.Dialer{}).DialContext(ctx, "tcp", target)
			if dialErr != nil {
				logger.Printf("连接实际应用 %s 失败: %v", target, dialErr)
				return
			}
			if bridgeErr := tunnel.Bridge(remoteStream, backend, tunnel.DefaultCopyOptions()); bridgeErr != nil && ctx.Err() == nil {
				logger.Printf("NatClient %s 到 %s 的流转发结束: %v", peer.ID, target, bridgeErr)
			}
		}(stream)
	}
}
