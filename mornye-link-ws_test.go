package main

import (
	"encoding/json"
	"testing"
)

func TestParseCommandFloat(t *testing.T) {
	var raw json.RawMessage = []byte(`{"positionMs":12345}`)
	got, ok := parseCommandFloat(raw, "positionMs", "value")
	if !ok || got != 12345 {
		t.Fatalf("got %v, %t; want 12345, true", got, ok)
	}
}

func TestParseCommandBool(t *testing.T) {
	var raw json.RawMessage = []byte(`{"shuffle":true}`)
	got, ok := parseCommandBool(raw, "shuffle", "enabled")
	if !ok || !got {
		t.Fatalf("got %v, %t; want true, true", got, ok)
	}
}

func TestParseCommandString(t *testing.T) {
	var raw json.RawMessage = []byte(`{"mode":"all"}`)
	got, ok := parseCommandString(raw, "repeat", "mode")
	if !ok || got != "all" {
		t.Fatalf("got %q, %t; want all, true", got, ok)
	}
}

func TestClampVolume(t *testing.T) {
	if got := clampVolume(-0.1); got != 0 {
		t.Fatalf("clampVolume(-0.1) = %v, want 0", got)
	}
	if got := clampVolume(1.1); got != 1 {
		t.Fatalf("clampVolume(1.1) = %v, want 1", got)
	}
}

func TestWebsocketAcceptRFC6455Example(t *testing.T) {
	const key = "dGhlIHNhbXBsZSBub25jZQ=="
	const want = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
	if got := websocketAccept(key); got != want {
		t.Fatalf("websocketAccept(%q) = %q, want %q", key, got, want)
	}
}
