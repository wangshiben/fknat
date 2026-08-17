package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"syscall"
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
	if !options.nonInteractive {
		if err := completeInteractive(input, output, &config); err != nil {
			return err
		}
	}
	if err := config.normalizeAndValidate(); err != nil {
		return err
	}
	if err := configureSDKEnvironment(config); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger := log.New(errorOutput, "", log.LstdFlags)

	switch config.Role {
	case roleClient:
		return runClient(ctx, config, output, logger)
	case roleServer:
		return runServer(ctx, config, output, logger)
	default:
		return fmt.Errorf("不支持的运行角色 %q", config.Role)
	}
}
