package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestParseRole(t *testing.T) {
	for input, expected := range map[string]role{
		"client": roleClient,
		"C":      roleClient,
		"1":      roleClient,
		"server": roleServer,
		"S":      roleServer,
		"2":      roleServer,
	} {
		actual, err := parseRole(input)
		if err != nil {
			t.Fatalf("parseRole(%q): %v", input, err)
		}
		if actual != expected {
			t.Fatalf("parseRole(%q) = %q, want %q", input, actual, expected)
		}
	}
	if _, err := parseRole("relay"); err == nil {
		t.Fatal("parseRole(relay) unexpectedly succeeded")
	}
}

func TestNormalizeListenAddress(t *testing.T) {
	tests := map[string]string{
		"":                "127.0.0.1:0",
		"8080":            "127.0.0.1:8080",
		"0.0.0.0:9000":    "0.0.0.0:9000",
		"[::1]:12345":     "[::1]:12345",
		"127.0.0.1:65535": "127.0.0.1:65535",
	}
	for input, expected := range tests {
		actual, err := normalizeListenAddress(input)
		if err != nil {
			t.Fatalf("normalizeListenAddress(%q): %v", input, err)
		}
		if actual != expected {
			t.Fatalf("normalizeListenAddress(%q) = %q, want %q", input, actual, expected)
		}
	}
	for _, invalid := range []string{"localhost", "127.0.0.1:65536", "-1"} {
		if _, err := normalizeListenAddress(invalid); err == nil {
			t.Fatalf("normalizeListenAddress(%q) unexpectedly succeeded", invalid)
		}
	}
}

func TestNormalizeForwardTarget(t *testing.T) {
	for input, expected := range map[string]string{
		"8080":             "127.0.0.1:8080",
		":9000":            "127.0.0.1:9000",
		"10.0.0.8:443":     "10.0.0.8:443",
		"[2001:db8::1]:80": "[2001:db8::1]:80",
	} {
		actual, err := normalizeForwardTarget(input)
		if err != nil {
			t.Fatalf("normalizeForwardTarget(%q): %v", input, err)
		}
		if actual != expected {
			t.Fatalf("normalizeForwardTarget(%q) = %q, want %q", input, actual, expected)
		}
	}
	for _, invalid := range []string{"", "127.0.0.1:0", "bad"} {
		if _, err := normalizeForwardTarget(invalid); err == nil {
			t.Fatalf("normalizeForwardTarget(%q) unexpectedly succeeded", invalid)
		}
	}
}

func TestProductionConfigRequiresBillingKey(t *testing.T) {
	config := appConfig{
		Role: roleClient, IndexAddress: "index.example:9000",
		SecurityProfile: "production", ServerNodeID: strings.Repeat("a", 64),
		RelayCount: 1, DialAttempts: 1, RetryDelay: 1, ReconnectDelay: 1,
	}
	if err := config.normalizeAndValidate(); err == nil || !strings.Contains(err.Error(), "扣费") {
		t.Fatalf("normalizeAndValidate() error = %v, want missing billing key error", err)
	}
}

func TestServerDefaultDispatchTargetMayOmitLogicalPort(t *testing.T) {
	config := appConfig{
		Role: roleServer, SecurityProfile: "development", IndexAddress: "index.example:9000", RelayCount: 1,
		ServerPorts: []AllowedPort{{ID: "default", Protocol: "tcp", Target: "127.0.0.1:8080", Enabled: true}},
		MaxSessions: 1, AcceptQueue: 1, MaxStreams: 1, MaxStreamsPerSession: 1,
	}
	if err := config.normalizeAndValidate(); err != nil {
		t.Fatalf("default dispatch target rejected: %v", err)
	}
	config.ServerPorts = append(config.ServerPorts, AllowedPort{ID: "second-default", Protocol: "tcp", Target: "127.0.0.1:8081", Enabled: true})
	if err := config.normalizeAndValidate(); err == nil || !strings.Contains(err.Error(), "逻辑路由端口") {
		t.Fatalf("multiple default targets error = %v", err)
	}
}

func TestProductionCAURLCannotBeOverridden(t *testing.T) {
	t.Setenv("FKNAT_CA_URL", "https://attacker.invalid")
	if productionCAURL != "https://ca.fknat.top" {
		t.Fatalf("productionCAURL = %q", productionCAURL)
	}
	if _, _, err := parseFlags([]string{"--ca", "https://attacker.invalid"}, io.Discard); err == nil {
		t.Fatal("removed --ca flag unexpectedly accepted")
	}
}

func TestDevelopmentProfileDisablesExternalCA(t *testing.T) {
	if got := caURLForConfig(appConfig{SecurityProfile: "development"}); got != "" {
		t.Fatalf("development CA URL = %q, want empty", got)
	}
	if got := caURLForConfig(appConfig{SecurityProfile: "production"}); got != productionCAURL {
		t.Fatalf("production CA URL = %q, want %q", got, productionCAURL)
	}
}

