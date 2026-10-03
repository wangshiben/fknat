package main

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestWebStatusAndConfigPersistence(t *testing.T) {
	config := appConfig{Role: roleClient, SecurityProfile: "development", RelayCount: 1, MaxSessions: 128, AcceptQueue: 128, MaxStreams: 1024, MaxStreamsPerSession: 128, DialAttempts: 1, RetryDelay: time.Second, ReconnectDelay: time.Second, ConfigFile: t.TempDir() + "/config.json", WebListenAddress: "127.0.0.1:0"}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	controller := newRuntimeController(ctx, config, io.Discard, log.New(io.Discard, "", 0))
	server := httptest.NewServer(controller.handler())
	defer server.Close()
	response, err := http.Get(server.URL + "/api/status")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status code = %d", response.StatusCode)
	}
	var status publicRuntime
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		t.Fatal(err)
	}
	if status.Status != "waiting_for_configuration" {
		t.Fatalf("status = %q", status.Status)
	}
	payload := `{"mode":"client","security_profile":"development","index_address":"127.0.0.1:1","server_node_id":"` + strings.Repeat("a", 64) + `","client_mappings":[{"id":"one","protocol":"tcp","listen":"127.0.0.1:18080","remote_port":8080,"enabled":true}]}`
	request, _ := http.NewRequest(http.MethodPut, server.URL+"/api/config", strings.NewReader(payload))
	request.Header.Set("Content-Type", "application/json")
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("config update status=%d body=%s", response.StatusCode, body)
	}
	loaded, err := loadConfigFile(config.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.ServerNodeID == "" || len(loaded.ClientMappings) != 1 {
		t.Fatalf("loaded=%+v", loaded)
	}
	changedListen, _ := http.NewRequest(http.MethodPut, server.URL+"/api/config", strings.NewReader(`{"web_listen_address":"127.0.0.1:9999"}`))
	changedListen.Header.Set("Content-Type", "application/json")
	changedResponse, err := http.DefaultClient.Do(changedListen)
	if err != nil {
		t.Fatal(err)
	}
	changedResponse.Body.Close()
	if changedResponse.StatusCode != http.StatusBadRequest {
		t.Fatalf("changing Web listen address returned %d, want 400", changedResponse.StatusCode)
	}
	if status.Config.BillingKeyFile != "" || status.Config.IdentityFile != "" {
		t.Fatalf("unexpected secret paths in initial status: %+v", status.Config)
	}
}

