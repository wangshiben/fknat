package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/wangshiben/QuicFrameWork/RouteDisPatch"
	qserver "github.com/wangshiben/QuicFrameWork/server"
	"golang.org/x/crypto/bcrypt"
)

//go:embed web/dist/*
var webAssets embed.FS

const webAuthenticatedSessionKey = "fknat.web.authenticated"

type runtimeController struct {
	mu             sync.RWMutex
	config         appConfig
	rootCtx        context.Context
	roleStop       context.CancelFunc
	roleDone       chan error
	roleGeneration uint64
	status         string
	lastErr        string
	nodeID         string
	startedAt      time.Time
	logger         *log.Logger
	output         io.Writer
}

func newRuntimeController(ctx context.Context, config appConfig, output io.Writer, logger *log.Logger) *runtimeController {
	if ctx == nil {
		ctx = context.Background()
	}
	if output == nil {
		output = io.Discard
	}
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	if config.ConfigFile == "" {
		config.ConfigFile = defaultConfigFile()
	}
	if config.WebListenAddress == "" {
		config.WebListenAddress = "0.0.0.0:8088"
	}
	if config.SecurityProfile == "" {
		config.SecurityProfile = "production"
	}
	if err := config.normalizeWebAuth(); err != nil {
		return &runtimeController{config: config, rootCtx: ctx, status: "configuration_error", lastErr: err.Error(), startedAt: time.Now(), logger: logger, output: output}
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
	return &runtimeController{config: config.ensureIDs(), rootCtx: ctx, status: "waiting_for_configuration", startedAt: time.Now(), logger: logger, output: output}
}

func (controller *runtimeController) start() error {
	controller.mu.Lock()
	controller.startRoleLocked()
	address := controller.config.WebListenAddress
	controller.mu.Unlock()
	listener, err := net.Listen("tcp", address)
	if err != nil && strings.HasSuffix(address, ":8088") {
		fallback := "0.0.0.0:0"
		listener, err = net.Listen("tcp4", fallback)
		if err == nil {
			address = listener.Addr().String()
			controller.logger.Printf("Web 地址 %s 已占用，自动切换到 %s", controller.config.WebListenAddress, address)
		}
	}
	if err != nil {
		return err
	}
	webServer := controller.frameworkServer(address)
	go func() {
		<-controller.rootCtx.Done()
		shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = webServer.Server.Shutdown(shutdownContext)
		cancel()
		controller.stopRole()
	}()
	go controller.cleanWebSessions(webServer)
	controller.logger.Printf("fknat Web 管理地址: http://%s/（QuicFrameWork）", address)
	err = webServer.Serve(listener)
	controller.stopRole()
	_ = webServer.Session.Close()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (controller *runtimeController) cleanWebSessions(webServer *qserver.Server) {
	interval := webServer.Session.GetNextTimePicker()
	if interval <= 0 {
		interval = 15 * time.Minute
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-controller.rootCtx.Done():
			return
		case <-ticker.C:
			webServer.Session.CleanExpItem()
		}
	}
}

func (controller *runtimeController) startRoleLocked() {
	controller.stopRoleLocked()
	controller.roleGeneration++
	generation := controller.roleGeneration
	controller.nodeID = ""
	config := controller.config
	if !roleReady(config) {
		controller.status = "waiting_for_configuration"
		return
	}
	if err := config.normalizeAndValidate(); err != nil {
		controller.status = "configuration_error"
		controller.lastErr = err.Error()
		return
	}
	if err := configureSDKEnvironment(config); err != nil {
		controller.status = "configuration_error"
		controller.lastErr = err.Error()
		return
	}
	roleContext, cancel := context.WithCancel(controller.rootCtx)
	controller.roleStop = cancel
	controller.roleDone = make(chan error, 1)
	controller.status = "starting"
	controller.lastErr = ""
	controller.config = config
	go func() {
		var err error
		reportNodeID := func(nodeID string) {
			controller.mu.Lock()
			if controller.roleGeneration == generation {
				controller.nodeID = nodeID
			}
			controller.mu.Unlock()
		}
		if config.Role == roleClient {
			err = runClientWithNodeID(roleContext, config, controller.output, controller.logger, func(routeErr error) {
				controller.mu.Lock()
				if controller.roleGeneration == generation && routeErr != nil {
					controller.lastErr = routeErr.Error()
					controller.status = "route_error"
				}
				controller.mu.Unlock()
			}, reportNodeID)
		} else {
			err = runServer(roleContext, config, controller.output, controller.logger, reportNodeID)
		}
		controller.roleDone <- err
		controller.mu.Lock()
		if controller.roleGeneration == generation {
			if err != nil && roleContext.Err() == nil {
				controller.status = "error"
				controller.lastErr = err.Error()
			} else if roleContext.Err() != nil {
				controller.status = "stopped"
			}
		}
		controller.mu.Unlock()
	}()
	controller.status = "running"
}

func (controller *runtimeController) stopRoleLocked() {
	if controller.roleStop != nil {
		controller.roleStop()
		controller.roleStop = nil
	}
	if controller.roleDone != nil {
		select {
		case <-controller.roleDone:
		default:
		}
	}
	controller.roleDone = nil
}

func (controller *runtimeController) stopRole() {
	controller.mu.Lock()
	controller.stopRoleLocked()
	controller.mu.Unlock()
}

func (controller *runtimeController) update(mutator func(*appConfig) error) error {
	controller.mu.Lock()
	previous := controller.config
	updated := controller.config
	if err := mutator(&updated); err != nil {
		controller.mu.Unlock()
		return err
	}
	updated = updated.ensureIDs()
	if updated.ConfigFile == "" {
		updated.ConfigFile = controller.config.ConfigFile
	}
	if err := updated.normalizeWebAuth(); err != nil {
		controller.mu.Unlock()
		return err
	}
	if roleReady(updated) {
		if err := updated.normalizeAndValidate(); err != nil {
			controller.mu.Unlock()
			return err
		}
	}
	controller.mu.Unlock()
	if err := changeConfiguredNodeMode(controller.rootCtx, previous, updated); err != nil {
		return err
	}
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if err := saveConfigFile(updated.ConfigFile, updated); err != nil {
		return err
	}
	controller.config = updated
	controller.startRoleLocked()
	return nil
}

func roleReady(config appConfig) bool {
	if config.Role != roleClient && config.Role != roleServer {
		return false
	}
	if strings.TrimSpace(config.BillingKeyFile) == "" && strings.ToLower(config.SecurityProfile) == "production" {
		return false
	}
	if config.Role == roleClient {
		return strings.TrimSpace(config.ServerNodeID) != "" && len(enabledClientMappings(config)) > 0
	}
	return len(enabledServerPorts(config)) > 0 || strings.TrimSpace(config.ForwardTarget) != ""
}

func enabledClientMappings(config appConfig) []PortMapping {
	result := make([]PortMapping, 0, len(config.ClientMappings))
	for _, value := range config.ClientMappings {
		if value.Enabled {
			result = append(result, value)
		}
	}
	return result
}

func enabledServerPorts(config appConfig) []AllowedPort {
	result := make([]AllowedPort, 0, len(config.ServerPorts))
	for _, value := range config.ServerPorts {
		if value.Enabled {
			result = append(result, value)
		}
	}
	return result
}

type publicRuntime struct {
	Mode      role         `json:"mode"`
	Status    string       `json:"status"`
	NodeID    string       `json:"node_id,omitempty"`
	LastError string       `json:"last_error,omitempty"`
	Config    publicConfig `json:"config"`
	StartedAt time.Time    `json:"started_at"`
}

type publicConfig struct {
	Mode             role          `json:"mode"`
	IndexAddress     string        `json:"index_address"`
	RelayAddress     string        `json:"relay_address"`
	RelayAddresses   []string      `json:"relay_addresses,omitempty"`
	ServerNodeID     string        `json:"server_node_id,omitempty"`
	ListenAddress    string        `json:"listen_address,omitempty"`
	ForwardTarget    string        `json:"forward_target,omitempty"`
	RemotePort       uint16        `json:"remote_port,omitempty"`
	ClientMappings   []PortMapping `json:"client_mappings,omitempty"`
	ServerPorts      []AllowedPort `json:"server_ports,omitempty"`
	WebListenAddress string        `json:"web_listen_address"`
	WebUser          string        `json:"web_user,omitempty"`
	AuthRequired     bool          `json:"auth_required"`
	ConfigFile       string        `json:"config_file"`
	SecurityProfile  string        `json:"security_profile"`
	// These are file paths only. The Web API never returns private key contents.
	BillingKeyFile string `json:"billing_key_file,omitempty"`
	IdentityFile   string `json:"identity_file,omitempty"`
}

func (controller *runtimeController) snapshot() publicRuntime {
	controller.mu.RLock()
	defer controller.mu.RUnlock()
	return publicRuntime{Mode: controller.config.Role, Status: controller.status, NodeID: controller.nodeID, LastError: controller.lastErr, StartedAt: controller.startedAt, Config: publicConfig{
		Mode: controller.config.Role, IndexAddress: controller.config.IndexAddress, RelayAddress: controller.config.RelayAddress, RelayAddresses: append([]string(nil), controller.config.RelayAddresses...), ServerNodeID: controller.config.ServerNodeID, ListenAddress: controller.config.ListenAddress, ForwardTarget: controller.config.ForwardTarget, RemotePort: controller.config.RemotePort, ClientMappings: append([]PortMapping(nil), controller.config.ClientMappings...), ServerPorts: append([]AllowedPort(nil), controller.config.ServerPorts...), WebListenAddress: controller.config.WebListenAddress, WebUser: controller.config.WebUser, AuthRequired: controller.webAuthRequired(), ConfigFile: controller.config.ConfigFile, SecurityProfile: controller.config.SecurityProfile, BillingKeyFile: controller.config.BillingKeyFile, IdentityFile: controller.config.IdentityFile,
	}}
}

func (controller *runtimeController) webAuthRequired() bool {
	return strings.TrimSpace(controller.config.WebUser) != "" && strings.TrimSpace(controller.config.WebPasswordHash) != ""
}

func (controller *runtimeController) frameworkServer(address string) *qserver.Server {
	webServer := qserver.NewHttpServer(address)
	webServer.AddHttpHandler("/", http.MethodGet, controller.handleAssetRoute)
	webServer.AddHttpHandler("/**", http.MethodGet, controller.handleAssetRoute)
	webServer.AddHttpHandler("/**", http.MethodOptions, func(writer http.ResponseWriter, _ *RouteDisPatch.Request) { writer.WriteHeader(http.StatusNoContent) })

	webServer.AddHttpHandler("/api/auth/status", http.MethodGet, controller.handleAuthStatusRoute)
	webServer.AddHttpHandler("/api/auth/login", http.MethodPost, controller.handleAuthLoginRoute)
	webServer.AddHttpHandler("/api/auth/logout", http.MethodPost, controller.handleAuthLogoutRoute)
	webServer.AddHttpHandler("/api/status", http.MethodGet, controller.handleStatusRoute)
	webServer.AddHttpHandler("/api/config", http.MethodGet, controller.handleConfigRoute)
	webServer.AddHttpHandler("/api/config", http.MethodPut, controller.handleConfigRoute)
	webServer.AddHttpHandler("/api/config", http.MethodPost, controller.handleConfigRoute)
	webServer.AddHttpHandler("/api/client/mappings", http.MethodPost, controller.handleClientMappingsRoute)
	webServer.AddHttpHandler("/api/client/mappings/**", http.MethodPut, controller.handleClientMappingsRoute)
	webServer.AddHttpHandler("/api/client/mappings/**", http.MethodPatch, controller.handleClientMappingsRoute)
	webServer.AddHttpHandler("/api/client/mappings/**", http.MethodDelete, controller.handleClientMappingsRoute)
	webServer.AddHttpHandler("/api/server/ports", http.MethodPost, controller.handleServerPortsRoute)
	webServer.AddHttpHandler("/api/server/ports/**", http.MethodPut, controller.handleServerPortsRoute)
	webServer.AddHttpHandler("/api/server/ports/**", http.MethodPatch, controller.handleServerPortsRoute)
	webServer.AddHttpHandler("/api/server/ports/**", http.MethodDelete, controller.handleServerPortsRoute)
	webServer.AddHttpHandler("/api/retry", http.MethodPost, controller.handleRetryRoute)

	webServer.Route.AddFilter("/**", controller.corsFilter)
	for _, route := range []string{"/api/status", "/api/config", "/api/client/mappings/**", "/api/server/ports/**", "/api/retry"} {
		webServer.Route.AddFilter(route, controller.authFilter)
	}
	return webServer
}

// handler is retained for httptest-based callers. Production serving uses the
// same QuicFrameWork Server through start().
func (controller *runtimeController) handler() http.Handler {
	return controller.frameworkServer(controller.config.WebListenAddress).Server.Handler
}

func (controller *runtimeController) corsFilter(writer http.ResponseWriter, request *RouteDisPatch.Request, next RouteDisPatch.Next) {
	origin := request.GetRequest().Header.Get("Origin")
	if origin != "" {
		writer.Header().Set("Access-Control-Allow-Origin", origin)
		writer.Header().Add("Vary", "Origin")
	}
	writer.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	writer.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
	if request.GetRequest().Method == http.MethodOptions {
		writer.WriteHeader(http.StatusNoContent)
		return
	}
	next.Next(writer, request)
}

func (controller *runtimeController) authFilter(writer http.ResponseWriter, request *RouteDisPatch.Request, next RouteDisPatch.Next) {
	if request.GetRequest().Method == http.MethodOptions || !controller.webAuthRequired() {
		next.Next(writer, request)
		return
	}
	session, err := request.GetSession()
	if err != nil {
		writeJSON(writer, http.StatusUnauthorized, map[string]string{"error": "需要有效的 Web 会话"})
		return
	}
	value, _ := session.GetStoreValue(webAuthenticatedSessionKey)
	authenticated, _ := value.(bool)
	if !authenticated {
		writeJSON(writer, http.StatusUnauthorized, map[string]string{"error": "需要登录 Web 管理界面"})
		return
	}
	next.Next(writer, request)
}

func (controller *runtimeController) handleAssetRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleAsset(writer, request.GetRequest())
}

