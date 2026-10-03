package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

var version = "dev"

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintf(os.Stderr, "fknat: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string, input io.Reader, output, errorOutput io.Writer) error {
	config, options, err := parseFlags(args, output)
	if errors.Is(err, errHelpRequested) {
		return nil
	}
	if err != nil {
		return err
	}
	if options.showVersion {
		fmt.Fprintf(output, "fknat %s\n", version)
		return nil
	}
	if options.interactive && !options.nonInteractive {
		if err := completeInteractive(input, output, &config); err != nil {
			return err
		}
	}
	generatedWebPassword, err := prepareWebConfig(&config)
	if err != nil {
		return err
	}
	if generatedWebPassword != "" {
		if err := saveConfigFile(config.ConfigFile, config); err != nil {
			return err
		}
		fmt.Fprintf(errorOutput, "fknat Web 默认已启用登录，用户名: %s\n", config.WebUser)
		fmt.Fprintf(errorOutput, "fknat Web 初始密码（仅显示一次）: %s\n", generatedWebPassword)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger := log.New(errorOutput, "", log.LstdFlags)

	controller := newRuntimeController(ctx, config, output, logger)
	return controller.start()
}

func prepareWebConfig(config *appConfig) (string, error) {
	if config.ConfigFile == "" {
		config.ConfigFile = defaultConfigFile()
	}
	if config.WebListenAddress == "" {
		config.WebListenAddress = "0.0.0.0:8088"
	}
	if config.SecurityProfile == "" {
		config.SecurityProfile = "production"
	}
	generatedWebPassword, err := ensureWebAuthDefaults(config)
	if err != nil {
		return "", err
	}
	if config.RelayCount == 0 {
		config.RelayCount = 1
	}
	if config.MaxSessions == 0 {
		config.MaxSessions = 128
	}
	if config.AcceptQueue == 0 {
		config.AcceptQueue = 128
	}
	if config.MaxStreams == 0 {
		config.MaxStreams = 1024
	}
	if config.MaxStreamsPerSession == 0 {
		config.MaxStreamsPerSession = 128
	}
	if config.DialAttempts == 0 {
		config.DialAttempts = 12
	}
	if config.RetryDelay == 0 {
		config.RetryDelay = 3 * time.Second
	}
	if config.ReconnectDelay == 0 {
		config.ReconnectDelay = 3 * time.Second
	}
	if config.IdentityFile == "" && (config.Role == roleClient || config.Role == roleServer) {
		identity, err := defaultIdentityFile(config.Role)
		if err != nil {
			return "", err
		}
		config.IdentityFile = identity
	}
	if config.Role == roleClient && len(config.ClientMappings) == 0 && config.ListenAddress != "" {
		config.ClientMappings = []PortMapping{{ID: "client-1", Protocol: "tcp", Listen: config.ListenAddress, RemotePort: config.RemotePort, Enabled: true}}
	}
	if config.Role == roleServer && len(config.ServerPorts) == 0 && config.ForwardTarget != "" {
		target, err := normalizeForwardTarget(config.ForwardTarget)
		if err != nil {
			return "", err
		}
		config.ForwardTarget = target
		_, port, _ := net.SplitHostPort(target)
		parsed, _ := strconv.Atoi(port)
		config.ServerPorts = []AllowedPort{{ID: "server-1", Protocol: "tcp", Port: uint16(parsed), Target: target, Enabled: true}}
	}
	*config = config.ensureIDs()
	if config.Role == roleClient || config.Role == roleServer {
		if roleReady(*config) {
			if err := config.normalizeAndValidate(); err != nil {
				return "", err
			}
		}
	}
	return generatedWebPassword, nil
}