func TestWebUpdatesMappingsAndPorts(t *testing.T) {
	config := appConfig{Role: roleClient, SecurityProfile: "development", IndexAddress: "127.0.0.1:1", ServerNodeID: strings.Repeat("a", 64), RelayCount: 1, MaxSessions: 1, AcceptQueue: 1, MaxStreams: 1, MaxStreamsPerSession: 1, DialAttempts: 1, RetryDelay: time.Second, ReconnectDelay: time.Second, ConfigFile: t.TempDir() + "/config.json", WebListenAddress: "127.0.0.1:0", ClientMappings: []PortMapping{{ID: "one", Protocol: "tcp", Listen: "127.0.0.1:18080", RemotePort: 8080, Enabled: true}}}
	controller := newRuntimeController(context.Background(), config, io.Discard, log.New(io.Discard, "", 0))
	server := httptest.NewServer(controller.handler())
	defer server.Close()
	put := func(path, body string) {
		request, _ := http.NewRequest(http.MethodPut, server.URL+path, strings.NewReader(body))
		request.Header.Set("Content-Type", "application/json")
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			data, _ := io.ReadAll(response.Body)
			t.Fatalf("PUT %s status=%d body=%s", path, response.StatusCode, data)
		}
	}
	put("/api/client/mappings/one", `{"protocol":"udp","listen":"127.0.0.1:18081","remote_port":5353}`)
	loaded, err := loadConfigFile(config.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.ClientMappings[0].Protocol != "udp" || loaded.ClientMappings[0].RemotePort != 5353 {
		t.Fatalf("updated client mapping = %+v", loaded.ClientMappings[0])
	}

	config.Role = roleServer
	config.ClientMappings = nil
	config.ServerPorts = []AllowedPort{{ID: "http", Protocol: "tcp", Port: 8080, Target: "127.0.0.1:18080", Enabled: true}}
	if err := saveConfigFile(config.ConfigFile, config); err != nil {
		t.Fatal(err)
	}
	controller.mu.Lock()
	controller.config = config
	controller.mu.Unlock()
	put("/api/server/ports/http", `{"protocol":"tcp","port":8081,"target":"127.0.0.1:18081"}`)
	loaded, err = loadConfigFile(config.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.ServerPorts[0].Port != 8081 || loaded.ServerPorts[0].Target != "127.0.0.1:18081" {
		t.Fatalf("updated server port = %+v", loaded.ServerPorts[0])
	}
}

func TestWebDeletingExplicitPortsDisablesLegacyFallback(t *testing.T) {
	configPath := t.TempDir() + "/config.json"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	config := appConfig{
		Role: roleServer, SecurityProfile: "development", IndexAddress: "127.0.0.1:1", RelayCount: 1,
		MaxSessions: 1, AcceptQueue: 1, MaxStreams: 1, MaxStreamsPerSession: 1,
		DialAttempts: 1, RetryDelay: time.Second, ReconnectDelay: time.Second,
		ForwardTarget: "127.0.0.1:18080", ConfigFile: configPath,
		ServerPorts: []AllowedPort{
			{ID: "one", Protocol: "tcp", Port: 18080, Target: "127.0.0.1:18080", Enabled: true},
			{ID: "two", Protocol: "tcp", Port: 18081, Target: "127.0.0.1:18081", Enabled: true},
		},
	}
	controller := newRuntimeController(ctx, config, io.Discard, log.New(io.Discard, "", 0))
	server := httptest.NewServer(controller.handler())
	defer server.Close()
	remove := func(id string) {
		request, _ := http.NewRequest(http.MethodDelete, server.URL+"/api/server/ports/"+id, nil)
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			data, _ := io.ReadAll(response.Body)
			t.Fatalf("DELETE %s status=%d body=%s", id, response.StatusCode, data)
		}
	}
	remove("one")
	loaded, err := loadConfigFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.ForwardTarget == "" || len(loaded.ServerPorts) != 1 {
		t.Fatalf("first delete unexpectedly cleared fallback or ports: %+v", loaded)
	}
	remove("two")
	loaded, err = loadConfigFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.ForwardTarget != "" || len(loaded.ServerPorts) != 0 {
		t.Fatalf("last delete left fallback enabled: %+v", loaded)
	}
}

func TestWebAuthUsesQuicFrameWorkSession(t *testing.T) {
	config := appConfig{
		SecurityProfile:  "development",
		WebUser:          "admin",
		WebPassword:      "correct-password",
		ConfigFile:       t.TempDir() + "/config.json",
		WebListenAddress: "127.0.0.1:0",
	}
	controller := newRuntimeController(context.Background(), config, io.Discard, log.New(io.Discard, "", 0))
	server := httptest.NewServer(controller.handler())
	defer server.Close()
	client := &http.Client{Jar: mustCookieJar(t)}

	status := func() *http.Response {
		response, err := client.Get(server.URL + "/api/auth/status")
		if err != nil {
			t.Fatal(err)
		}
		return response
	}
	response := status()
	if response.StatusCode != http.StatusOK || len(response.Cookies()) != 1 || response.Cookies()[0].Name != "quickSession" {
		t.Fatalf("auth status response = %d cookies=%v", response.StatusCode, response.Cookies())
	}
	response.Body.Close()
	response, err := client.Get(server.URL + "/api/status")
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d, want 401", response.StatusCode)
	}
	response.Body.Close()

	login := func(username, password string) *http.Response {
		body := strings.NewReader(`{"username":"` + username + `","password":"` + password + `"}`)
		request, _ := http.NewRequest(http.MethodPost, server.URL+"/api/auth/login", body)
		request.Header.Set("Content-Type", "application/json")
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		return response
	}
	response = login("admin", "wrong-password")
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong password status = %d", response.StatusCode)
	}
	response.Body.Close()
	response = login("admin", "correct-password")
	if response.StatusCode != http.StatusOK {
		t.Fatalf("correct password status = %d", response.StatusCode)
	}
	response.Body.Close()
	response, err = client.Get(server.URL + "/api/status")
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("authenticated status = %d, want 200", response.StatusCode)
	}
	response.Body.Close()
}

func mustCookieJar(t *testing.T) http.CookieJar {
	t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	return jar
}