func (controller *runtimeController) handleStatusRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleStatus(writer, request.GetRequest())
}

func (controller *runtimeController) handleConfigRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleConfig(writer, request.GetRequest())
}

func (controller *runtimeController) handleClientMappingsRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleClientMappings(writer, request.GetRequest())
}

func (controller *runtimeController) handleServerPortsRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleServerPorts(writer, request.GetRequest())
}

func (controller *runtimeController) handleRetryRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleRetry(writer, request.GetRequest())
}

func (controller *runtimeController) handleAuthStatusRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleAuthStatus(writer, request)
}

func (controller *runtimeController) handleAuthLoginRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleAuthLogin(writer, request)
}

func (controller *runtimeController) handleAuthLogoutRoute(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	controller.handleAuthLogout(writer, request)
}

func (controller *runtimeController) handleAuthStatus(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	if !controller.webAuthRequired() {
		writeJSON(writer, http.StatusOK, map[string]any{"required": false, "authenticated": true, "user": ""})
		return
	}
	session, err := request.GetSession()
	if err != nil {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": "创建 Web 会话失败"})
		return
	}
	value, _ := session.GetStoreValue(webAuthenticatedSessionKey)
	authenticated, _ := value.(bool)
	writeJSON(writer, http.StatusOK, map[string]any{"required": true, "authenticated": authenticated, "user": controller.config.WebUser})
}

