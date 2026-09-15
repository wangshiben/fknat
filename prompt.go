package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strings"
)

func completeInteractive(input io.Reader, output io.Writer, config *appConfig) error {
	reader := bufio.NewReader(input)
	fmt.Fprintln(output, "=== fknat / natP2pSDK TCP 转发向导 ===")
	if config.Role == "" {
		value, err := ask(reader, output, "选择角色：1) Client  2) Server", "", true)
		if err != nil {
			return err
		}
		selectedRole, err := parseRole(value)
		if err != nil {
			return err
		}
		config.Role = selectedRole
	}

	identityDefault := config.IdentityFile
	if identityDefault == "" {
		var err error
		identityDefault, err = defaultIdentityFile(config.Role)
		if err != nil {
			return err
		}
	}
	var err error
	config.IndexAddress, err = ask(reader, output, "Index 地址（可留空，由 CA Web 自动选择）", config.IndexAddress, false)
	if err != nil {
		return err
	}
	fmt.Fprintf(output, "CA Web API: %s（内置）\n", productionCAURL)
	fmt.Fprintln(output, "扣费密钥应为 CA Web 导出的 JSON 文件；这里填写文件路径，不要粘贴私钥内容。")
	config.BillingKeyFile, err = ask(reader, output, "扣费私钥文件", config.BillingKeyFile, config.SecurityProfile == "production")
	if err != nil {
		return err
	}
	config.IdentityFile, err = ask(reader, output, "节点身份文件", identityDefault, true)
	if err != nil {
		return err
	}

	switch config.Role {
	case roleClient:
		config.RelayAddress, err = ask(reader, output, "固定入口 Relay（可留空，由 Index 发现）", config.RelayAddress, false)
		if err != nil {
			return err
		}
		config.ServerNodeID, err = ask(reader, output, "目标 NatServer NodeID", config.ServerNodeID, true)
		if err != nil {
			return err
		}
		listenDefault := config.ListenAddress
		if listenDefault == "" {
			listenDefault = "127.0.0.1:0"
		}
		config.ListenAddress, err = ask(reader, output, "本地 TCP 监听地址（端口 0 为随机）", listenDefault, true)
	case roleServer:
		relaysDefault := strings.Join(config.RelayAddresses, ",")
		if relaysDefault == "" {
			relaysDefault = config.RelayAddress
		}
		relays, askErr := ask(reader, output, "固定服务 Relay（可空；多个用逗号分隔，最多三个）", relaysDefault, false)
		if askErr != nil {
			return askErr
		}
		parsedRelays := splitCSV(relays)
		if len(parsedRelays) == 1 {
			config.RelayAddress = parsedRelays[0]
			config.RelayAddresses = nil
		} else {
			config.RelayAddress = ""
			config.RelayAddresses = parsedRelays
		}
		targetDefault := config.ForwardTarget
		if targetDefault == "" {
			targetDefault = "127.0.0.1:8080"
		}
		config.ForwardTarget, err = ask(reader, output, "实际 TCP 应用地址或本地端口", targetDefault, true)
	}
	return err
}

func ask(reader *bufio.Reader, output io.Writer, label, defaultValue string, required bool) (string, error) {
	if defaultValue == "" {
		fmt.Fprintf(output, "%s: ", label)
	} else {
		fmt.Fprintf(output, "%s [%s]: ", label, defaultValue)
	}
	line, err := reader.ReadString('\n')
	value := strings.TrimSpace(line)
	if value == "" {
		value = strings.TrimSpace(defaultValue)
	}
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("读取 %s 失败: %w", label, err)
	}
	if required && value == "" {
		return "", fmt.Errorf("%s 不能为空", label)
	}
	return value, nil
}
