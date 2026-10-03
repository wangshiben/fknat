package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"golang.org/x/crypto/bcrypt"
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
	Role                 role          `json:"mode"`
	IndexAddress         string        `json:"index_address"`
	RelayAddress         string        `json:"relay_address"`
	RelayAddresses       []string      `json:"relay_addresses,omitempty"`
	RelayCount           int           `json:"relay_count,omitempty"`
	BillingKeyFile       string        `json:"billing_key_file,omitempty"`
	BillingSnapshotFile  string        `json:"billing_snapshot_file,omitempty"`
	IdentityFile         string        `json:"identity_file,omitempty"`
	ListenAddress        string        `json:"listen_address,omitempty"`
	ServerNodeID         string        `json:"server_node_id,omitempty"`
	ForwardTarget        string        `json:"forward_target,omitempty"`
	RemotePort           uint16        `json:"remote_port,omitempty"`
	ClientMappings       []PortMapping `json:"client_mappings,omitempty"`
	ServerPorts          []AllowedPort `json:"server_ports,omitempty"`
	ConfigFile           string        `json:"config_file,omitempty"`
	WebListenAddress     string        `json:"web_listen_address,omitempty"`
	MaxSessions          int           `json:"max_sessions,omitempty"`
	AcceptQueue          int           `json:"accept_queue,omitempty"`
	MaxStreams           int           `json:"max_streams,omitempty"`
	MaxStreamsPerSession int           `json:"max_streams_per_session,omitempty"`
	DialAttempts         int           `json:"dial_attempts,omitempty"`
	RetryDelay           time.Duration `json:"retry_delay_ns,omitempty"`
	ReconnectDelay       time.Duration `json:"reconnect_delay_ns,omitempty"`
	SecurityProfile      string        `json:"security_profile,omitempty"`
	WebUser              string        `json:"web_user,omitempty"`
	WebPassword          string        `json:"-"`
	WebPasswordHash      string        `json:"web_password_hash,omitempty"`
}

// PortMapping describes one client-side local listener and its remote server port.
type PortMapping struct {
	ID         string `json:"id"`
	Protocol   string `json:"protocol"`
	Listen     string `json:"listen"`
	RemotePort uint16 `json:"remote_port"`
	Enabled    bool   `json:"enabled"`
}

// AllowedPort describes one server-side forwarding rule. Port is retained as
// a compatibility route key for multi-target configurations; a single target
// can be selected without a route key.
type AllowedPort struct {
	ID       string `json:"id"`
	Protocol string `json:"protocol"`
	Port     uint16 `json:"port"`
	Target   string `json:"target"`
	Enabled  bool   `json:"enabled"`
}

func defaultConfigFile() string {
	if value := strings.TrimSpace(os.Getenv("FKNAT_CONFIG_FILE")); value != "" {
		return value
	}
	directory, err := os.UserConfigDir()
	if err != nil {
		return "fknat-config.json"
	}
	return filepath.Join(directory, "fknat", "config.json")
}

func (config appConfig) ensureIDs() appConfig {
	for index := range config.ClientMappings {
		if strings.TrimSpace(config.ClientMappings[index].ID) == "" {
			config.ClientMappings[index].ID = fmt.Sprintf("client-%d", index+1)
		}
		config.ClientMappings[index].Protocol = normalizeProtocol(config.ClientMappings[index].Protocol)
	}
	for index := range config.ServerPorts {
		if strings.TrimSpace(config.ServerPorts[index].ID) == "" {
			config.ServerPorts[index].ID = fmt.Sprintf("server-%d", index+1)
		}
		config.ServerPorts[index].Protocol = normalizeProtocol(config.ServerPorts[index].Protocol)
	}
	return config
}

func normalizeProtocol(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "udp" {
		return "udp"
	}
	return "tcp"
}