func (controller *runtimeController) handleAuthLogin(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	if !controller.webAuthRequired() {
		writeJSON(writer, http.StatusOK, map[string]any{"authenticated": true})
		return
	}
	var credentials struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(io.LimitReader(request.GetRequest().Body, 64<<10)).Decode(&credentials); err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "登录请求格式无效"})
		return
	}
	controller.mu.RLock()
	user, passwordHash := controller.config.WebUser, controller.config.WebPasswordHash
	controller.mu.RUnlock()
	if credentials.Username != user || bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(credentials.Password)) != nil {
		writeJSON(writer, http.StatusUnauthorized, map[string]string{"error": "用户名或密码错误"})
		return
	}
	session, err := request.GetSession()
	if err != nil {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": "创建 Web 会话失败"})
		return
	}
	if err := session.Store(webAuthenticatedSessionKey, true); err != nil {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": "保存 Web 会话失败"})
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{"authenticated": true, "user": user})
}

func (controller *runtimeController) handleAuthLogout(writer http.ResponseWriter, request *RouteDisPatch.Request) {
	session, err := request.GetSession()
	if err == nil {
		_, _ = session.RemoveStoreValue(webAuthenticatedSessionKey)
	}
	writeJSON(writer, http.StatusOK, map[string]any{"authenticated": false})
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func (controller *runtimeController) handleStatus(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	writeJSON(writer, http.StatusOK, controller.snapshot())
}

func (controller *runtimeController) handleConfig(writer http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodGet {
		writeJSON(writer, http.StatusOK, controller.snapshot().Config)
		return
	}
	if request.Method != http.MethodPut && request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var incoming struct {
		publicConfig
	}
	if err := json.NewDecoder(io.LimitReader(request.Body, 1<<20)).Decode(&incoming); err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	err := controller.update(func(config *appConfig) error {
		if incoming.WebListenAddress != "" && incoming.WebListenAddress != config.WebListenAddress {
			return errors.New("Web 监听地址不能通过 Web 控制台修改，请使用启动参数并重启")
		}
		config.Role = incoming.Mode
		config.IndexAddress = strings.TrimSpace(incoming.IndexAddress)
		config.RelayAddress = strings.TrimSpace(incoming.RelayAddress)
		config.RelayAddresses = incoming.RelayAddresses
		config.ServerNodeID = strings.TrimSpace(incoming.ServerNodeID)
		config.ListenAddress = strings.TrimSpace(incoming.ListenAddress)
		config.ForwardTarget = strings.TrimSpace(incoming.ForwardTarget)
		config.RemotePort = incoming.RemotePort
		config.ClientMappings = incoming.ClientMappings
		config.ServerPorts = incoming.ServerPorts
		if incoming.SecurityProfile != "" {
			config.SecurityProfile = incoming.SecurityProfile
		}
		if incoming.publicConfig.BillingKeyFile != "" {
			config.BillingKeyFile = incoming.publicConfig.BillingKeyFile
		}
		if incoming.publicConfig.IdentityFile != "" {
			config.IdentityFile = incoming.publicConfig.IdentityFile
		}
		return nil
	})
	if err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(writer, http.StatusOK, controller.snapshot())
}

func (controller *runtimeController) handleClientMappings(writer http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodPut || request.Method == http.MethodPatch {
		id := strings.TrimPrefix(request.URL.Path, "/api/client/mappings/")
		if id == "" || id == request.URL.Path {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "缺少映射 ID"})
			return
		}
		var mapping PortMapping
		if err := json.NewDecoder(io.LimitReader(request.Body, 64<<10)).Decode(&mapping); err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		mapping.ID = id
		mapping.Protocol = normalizeProtocol(mapping.Protocol)
		mapping.Enabled = true
		err := controller.update(func(config *appConfig) error {
			for index := range config.ClientMappings {
				if config.ClientMappings[index].ID == id {
					config.ClientMappings[index] = mapping
					return nil
				}
			}
			return fmt.Errorf("映射 %s 不存在", id)
		})
		if err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(writer, http.StatusOK, controller.snapshot().Config)
		return
	}
	if request.Method == http.MethodDelete {
		id := strings.TrimPrefix(request.URL.Path, "/api/client/mappings/")
		if id == "" || id == request.URL.Path {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "缺少映射 ID"})
			return
		}
		err := controller.update(func(config *appConfig) error {
			filtered := config.ClientMappings[:0]
			for _, mapping := range config.ClientMappings {
				if mapping.ID != id {
					filtered = append(filtered, mapping)
				}
			}
			config.ClientMappings = filtered
			return nil
		})
		if err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(writer, http.StatusOK, controller.snapshot().Config)
		return
	}
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var mapping PortMapping
	if err := json.NewDecoder(io.LimitReader(request.Body, 64<<10)).Decode(&mapping); err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if mapping.ID == "" {
		mapping.ID = fmt.Sprintf("client-%d", time.Now().UnixNano())
	}
	mapping.Protocol = normalizeProtocol(mapping.Protocol)
	mapping.Enabled = true
	err := controller.update(func(config *appConfig) error {
		if config.Role == "" {
			config.Role = roleClient
		}
		config.ClientMappings = append(config.ClientMappings, mapping)
		return nil
	})
	if err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(writer, http.StatusOK, controller.snapshot().Config)
}

