package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
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

func TestValidateSecretFilePermissions(t *testing.T) {
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
	if _, err := validateSecretFile(filename); err == nil {
		t.Fatal("validateSecretFile(0644) unexpectedly succeeded")
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
