package main

// History belongs to a Solve, never to an idle adapter. Only scrubbed snapshots
// cross the private daemon API; secret/session payloads are never written to disk.
import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	control "github.com/moby/buildkit/api/services/control"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const historyLogLimit = 2 << 20

// A session's secret replies are observed before the worker can print them.
// This is shared by concurrent solves of that session and destroyed with it.
type historySecrets struct {
	mu     sync.Mutex
	values map[string]struct{}
	bytes  int
}

func (s *historySecrets) remember(value string) error {
	if value == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.values[value]; ok {
		return nil
	}
	if s.bytes+len(value) > 1<<20 {
		return status.Error(codes.ResourceExhausted, "build secret redaction budget exceeded")
	}
	if s.values == nil {
		s.values = map[string]struct{}{}
	}
	s.values[value] = struct{}{}
	s.bytes += len(value)
	return nil
}

func (s *historySecrets) snapshot() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	values := make([]string, 0, len(s.values))
	for value := range s.values {
		values = append(values, value)
	}
	sort.Slice(values, func(i, j int) bool { return len(values[i]) > len(values[j]) })
	return values
}

type nativeHistoryRecord struct {
	ID          string     `json:"id"`
	Tags        []string   `json:"tags"`
	StartedAt   time.Time  `json:"startedAt"`
	EndedAt     *time.Time `json:"endedAt,omitempty"`
	Status      string     `json:"status"`
	Error       string     `json:"error,omitempty"`
	Duration    float64    `json:"duration"`
	CachedSteps int        `json:"cachedSteps"`
	TotalSteps  int        `json:"totalSteps"`
	ContextSize int64      `json:"contextSize"`
	Log         string     `json:"log"`
}

type nativeHistory struct {
	record    nativeHistoryRecord
	secrets   *historySecrets
	args      []string
	steps     map[string]bool
	names     map[string]string
	transfers map[string]int64
	logs      map[string][]byte
	order     []string
	logBytes  int
	truncated map[string]bool
}

func newNativeHistory(req *control.SolveRequest, secrets *historySecrets) *nativeHistory {
	var id [16]byte
	_, _ = rand.Read(id[:]) // crypto/rand.Read cannot fail on the supported Go toolchain.
	h := &nativeHistory{
		record:  nativeHistoryRecord{ID: hex.EncodeToString(id[:]), Tags: []string{}, StartedAt: time.Now(), Status: "running"},
		secrets: secrets, steps: map[string]bool{}, names: map[string]string{}, transfers: map[string]int64{},
		logs: map[string][]byte{}, truncated: map[string]bool{},
	}
	for key, value := range req.FrontendAttrs {
		if strings.HasPrefix(key, "build-arg:") && value != "" {
			h.args = append(h.args, value)
		}
	}
	sort.Slice(h.args, func(i, j int) bool { return len(h.args[i]) > len(h.args[j]) })
	names := []string{req.ExporterAttrsDeprecated["name"]}
	for _, exporter := range req.Exporters {
		names = append(names, exporter.Attrs["name"])
	}
	for _, name := range names {
		if name != "" {
			for _, tag := range strings.Split(name, ",") {
				tag = strings.TrimPrefix(tag, "docker.io/")
				tag = strings.TrimPrefix(tag, "library/")
				h.record.Tags = append(h.record.Tags, tag)
			}
		}
	}
	// Tags can themselves contain a secret-looking argument value. Mask it
	// before even the initial snapshot; unrelated argument values keep tags intact.
	for key, value := range req.FrontendAttrs {
		if !strings.HasPrefix(key, "build-arg:") || value == "" {
			continue
		}
		key = strings.ToLower(key)
		for _, word := range []string{"token", "secret", "password", "passwd", "passphrase", "key", "credential", "auth", "cookie", "session"} {
			if strings.Contains(key, word) {
				for i, tag := range h.record.Tags {
					h.record.Tags[i] = strings.ReplaceAll(tag, value, "[redacted]")
				}
				break
			}
		}
	}
	return h
}

func (h *nativeHistory) append(text string) { h.appendVertex("", text) }

func (h *nativeHistory) appendVertex(vertex, text string) {
	remaining := historyLogLimit - h.logBytes
	if len(text) > remaining {
		text = text[:remaining]
		h.truncated[vertex] = true
	}
	if text == "" {
		return
	}
	if _, exists := h.logs[vertex]; !exists {
		h.order = append(h.order, vertex)
	}
	h.logs[vertex] = append(h.logs[vertex], text...)
	h.logBytes += len(text)
}

func (h *nativeHistory) observe(message *control.StatusResponse) {
	for _, vertex := range message.Vertexes {
		if _, seen := h.steps[vertex.Digest]; !seen {
			h.appendVertex(vertex.Digest, vertex.Name+"\n")
		}
		h.steps[vertex.Digest] = h.steps[vertex.Digest] || vertex.Cached
		h.names[vertex.Digest] = vertex.Name
	}
	for _, entry := range message.Logs {
		h.appendVertex(entry.Vertex, string(entry.Msg))
	}
	for _, transfer := range message.Statuses {
		if strings.Contains(h.names[transfer.Vertex], "load build context") && transfer.Current > h.transfers[transfer.Vertex+"/"+transfer.ID] {
			h.transfers[transfer.Vertex+"/"+transfer.ID] = transfer.Current
		}
	}
}

