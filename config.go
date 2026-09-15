package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type role string

const (
	roleClient      role = "client"
	roleServer      role = "server"
	productionCAURL      = "https://ca.fknat.top"
)

var errHelpRequested = errors.New("help requested")

func caURLForConfig(config appConfig) string {
	if config.SecurityProfile == "development" {
		return ""
	}
	return productionCAURL
}

type appConfig struct {
	Role                 role
	IndexAddress         string
	RelayAddress         string
	RelayAddresses       []string
	RelayCount           int
	BillingKeyFile       string
	IdentityFile         string
	ListenAddress        string
	ServerNodeID         string
	ForwardTarget        string
	MaxSessions          int
	AcceptQueue          int
	MaxStreams           int
	MaxStreamsPerSession int
	DialAttempts         int
	RetryDelay           time.Duration
	ReconnectDelay       time.Duration
	SecurityProfile      string
}

type cliOptions struct {
	nonInteractive bool
	showVersion    bool
}

func parseFlags(args []string, output io.Writer) (appConfig, cliOptions, error) {
	config := appConfig{}
	options := cliOptions{}
	var roleValue string
	var relaysValue string

	flags := flag.NewFlagSet("fknat", flag.ContinueOnError)
	flags.SetOutput(output)
	flags.StringVar(&roleValue, "mode", envOrDefault("FKNAT_MODE", ""), "运行角色: client 或 server")
	flags.StringVar(&config.IndexAddress, "index", envOrDefault("FKNAT_INDEX_ADDRESS", ""), "Index 地址 host:port；留空时从 CA Web 自动发现")
	flags.StringVar(&config.RelayAddress, "relay", envOrDefault("FKNAT_RELAY_ADDRESS", ""), "固定使用一个 Relay；为空则通过 Index 发现")
	flags.StringVar(&relaysValue, "relays", envOrDefault("FKNAT_RELAY_ADDRESSES", ""), "Server 使用的多个 Relay，逗号分隔，最多三个")
	flags.IntVar(&config.RelayCount, "relay-count", 1, "Server 自动选择的 Relay 数量，1..3")
	flags.StringVar(&config.BillingKeyFile, "billing-key", envOrDefault("BNFS_BILLING_KEY_FILE", ""), "CA Web 导出的扣费私钥 JSON 文件")
	flags.StringVar(&config.IdentityFile, "identity", envOrDefault("FKNAT_IDENTITY_FILE", ""), "节点身份私钥文件；不存在时自动创建")
	flags.StringVar(&config.ListenAddress, "listen", envOrDefault("FKNAT_LISTEN_ADDRESS", ""), "Client 本地 TCP 监听地址；端口 0 表示随机")
	flags.StringVar(&config.ServerNodeID, "server-id", envOrDefault("FKNAT_SERVER_NODE_ID", ""), "Client 要连接的 NatServer NodeID")
	flags.StringVar(&config.ForwardTarget, "target", envOrDefault("FKNAT_FORWARD_TARGET", ""), "Server 实际 TCP 应用地址 host:port")
	flags.IntVar(&config.MaxSessions, "max-sessions", 128, "Server 最大并发 NatClient 会话数")
	flags.IntVar(&config.AcceptQueue, "accept-queue", 128, "Server 已认证会话等待队列长度")
	flags.IntVar(&config.MaxStreams, "max-streams", 1024, "Server 全局最大并发逻辑流数")
	flags.IntVar(&config.MaxStreamsPerSession, "max-streams-per-session", 128, "Server 每个 NatClient 会话最大并发逻辑流数")
	flags.IntVar(&config.DialAttempts, "dial-attempts", 12, "Client 每次建立 P2P 连接的尝试次数")
	flags.DurationVar(&config.RetryDelay, "retry-delay", 3*time.Second, "Client 单次 P2P 拨号重试间隔")
	flags.DurationVar(&config.ReconnectDelay, "reconnect-delay", 3*time.Second, "Client 隧道失效后的重连间隔")
	flags.StringVar(&config.SecurityProfile, "security-profile", envOrDefault("BNFS_SECURITY_PROFILE", "production"), "SDK 安全档: development, staging, production")
	flags.BoolVar(&options.nonInteractive, "non-interactive", false, "关闭交互提示，缺少必填配置时直接失败")
	flags.BoolVar(&options.showVersion, "version", false, "显示版本")
	flags.Usage = func() {
		fmt.Fprintln(output, "fknat - natP2pSDK TCP 端口转发工具")
		fmt.Fprintln(output)
		fmt.Fprintln(output, "直接运行会进入交互向导；自动部署可使用 --non-interactive。")
		fmt.Fprintln(output)
		flags.PrintDefaults()
	}

	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return appConfig{}, cliOptions{}, errHelpRequested
		}
		return appConfig{}, cliOptions{}, err
	}
	if flags.NArg() != 0 {
		return appConfig{}, cliOptions{}, fmt.Errorf("不支持的位置参数 %q", strings.Join(flags.Args(), " "))
	}
	if roleValue != "" {
		parsedRole, err := parseRole(roleValue)
		if err != nil {
			return appConfig{}, cliOptions{}, err
		}
		config.Role = parsedRole
	}
	config.RelayAddresses = splitCSV(relaysValue)
	return config, options, nil
}