func loadConfigFile(path string) (appConfig, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return appConfig{}, nil
	}
	if err != nil {
		return appConfig{}, fmt.Errorf("读取配置文件: %w", err)
	}
	var config appConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return appConfig{}, fmt.Errorf("解析配置文件: %w", err)
	}
	config.ConfigFile = path
	return config.ensureIDs(), nil
}

func saveConfigFile(path string, config appConfig) error {
	if strings.TrimSpace(path) == "" {
		path = defaultConfigFile()
	}
	config.ConfigFile = path
	config = config.ensureIDs()
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("编码配置文件: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("创建配置目录: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".fknat-config-*")
	if err != nil {
		return fmt.Errorf("创建配置临时文件: %w", err)
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(append(data, '\n')); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("写入配置文件: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryName, path); err != nil {
		return fmt.Errorf("替换配置文件: %w", err)
	}
	return nil
}

type cliOptions struct {
	nonInteractive bool
	interactive    bool
	showVersion    bool
}

func parseFlags(args []string, output io.Writer) (appConfig, cliOptions, error) {
	config := appConfig{}
	options := cliOptions{}
	var roleValue string
	var relaysValue string
	var remotePortValue uint

	flags := flag.NewFlagSet("fknat", flag.ContinueOnError)
	flags.SetOutput(output)
	flags.StringVar(&roleValue, "mode", envOrDefault("FKNAT_MODE", ""), "运行角色: client 或 server")
	flags.StringVar(&config.IndexAddress, "index", envOrDefault("FKNAT_INDEX_ADDRESS", ""), "Index 地址 host:port；留空时从 CA Web 自动发现")
	flags.StringVar(&config.RelayAddress, "relay", envOrDefault("FKNAT_RELAY_ADDRESS", ""), "固定使用一个 Relay；为空则通过 Index 发现")
	flags.StringVar(&relaysValue, "relays", envOrDefault("FKNAT_RELAY_ADDRESSES", ""), "Server 使用的多个 Relay，逗号分隔，最多三个")
	flags.IntVar(&config.RelayCount, "relay-count", 1, "Server 自动选择的 Relay 数量，1..3")
	flags.StringVar(&config.BillingKeyFile, "billing-key", envOrDefault("BNFS_BILLING_KEY_FILE", ""), "CA Web 导出的扣费私钥 JSON 文件")
	flags.StringVar(&config.BillingSnapshotFile, "billing-snapshot", "", "Server 私有计费恢复快照；默认保存在节点身份文件旁")
	flags.StringVar(&config.IdentityFile, "identity", envOrDefault("FKNAT_IDENTITY_FILE", ""), "节点身份私钥文件；不存在时自动创建")
	flags.StringVar(&config.ListenAddress, "listen", envOrDefault("FKNAT_LISTEN_ADDRESS", ""), "Client 本地 TCP 监听地址；端口 0 表示随机")
	flags.StringVar(&config.ServerNodeID, "server-id", envOrDefault("FKNAT_SERVER_NODE_ID", ""), "Client 要连接的 NatServer NodeID")
	flags.StringVar(&config.ForwardTarget, "target", envOrDefault("FKNAT_FORWARD_TARGET", ""), "Server 实际 TCP 应用地址 host:port")
	flags.UintVar(&remotePortValue, "remote-port", uint(envUint16OrDefault("FKNAT_REMOTE_PORT", 0)), "Client 请求的 Server 目标端口；0 表示 Server 默认目标")
	flags.StringVar(&config.ConfigFile, "config", envOrDefault("FKNAT_CONFIG_FILE", defaultConfigFile()), "JSON 配置文件路径")
	flags.StringVar(&config.WebListenAddress, "web-listen", envOrDefault("FKNAT_WEB_LISTEN", "0.0.0.0:8088"), "Web 管理地址")
	flags.StringVar(&config.WebUser, "web-user", envOrDefault("FKNAT_WEB_USER", ""), "Web 管理用户名；未配置时默认为 admin")
	flags.StringVar(&config.WebPassword, "web-password", envOrDefault("FKNAT_WEB_PASSWORD", ""), "Web 管理密码；未配置时首次启动自动生成")
	flags.IntVar(&config.MaxSessions, "max-sessions", 128, "Server 最大并发 NatClient 会话数")
	flags.IntVar(&config.AcceptQueue, "accept-queue", 128, "Server 已认证会话等待队列长度")
	flags.IntVar(&config.MaxStreams, "max-streams", 1024, "Server 全局最大并发逻辑流数")
	flags.IntVar(&config.MaxStreamsPerSession, "max-streams-per-session", 128, "Server 每个 NatClient 会话最大并发逻辑流数")
	flags.IntVar(&config.DialAttempts, "dial-attempts", 12, "Client 每次建立 P2P 连接的尝试次数")
	flags.DurationVar(&config.RetryDelay, "retry-delay", 3*time.Second, "Client 单次 P2P 拨号重试间隔")
	flags.DurationVar(&config.ReconnectDelay, "reconnect-delay", 3*time.Second, "Client 隧道失效后的重连间隔")
	flags.StringVar(&config.SecurityProfile, "security-profile", envOrDefault("BNFS_SECURITY_PROFILE", "production"), "SDK 安全档: development, staging, production")
	flags.BoolVar(&options.nonInteractive, "non-interactive", false, "关闭交互提示，缺少必填配置时直接失败")
	flags.BoolVar(&options.interactive, "interactive", false, "使用终端配置向导；默认直接启动 Web 管理")
	flags.BoolVar(&options.showVersion, "version", false, "显示版本")
	flags.Usage = func() {
		fmt.Fprintln(output, "fknat - natP2pSDK TCP 端口转发工具")
		fmt.Fprintln(output)
		fmt.Fprintln(output, "直接运行会启动 Web 管理；终端向导可使用 --interactive。")
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
	if remotePortValue > 65535 {
		return appConfig{}, cliOptions{}, errors.New("--remote-port 必须在 0..65535 之间")
	}
	config.RemotePort = uint16(remotePortValue)
	if config.ConfigFile != "" {
		fileConfig, err := loadConfigFile(config.ConfigFile)
		if err != nil {
			return appConfig{}, cliOptions{}, err
		}
		config = mergeConfigDefaults(config, fileConfig)
		// Explicit flags, including empty addresses and zero ports, override
		// persisted configuration. The selected path must never be replaced by
		// a config_file value read from an unrelated file.
		flags.Visit(func(f *flag.Flag) {
			switch f.Name {
			case "web-listen":
				config.WebListenAddress = f.Value.String()
			case "config":
				config.ConfigFile = f.Value.String()
			case "index":
				config.IndexAddress = f.Value.String()
			case "relay":
				config.RelayAddress = f.Value.String()
			case "remote-port":
				config.RemotePort = uint16(remotePortValue)
			}
		})
	}
	if config.WebListenAddress == "" {
		config.WebListenAddress = "0.0.0.0:8088"
	}
	if err := config.normalizeWebAuth(); err != nil {
		return appConfig{}, cliOptions{}, err
	}
	return config, options, nil
}

func mergeConfigDefaults(current, file appConfig) appConfig {
	if current.Role == "" {
		current.Role = file.Role
	}
	if current.IndexAddress == "" {
		current.IndexAddress = file.IndexAddress
	}
	if current.RelayAddress == "" {
		current.RelayAddress = file.RelayAddress
	}
	if len(current.RelayAddresses) == 0 {
		current.RelayAddresses = file.RelayAddresses
	}
	if current.BillingKeyFile == "" {
		current.BillingKeyFile = file.BillingKeyFile
	}
	if current.BillingSnapshotFile == "" {
		current.BillingSnapshotFile = file.BillingSnapshotFile
	}
	if current.IdentityFile == "" {
		current.IdentityFile = file.IdentityFile
	}
	if current.ListenAddress == "" {
		current.ListenAddress = file.ListenAddress
	}
	if current.ServerNodeID == "" {
		current.ServerNodeID = file.ServerNodeID
	}
	if current.ForwardTarget == "" {
		current.ForwardTarget = file.ForwardTarget
	}
	if current.RemotePort == 0 {
		current.RemotePort = file.RemotePort
	}
	if len(current.ClientMappings) == 0 {
		current.ClientMappings = file.ClientMappings
	}
	if len(current.ServerPorts) == 0 {
		current.ServerPorts = file.ServerPorts
	}
	if current.WebListenAddress == "" {
		current.WebListenAddress = file.WebListenAddress
	}
	if current.MaxSessions == 128 && file.MaxSessions != 0 {
		current.MaxSessions = file.MaxSessions
	}
	if current.AcceptQueue == 128 && file.AcceptQueue != 0 {
		current.AcceptQueue = file.AcceptQueue
	}
	if current.MaxStreams == 1024 && file.MaxStreams != 0 {
		current.MaxStreams = file.MaxStreams
	}
	if current.MaxStreamsPerSession == 128 && file.MaxStreamsPerSession != 0 {
		current.MaxStreamsPerSession = file.MaxStreamsPerSession
	}
	if current.DialAttempts == 12 && file.DialAttempts != 0 {
		current.DialAttempts = file.DialAttempts
	}
	if current.RetryDelay == 3*time.Second && file.RetryDelay != 0 {
		current.RetryDelay = file.RetryDelay
	}
	if current.ReconnectDelay == 3*time.Second && file.ReconnectDelay != 0 {
		current.ReconnectDelay = file.ReconnectDelay
	}
	if current.SecurityProfile == "production" && file.SecurityProfile != "" {
		current.SecurityProfile = file.SecurityProfile
	}
	if current.WebUser == "" {
		current.WebUser = file.WebUser
	}
	if current.WebPasswordHash == "" {
		current.WebPasswordHash = file.WebPasswordHash
	}
	if current.RelayCount == 1 && file.RelayCount != 0 {
		current.RelayCount = file.RelayCount
	}
	if current.ConfigFile == "" {
		current.ConfigFile = defaultConfigFile()
	}
	return current.ensureIDs()
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
	if err := config.normalizeWebAuth(); err != nil {
		return err
	}
	if config.ConfigFile == "" {
		config.ConfigFile = defaultConfigFile()
	}
	if config.WebListenAddress == "" {
		config.WebListenAddress = "0.0.0.0:8088"
	}
	if err := validateHostPort(config.WebListenAddress, true, true); err != nil {
		return fmt.Errorf("Web 监听地址无效: %w", err)
	}
	config.RelayAddresses = uniqueStrings(config.RelayAddresses)
	*config = config.ensureIDs()

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
	if config.BillingSnapshotFile == "" {
		config.BillingSnapshotFile = config.IdentityFile + ".billing.json"
	}

	switch config.Role {
	case roleClient:
		if config.ListenAddress != "" {
			config.ListenAddress, err = normalizeListenAddress(config.ListenAddress)
			if err != nil {
				return err
			}
		}
		config.ServerNodeID = strings.TrimSpace(config.ServerNodeID)
		if config.ServerNodeID != "" {
			if _, err := parseServerNodeID(config.ServerNodeID); err != nil {
				return err
			}
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
		for index := range config.ClientMappings {
			mapping := &config.ClientMappings[index]
			mapping.Protocol = normalizeProtocol(mapping.Protocol)
			mapping.Listen, err = normalizeListenAddress(mapping.Listen)
			if err != nil {
				return fmt.Errorf("Client 映射 %s 无效: %w", mapping.ID, err)
			}
			if mapping.RemotePort == 0 {
				continue
			}
		}
	case roleServer:
		if config.ForwardTarget != "" {
			config.ForwardTarget, err = normalizeForwardTarget(config.ForwardTarget)
			if err != nil {
				return err
			}
		}
		if config.MaxSessions < 1 || config.AcceptQueue < 1 || config.MaxStreams < 1 || config.MaxStreamsPerSession < 1 {
			return errors.New("--max-sessions、--accept-queue、--max-streams 和 --max-streams-per-session 必须大于 0")
		}
		zeroRoutePorts := map[string]int{}
		for _, value := range config.ServerPorts {
			if value.Enabled && value.Port == 0 {
				zeroRoutePorts[normalizeProtocol(value.Protocol)]++
			}
		}
		for protocol, count := range zeroRoutePorts {
			if count > 1 {
				return fmt.Errorf("Server 的 %s 规则只能配置一个不指定逻辑路由端口的默认目标；多个目标请填写不同的逻辑路由端口", strings.ToUpper(protocol))
			}
		}
		for index := range config.ServerPorts {
			port := &config.ServerPorts[index]
			port.Protocol = normalizeProtocol(port.Protocol)
			if port.Target == "" {
				if port.Port == 0 {
					return fmt.Errorf("Server 默认目标 %s 必须填写转发端口", port.ID)
				}
				port.Target = net.JoinHostPort("127.0.0.1", strconv.Itoa(int(port.Port)))
			}
			port.Target, err = normalizeForwardTarget(port.Target)
			if err != nil {
				return fmt.Errorf("Server 转发端口 %s 无效: %w", port.ID, err)
			}
		}
	}
	if config.Role == roleClient && len(config.ClientMappings) == 0 && config.ListenAddress != "" {
		port := config.RemotePort
		config.ClientMappings = []PortMapping{{ID: "client-1", Protocol: "tcp", Listen: config.ListenAddress, RemotePort: port, Enabled: true}}
	}
	if config.Role == roleServer && len(config.ServerPorts) == 0 && config.ForwardTarget != "" {
		_, portText, _ := net.SplitHostPort(config.ForwardTarget)
		port, _ := strconv.Atoi(portText)
		config.ServerPorts = []AllowedPort{{ID: "server-1", Protocol: "tcp", Port: uint16(port), Target: config.ForwardTarget, Enabled: true}}
	}
	*config = config.ensureIDs()
	return nil
}

func (config *appConfig) normalizeWebAuth() error {
	config.WebUser = strings.TrimSpace(config.WebUser)
	if config.WebUser == "" && config.WebPassword == "" && config.WebPasswordHash == "" {
		return nil
	}
	if config.WebUser == "" {
		return errors.New("Web 登录用户名不能为空")
	}
	if config.WebPassword != "" {
		if len(config.WebPassword) < 8 {
			return errors.New("Web 登录密码至少需要 8 个字符")
		}
		hash, err := bcrypt.GenerateFromPassword([]byte(config.WebPassword), bcrypt.DefaultCost)
		if err != nil {
			return fmt.Errorf("生成 Web 登录密码哈希失败: %w", err)
		}
		config.WebPasswordHash = string(hash)
		config.WebPassword = ""
	}
	if config.WebPasswordHash == "" {
		return errors.New("Web 登录密码不能为空")
	}
	return nil
}

// ensureWebAuthDefaults makes the Web console authenticated on every normal
// startup. An empty configuration gets an admin user and a one-time random
// password; only the bcrypt hash is persisted by the caller.
func ensureWebAuthDefaults(config *appConfig) (string, error) {
	config.WebUser = strings.TrimSpace(config.WebUser)
	if config.WebUser == "" && config.WebPassword == "" && config.WebPasswordHash == "" {
		config.WebUser = "admin"
		bytes := make([]byte, 18)
		if _, err := rand.Read(bytes); err != nil {
			return "", fmt.Errorf("生成 Web 初始密码失败: %w", err)
		}
		password := hex.EncodeToString(bytes)
		config.WebPassword = password
		if err := config.normalizeWebAuth(); err != nil {
			return "", err
		}
		return password, nil
	}
	if err := config.normalizeWebAuth(); err != nil {
		return "", err
	}
	return "", nil
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

func envUint16OrDefault(name string, fallback uint16) uint16 {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseUint(value, 10, 16)
	if err != nil {
		return fallback
	}
	return uint16(parsed)
}