func (h *nativeHistory) scrub(value string) string {
	values := append(h.secrets.snapshot(), h.args...)
	sort.Slice(values, func(i, j int) bool { return len(values[i]) > len(values[j]) })
	for _, secret := range values {
		value = strings.ReplaceAll(value, secret, "[redacted]")
		// Progress renderers and shell tools may split multi-line secrets.
		// Scrub each nonempty line as well as the complete reply.
		for _, line := range strings.Split(secret, "\n") {
			if line = strings.TrimRight(line, "\r"); line != "" {
				value = strings.ReplaceAll(value, line, "[redacted]")
			}
		}
	}
	return strings.ToValidUTF8(value, "\uFFFD")
}

func (h *nativeHistory) finish(err error) {
	end := time.Now()
	h.record.EndedAt = &end
	h.record.Duration = end.Sub(h.record.StartedAt).Seconds()
	h.record.Status = "success"
	if err != nil {
		h.record.Status = "failed"
		if errors.Is(err, context.Canceled) || status.Code(err) == codes.Canceled {
			h.record.Status = "cancelled"
		}
		h.record.Error = h.scrub(err.Error())
		if len(h.record.Error) > 4096 {
			h.record.Error = h.record.Error[:4096]
			for !utf8.ValidString(h.record.Error) {
				h.record.Error = h.record.Error[:len(h.record.Error)-1]
			}
		}
	}
	h.record.TotalSteps = len(h.steps)
	for _, cached := range h.steps {
		if cached {
			h.record.CachedSteps++
		}
	}
	for _, size := range h.transfers {
		h.record.ContextSize += size
	}
	longest := 0
	for _, value := range append(h.secrets.snapshot(), h.args...) {
		if len(value) > longest {
			longest = len(value)
		}
	}
	var log strings.Builder
	for _, vertex := range h.order {
		text := h.logs[vertex]
		if h.truncated[vertex] {
			text = text[:max(0, len(text)-longest)]
		}
		// Redact a vertex's complete byte stream before adding other vertices.
		// Parallel progress must not insert text between halves of a secret.
		log.WriteString(h.scrub(string(text)))
	}
	h.record.Log = log.String()
	if len(h.record.Log) > historyLogLimit {
		h.record.Log = h.record.Log[:historyLogLimit]
		for !utf8.ValidString(h.record.Log) {
			h.record.Log = h.record.Log[:len(h.record.Log)-1]
		}
	}
	for i, tag := range h.record.Tags {
		// Session secrets are now known. Keep normal tags intact.
		for _, secret := range h.secrets.snapshot() {
			tag = strings.ReplaceAll(tag, secret, "[redacted]")
			for _, line := range strings.Split(secret, "\n") {
				if line = strings.TrimRight(line, "\r"); line != "" {
					tag = strings.ReplaceAll(tag, line, "[redacted]")
				}
			}
		}
		h.record.Tags[i] = tag
	}
}

func (a *adapter) reportHistory(ctx context.Context, h *nativeHistory) error {
	data, err := json.Marshal(h.record)
	if err != nil {
		return err
	}
	response, err := a.noodle(ctx, "POST", "noodle/buildkit/history", data)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return failure(response)
	}
	_, err = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	return err
}

// The observer runs only during Solve. Finishing joins it before redaction so
// progress cannot race with the final snapshot. Client cancellation does not
// cancel the final local API write.
func (a *adapter) beginHistory(ctx context.Context, req *control.SolveRequest, secrets *historySecrets) (func(error) error, error) {
	h := newNativeHistory(req, secrets)
	if err := a.reportHistory(ctx, h); err != nil {
		return nil, err
	}
	progressCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	done := make(chan error, 1)
	go func() {
		stream, err := a.api.Status(outgoing(progressCtx), &control.StatusRequest{Ref: req.Ref})
		if err != nil {
			done <- err
			return
		}
		for {
			message, err := stream.Recv()
			if errors.Is(err, io.EOF) {
				done <- nil
				return
			}
			if err != nil {
				done <- err
				return
			}
			h.observe(message)
		}
	}()
	return func(solveErr error) error {
		defer cancel()
		var progressErr error
		select {
		case progressErr = <-done:
		case <-time.After(2 * time.Second):
			cancel()
			progressErr = <-done
		}
		if solveErr == nil && progressErr != nil {
			solveErr = fmt.Errorf("build progress unavailable: %w", progressErr)
		}
		if solveErr != nil && ctx.Err() != nil {
			solveErr = ctx.Err()
		}
		h.finish(solveErr)
		writeCtx, finish := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer finish()
		if err := a.reportHistory(writeCtx, h); err != nil {
			return fmt.Errorf("persist build history: %w", err)
		}
		return solveErr
	}, nil
}