func (config *appConfig) normalizeAndValidate() error {
	if config.Role != roleClient && config.Role != roleServer {
		return errors.New("必须选择 client 或 server 角色")
	}
	config.IndexAddress = strings.TrimSpace(config.IndexAddress)
	config.RelayAddress = strings.TrimSpace(config.RelayAddress)
	config.BillingKeyFile = strings.TrimSpace(config.BillingKeyFile)
	config.IdentityFile = strings.TrimSpace(config.IdentityFile)
	config.SecurityProfile = strings.ToLower(strings.TrimSpace(config.SecurityProfile))
	config.RelayAddresses = uniqueStrings(config.RelayAddresses)

	if config.SecurityProfile != "development" && config.SecurityProfile != "staging" && config.SecurityProfile != "production" {
		return fmt.Errorf("不支持的安全档 %q", config.SecurityProfile)
	}
	if config.IndexAddress != "" {
		if err := validateHostPort(config.IndexAddress, false, false); err != nil {
			return fmt.Errorf("Index 地址无效: %w", err)
		}
	} else if config.RelayAddress == "" && len(config.RelayAddresses) == 0 && config.SecurityProfile == "development" {
		return errors.New("开发安全档未配置 Index 或固定 Relay")
	}
	if config.RelayAddress != "" {
		if err := validateHostPort(config.RelayAddress, false, false); err != nil {
			return fmt.Errorf("Relay 地址无效: %w", err)
		}
	}
	for _, relayAddress := range config.RelayAddresses {
		if err := validateHostPort(relayAddress, false, false); err != nil {
			return fmt.Errorf("Relay 地址 %q 无效: %w", relayAddress, err)
		}
	}
	if config.RelayAddress != "" && len(config.RelayAddresses) != 0 {
		return errors.New("--relay 与 --relays 不能同时使用")
	}
	if len(config.RelayAddresses) > 3 {
		return errors.New("Server 最多只能配置三个 Relay")
	}
	if config.RelayCount < 1 || config.RelayCount > 3 {
		return errors.New("--relay-count 必须在 1..3 之间")
	}
	if config.SecurityProfile == "production" && config.BillingKeyFile == "" {
		return errors.New("production 安全档必须配置 CA Web 导出的扣费私钥文件")
	}
	if config.BillingKeyFile != "" {
		absolute, err := validateSecretFile(config.BillingKeyFile)
		if err != nil {
			return fmt.Errorf("扣费私钥文件无效: %w", err)
		}
		config.BillingKeyFile = absolute
		if strings.TrimSpace(os.Getenv("BNFS_CA_ISSUE_TOKEN_FILE")) != "" {
			return errors.New("BNFS_BILLING_KEY_FILE 与 BNFS_CA_ISSUE_TOKEN_FILE 不能同时使用")
		}
	}
	if config.IdentityFile == "" {
		identityFile, err := defaultIdentityFile(config.Role)
		if err != nil {
			return err
		}
		config.IdentityFile = identityFile
	}
	absoluteIdentity, err := filepath.Abs(config.IdentityFile)
	if err != nil {
		return fmt.Errorf("解析节点身份路径: %w", err)
	}
	config.IdentityFile = absoluteIdentity

	switch config.Role {
	case roleClient:
		config.ListenAddress, err = normalizeListenAddress(config.ListenAddress)
		if err != nil {
			return err
		}
		config.ServerNodeID = strings.TrimSpace(config.ServerNodeID)
		if _, err := parseServerNodeID(config.ServerNodeID); err != nil {
			return err
		}
		if len(config.RelayAddresses) != 0 {
			return errors.New("Client 不支持 --relays，请使用 --relay")
		}
		if config.DialAttempts < 1 {
			return errors.New("--dial-attempts 必须大于 0")
		}
		if config.RetryDelay <= 0 || config.ReconnectDelay <= 0 {
			return errors.New("拨号重试和重连间隔必须大于 0")
		}
	case roleServer:
		config.ForwardTarget, err = normalizeForwardTarget(config.ForwardTarget)
		if err != nil {
			return err
		}
		if config.MaxSessions < 1 || config.AcceptQueue < 1 || config.MaxStreams < 1 || config.MaxStreamsPerSession < 1 {
			return errors.New("--max-sessions、--accept-queue、--max-streams 和 --max-streams-per-session 必须大于 0")
		}
	}
	return nil
}