func TestValidateSecretFileAcceptsReadablePermissions(t *testing.T) {
	directory := t.TempDir()
	filename := filepath.Join(directory, "billing.json")
	if err := os.WriteFile(filename, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := validateSecretFile(filename); err != nil {
		t.Fatalf("validateSecretFile(0600): %v", err)
	}
	if err := os.Chmod(filename, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := validateSecretFile(filename); err != nil {
		t.Fatalf("validateSecretFile(0644): %v", err)
	}
}

func TestCompleteInteractiveClient(t *testing.T) {
	config := appConfig{IndexAddress: "index.example:9000", SecurityProfile: "development"}
	input := strings.NewReader("1\n\n\n\n\n" + strings.Repeat("a", 64) + "\n0\n")
	var output strings.Builder
	if err := completeInteractive(input, &output, &config); err != nil {
		t.Fatalf("completeInteractive: %v", err)
	}
	if config.Role != roleClient || config.ServerNodeID != strings.Repeat("a", 64) {
		t.Fatalf("unexpected interactive config: %#v", config)
	}
	if config.ListenAddress != "0" {
		t.Fatalf("ListenAddress = %q, want 0", config.ListenAddress)
	}
}

func TestConfigFileRoundTripAtomic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	original := appConfig{Role: roleClient, IndexAddress: "index.example:9000", ServerNodeID: strings.Repeat("a", 64), SecurityProfile: "development", ConfigFile: path, WebListenAddress: "0.0.0.0:8088", ClientMappings: []PortMapping{{ID: "web", Protocol: "tcp", Listen: "127.0.0.1:18080", RemotePort: 8080, Enabled: true}}}
	if err := saveConfigFile(path, original); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadConfigFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Role != roleClient || loaded.ClientMappings[0].RemotePort != 8080 || loaded.WebListenAddress != "0.0.0.0:8088" {
		t.Fatalf("loaded config = %+v", loaded)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("config mode = %04o, want 0600", info.Mode().Perm())
	}
}

func TestParseFlagsPrefersPersistedRoleAndMappingsOverEnvironmentDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	persisted := appConfig{
		Role:             roleClient,
		ConfigFile:       path,
		SecurityProfile:  "development",
		IndexAddress:     "index.persisted.example:4101",
		ServerNodeID:     strings.Repeat("b", 64),
		ListenAddress:    "0.0.0.0:29200",
		ClientMappings:   []PortMapping{{ID: "remote-http", Protocol: "tcp", Listen: "0.0.0.0:29200", RemotePort: 1124, Enabled: true}},
		WebListenAddress: "0.0.0.0:8091",
	}
	if err := saveConfigFile(path, persisted); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FKNAT_MODE", "server")
	t.Setenv("FKNAT_FORWARD_TARGET", "127.0.0.1:8080")
	t.Setenv("FKNAT_WEB_LISTEN", "0.0.0.0:8088")
	config, _, err := parseFlags([]string{"--config", path}, io.Discard)
	if err != nil {
		t.Fatalf("parseFlags: %v", err)
	}
	if config.Role != roleClient {
		t.Fatalf("role = %q, want client", config.Role)
	}
	if config.WebListenAddress != "0.0.0.0:8091" {
		t.Fatalf("web listen = %q, want persisted address", config.WebListenAddress)
	}
	if len(config.ClientMappings) != 1 || config.ClientMappings[0].Listen != "0.0.0.0:29200" || config.ClientMappings[0].RemotePort != 1124 {
		t.Fatalf("client mappings = %+v, want persisted mapping", config.ClientMappings)
	}

	config, _, err = parseFlags([]string{"--config", path, "--mode", "server", "--target", "127.0.0.1:9000"}, io.Discard)
	if err != nil {
		t.Fatalf("parseFlags with explicit flags: %v", err)
	}
	if config.Role != roleServer || config.ForwardTarget != "127.0.0.1:9000" {
		t.Fatalf("explicit flags did not override JSON: role=%q target=%q", config.Role, config.ForwardTarget)
	}
}

func TestPrepareWebConfigDefaultsToPublicListenerAndAuthentication(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	config := appConfig{ConfigFile: path, SecurityProfile: "development"}
	password, err := prepareWebConfig(&config)
	if err != nil {
		t.Fatal(err)
	}
	if config.WebListenAddress != "0.0.0.0:8088" {
		t.Fatalf("WebListenAddress = %q, want 0.0.0.0:8088", config.WebListenAddress)
	}
	if config.WebUser != "admin" || password == "" || config.WebPasswordHash == "" {
		t.Fatalf("default Web auth = user %q, password length %d, hash present %t", config.WebUser, len(password), config.WebPasswordHash != "")
	}
	if err := bcrypt.CompareHashAndPassword([]byte(config.WebPasswordHash), []byte(password)); err != nil {
		t.Fatalf("generated password does not match bcrypt hash: %v", err)
	}
	if err := saveConfigFile(path, config); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), password) {
		t.Fatal("generated Web password was persisted in plaintext")
	}
	loaded, err := loadConfigFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.WebUser != "admin" || loaded.WebPasswordHash == "" {
		t.Fatalf("persisted Web auth = user %q, hash present %t", loaded.WebUser, loaded.WebPasswordHash != "")
	}
}