func (controller *runtimeController) handleServerPorts(writer http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodPut || request.Method == http.MethodPatch {
		id := strings.TrimPrefix(request.URL.Path, "/api/server/ports/")
		if id == "" || id == request.URL.Path {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "缺少转发端口 ID"})
			return
		}
		var port AllowedPort
		if err := json.NewDecoder(io.LimitReader(request.Body, 64<<10)).Decode(&port); err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		port.ID = id
		port.Protocol = normalizeProtocol(port.Protocol)
		port.Enabled = true
		err := controller.update(func(config *appConfig) error {
			if config.Role == "" {
				config.Role = roleServer
			}
			for index := range config.ServerPorts {
				if config.ServerPorts[index].ID == id {
					config.ServerPorts[index] = port
					return nil
				}
			}
			return fmt.Errorf("转发端口 %s 不存在", id)
		})
		if err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(writer, http.StatusOK, controller.snapshot().Config)
		return
	}
	if request.Method == http.MethodDelete {
		id := strings.TrimPrefix(request.URL.Path, "/api/server/ports/")
		if id == "" || id == request.URL.Path {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "缺少转发端口 ID"})
			return
		}
		err := controller.update(func(config *appConfig) error {
			filtered := config.ServerPorts[:0]
			for _, port := range config.ServerPorts {
				if port.ID != id {
					filtered = append(filtered, port)
				}
			}
			config.ServerPorts = filtered
			if len(config.ServerPorts) == 0 {
				config.ForwardTarget = ""
			}
			return nil
		})
		if err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(writer, http.StatusOK, controller.snapshot().Config)
		return
	}
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var port AllowedPort
	if err := json.NewDecoder(io.LimitReader(request.Body, 64<<10)).Decode(&port); err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if port.ID == "" {
		port.ID = fmt.Sprintf("server-%d", time.Now().UnixNano())
	}
	port.Protocol = normalizeProtocol(port.Protocol)
	port.Enabled = true
	err := controller.update(func(config *appConfig) error {
		// Adding a Server allow-list entry from the Web console is an explicit
		// choice of the Server role when no role has been selected yet.
		if config.Role == "" {
			config.Role = roleServer
		}
		config.ServerPorts = append(config.ServerPorts, port)
		return nil
	})
	if err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(writer, http.StatusOK, controller.snapshot().Config)
}

func (controller *runtimeController) handleRetry(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	controller.mu.Lock()
	controller.startRoleLocked()
	controller.mu.Unlock()
	writeJSON(writer, http.StatusOK, controller.snapshot())
}

func (controller *runtimeController) handleAsset(writer http.ResponseWriter, request *http.Request) {
	asset := strings.TrimPrefix(path.Clean(request.URL.Path), "/")
	if asset == "." || asset == "" {
		asset = "index.html"
	}
	data, err := webAssets.ReadFile("web/dist/" + asset)
	if err != nil {
		data, err = webAssets.ReadFile("web/dist/index.html")
	}
	if err != nil {
		http.Error(writer, "web asset unavailable", http.StatusNotFound)
		return
	}
	contentType := "text/html; charset=utf-8"
	if strings.HasSuffix(asset, ".js") {
		contentType = "application/javascript; charset=utf-8"
	}
	if strings.HasSuffix(asset, ".css") {
		contentType = "text/css; charset=utf-8"
	}
	writer.Header().Set("Content-Type", contentType)
	_, _ = writer.Write(data)
}