func configureSDKEnvironment(config appConfig) error {
	if err := os.Setenv("BNFS_SECURITY_PROFILE", config.SecurityProfile); err != nil {
		return fmt.Errorf("设置 SDK 安全档失败: %w", err)
	}
	if config.BillingKeyFile != "" {
		if err := os.Setenv("BNFS_BILLING_KEY_FILE", config.BillingKeyFile); err != nil {
			return fmt.Errorf("设置 SDK 扣费密钥文件失败: %w", err)
		}
	}
	return nil
}

func parseRole(value string) (role, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "client", "c", "1":
		return roleClient, nil
	case "server", "s", "2":
		return roleServer, nil
	default:
		return "", fmt.Errorf("运行角色 %q 无效，只能是 client 或 server", value)
	}
}

func normalizeListenAddress(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		value = "127.0.0.1:0"
	} else if isDecimal(value) {
		value = net.JoinHostPort("127.0.0.1", value)
	}
	if err := validateHostPort(value, true, true); err != nil {
		return "", fmt.Errorf("Client 监听地址无效: %w", err)
	}
	return value, nil
}

func normalizeForwardTarget(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New("Server 必须配置实际应用端口或 host:port")
	}
	if isDecimal(value) {
		value = net.JoinHostPort("127.0.0.1", value)
	} else if strings.HasPrefix(value, ":") {
		value = "127.0.0.1" + value
	}
	if err := validateHostPort(value, false, false); err != nil {
		return "", fmt.Errorf("Server 转发目标无效: %w", err)
	}
	return value, nil
}

func validateHostPort(value string, allowZero, allowEmptyHost bool) error {
	host, portValue, err := net.SplitHostPort(value)
	if err != nil {
		return err
	}
	if strings.TrimSpace(host) == "" && !allowEmptyHost {
		return errors.New("主机名不能为空")
	}
	port, err := strconv.Atoi(portValue)
	if err != nil || port < 0 || port > 65535 || (!allowZero && port == 0) {
		return fmt.Errorf("端口 %q 不在有效范围", portValue)
	}
	return nil
}

func validateSecretFile(value string) (string, error) {
	absolute, err := filepath.Abs(value)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(absolute)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 64<<10 {
		return "", errors.New("必须是 1..65536 字节的普通文件")
	}
	if !secretFileModeIsSecure(info.Mode()) {
		return "", fmt.Errorf("权限必须为 0600 或更严格，当前为 %04o；请先执行 chmod 600", info.Mode().Perm())
	}
	return absolute, nil
}

func defaultIdentityFile(selectedRole role) (string, error) {
	configDirectory, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("定位用户配置目录失败: %w", err)
	}
	return filepath.Join(configDirectory, "fknat", string(selectedRole)+".identity"), nil
}

func splitCSV(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	return uniqueStrings(strings.Split(value, ","))
}

func uniqueStrings(values []string) []string {
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func isDecimal(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}
