package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	control "github.com/moby/buildkit/api/services/control"
)

func TestNativeHistoryScrubsSplitSecretAndArgumentsBeforeEncoding(t *testing.T) {
	secrets := new(historySecrets)
	h := newNativeHistory(&control.SolveRequest{
		FrontendAttrs: map[string]string{"build-arg:API_TOKEN": "argument-private"},
		Exporters:     []*control.Exporter{{Attrs: map[string]string{"name": "docker.io/e2e/history:1"}}},
	}, secrets)
	h.append("before mount-")
	h.append("private\nafter argument-private\n")
	// Secret acquisition can race progress delivery. Redact after both finish.
	if err := secrets.remember("mount-private\n"); err != nil {
		t.Fatal(err)
	}
	h.finish(nil)
	data, err := json.Marshal(h.record)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"mount-private", "argument-private"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("persisted secret %q", secret)
		}
	}
	if !strings.Contains(h.record.Log, "before [redacted]") || h.record.Status != "success" {
		t.Fatal(h.record)
	}
	if len(h.record.Tags) != 1 || h.record.Tags[0] != "e2e/history:1" {
		t.Fatal(h.record.Tags)
	}
}

func TestNativeHistoryCountsContinueBeyondLogCap(t *testing.T) {
	h := newNativeHistory(&control.SolveRequest{}, new(historySecrets))
	h.observe(&control.StatusResponse{Vertexes: []*control.Vertex{{Digest: "first", Name: "load build context"}}})
	h.append(strings.Repeat("x", historyLogLimit+1))
	h.observe(&control.StatusResponse{
		Vertexes: []*control.Vertex{{Digest: "first", Name: "load build context", Cached: true}, {Digest: "second", Name: "RUN true"}},
		Statuses: []*control.VertexStatus{{Vertex: "first", ID: "transfer", Current: 512}},
	})
	h.observe(&control.StatusResponse{Statuses: []*control.VertexStatus{{Vertex: "first", ID: "transfer", Current: 1024}}})
	h.finish(nil)
	if len(h.record.Log) > historyLogLimit || h.record.TotalSteps != 2 || h.record.CachedSteps != 1 || h.record.ContextSize != 1024 {
		t.Fatalf("bytes=%d total=%d cached=%d context=%d", len(h.record.Log), h.record.TotalSteps, h.record.CachedSteps, h.record.ContextSize)
	}
}

func TestNativeHistoryCancellationAndSecretBudget(t *testing.T) {
	secrets := new(historySecrets)
	if err := secrets.remember(strings.Repeat("x", (1<<20)+1)); err == nil {
		t.Fatal("unbounded secret accepted")
	}
	if err := secrets.remember("private-error"); err != nil {
		t.Fatal(err)
	}
	h := newNativeHistory(&control.SolveRequest{}, secrets)
	h.append("private-error")
	h.finish(context.Canceled)
	if h.record.Status != "cancelled" || strings.Contains(h.record.Log, "private-error") || h.record.EndedAt == nil {
		t.Fatal(h.record)
	}
}

func TestNativeHistoryParallelLogsDoNotSplitRedaction(t *testing.T) {
	secrets := new(historySecrets)
	if err := secrets.remember("mount-private"); err != nil {
		t.Fatal(err)
	}
	if err := secrets.remember("line-one\nline-two\n"); err != nil {
		t.Fatal(err)
	}
	h := newNativeHistory(&control.SolveRequest{}, secrets)
	h.observe(&control.StatusResponse{Logs: []*control.VertexLog{{Vertex: "first", Msg: []byte("mount-pri")}}})
	h.observe(&control.StatusResponse{Logs: []*control.VertexLog{{Vertex: "second", Msg: []byte("other step\n")}}})
	h.observe(&control.StatusResponse{Logs: []*control.VertexLog{{Vertex: "first", Msg: []byte("vate\nline-one\nprefix: line-two\n")}}})
	h.finish(nil)
	for _, fragment := range []string{"mount-pri", "vate", "line-one", "line-two"} {
		if strings.Contains(h.record.Log, fragment) {
			t.Fatalf("leaked secret fragment %q: %s", fragment, h.record.Log)
		}
	}
	if !strings.Contains(h.record.Log, "other step") {
		t.Fatal("parallel output was lost")
	}
}
