// A transient Docker-driver adapter. stdin is a connected, host-owned worker
// socket. Only the private Unix socket created by noodled accepts clients.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	control "github.com/moby/buildkit/api/services/control"
	"github.com/moby/buildkit/session/filesync"
	"github.com/moby/buildkit/session/grpchijack"
	"github.com/moby/buildkit/session/secrets"
	"github.com/siderolabs/grpc-proxy/proxy"
	"golang.org/x/net/http2"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/stats"
	"google.golang.org/grpc/status"
)

const sendFile = "/moby.filesync.v1.FileSend/DiffCopy"

type codec struct{ encoding.CodecV2 }

func (codec) Name() string { return "proto" }

var wire = codec{proxy.Codec()}

type connection struct {
	net.Conn
	r *bufio.Reader
}

func (c connection) Read(p []byte) (int, error) { return c.r.Read(p) }

type budget struct {
	count  atomic.Int64
	cancel context.CancelFunc
}

func (*budget) TagRPC(ctx context.Context, _ *stats.RPCTagInfo) context.Context { return ctx }
func (b *budget) HandleRPC(_ context.Context, s stats.RPCStats) {
	if p, ok := s.(*stats.InPayload); ok && b.count.Add(int64(p.Length)) > 1<<30 {
		b.cancel()
	}
}
func (*budget) TagConn(ctx context.Context, _ *stats.ConnTagInfo) context.Context { return ctx }
func (*budget) HandleConn(context.Context, stats.ConnStats)                       {}

func client(c net.Conn, opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	var once atomic.Bool
	opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithDefaultCallOptions(grpc.ForceCodecV2(wire)), grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
		if !once.CompareAndSwap(false, true) {
			return nil, net.ErrClosed
		}
		return c, nil
	}))
	return grpc.NewClient("passthrough:///noodle", opts...)
}
func outgoing(ctx context.Context) context.Context {
	md, _ := metadata.FromIncomingContext(ctx)
	return metadata.NewOutgoingContext(ctx, md.Copy())
}
func forward(c *grpc.ClientConn) grpc.StreamHandler {
	backend := &proxy.SingleBackend{GetConn: func(ctx context.Context) (context.Context, *grpc.ClientConn, error) { return outgoing(ctx), c, nil }}
	return proxy.TransparentHandler(func(context.Context, string) (proxy.Mode, []proxy.Backend, error) {
		return proxy.One2One, []proxy.Backend{backend}, nil
	})
}

type target struct {
	path    string
	started atomic.Bool
	ready   atomic.Bool
}
type key struct {
	session string
	index   int
}
type adapter struct {
	upstream *grpc.ClientConn
	api      control.ControlClient
	docker   *http.Client
	tmp      string
	targets  sync.Map
	token    string
	sessions sync.Map
}

func serve(ctx context.Context, c net.Conn, h grpc.StreamHandler) {
	s := grpc.NewServer(grpc.ForceServerCodecV2(wire), grpc.UnknownServiceHandler(h))
	defer s.Stop()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	var h2 http2.Server
	h2.ServeConn(c, &http2.ServeConnOpts{Handler: s, Context: ctx})
}
func (a *adapter) solve(s grpc.ServerStream) (result error) {
	var req control.SolveRequest
	if err := s.RecvMsg(&req); err != nil {
		return err
	}
	var session *sessionState
	if req.Session != "" {
		if state, ok := a.awaitSession(s.Context(), req.Session); ok {
			session = state.(*sessionState)
		}
	}
	redactions := new(historySecrets)
	if session != nil {
		redactions = &session.secrets
	}
	finish, err := a.beginHistory(s.Context(), &req, redactions)
	if err != nil {
		return err
	}
	defer func() {
		if finish != nil {
			result = finish(result)
		}
	}()
	if len(req.Exporters) == 0 && req.ExporterDeprecated != "" {
		req.Exporters = []*control.Exporter{{Type: req.ExporterDeprecated, Attrs: req.ExporterAttrsDeprecated}}
		req.ExporterDeprecated = ""
		req.ExporterAttrsDeprecated = nil
	}
	var output *target
	var tags []string
	for i, e := range req.Exporters {
		if e.Type != "moby" {
			continue
		}
		push, err := strconv.ParseBool(e.Attrs["push"])
		if e.Attrs["push"] != "" && err != nil {
			return status.Error(codes.InvalidArgument, "invalid image push option")
		}
		if output != nil || push {
			return status.Error(codes.Unimplemented, "multiple image loads and push through the native image exporter are unsupported")
		}
		f, err := os.CreateTemp(a.tmp, "image-*.tar")
		if err != nil {
			return err
		}
		defer os.Remove(f.Name())
		if err := f.Close(); err != nil {
			return err
		}
		output = &target{path: f.Name()}
		if name := e.Attrs["name"]; name != "" {
			tags = strings.Split(name, ",")
		}
		k := key{req.Session, i}
		if _, busy := a.targets.LoadOrStore(k, output); busy {
			return status.Error(codes.ResourceExhausted, "image exporter is already active in this session")
		}
		defer a.targets.Delete(k)
		e.Type = "docker"
		delete(e.Attrs, "prefer-image-digest")
	}
	// The Mac resolves base images for this solve unless the client brought its own source policy session.
	if session != nil && req.SourcePolicySession == "" {
		st := session
		st.pull.Store(req.FrontendAttrs["image-resolve-mode"] == "pull")
		st.active.Store(true)
		req.SourcePolicySession = req.Session
	}
	resp, err := a.api.Solve(outgoing(s.Context()), &req)
	if err != nil {
		return err
	}
	if output != nil {
		if !output.ready.Load() {
			return status.Error(codes.FailedPrecondition, "worker returned without an image archive")
		}
		digest := resp.ExporterResponse["containerimage.config.digest"]
		payload, err := json.Marshal(struct {
			File, Digest string
			Tags         []string
		}{filepath.Base(output.path), digest, tags})
		if err != nil {
			return err
		}
		request, err := http.NewRequestWithContext(s.Context(), "POST", "http://noodle/noodle/buildkit/import", bytes.NewReader(payload))
		if err != nil {
			return err
		}
		request.Header.Set("X-Noodle-Build-Token", a.token)
		response, err := a.docker.Do(request)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return status.Errorf(codes.Internal, "Noodle image import returned HTTP %d", response.StatusCode)
		}
		var loaded struct{ ID string }
		if err = json.NewDecoder(io.LimitReader(response.Body, 1024)).Decode(&loaded); err != nil || digest == "" || loaded.ID != digest {
			return status.Error(codes.FailedPrecondition, "loaded image digest mismatch")
		}
	}
	result = finish(nil)
	finish = nil
	if result != nil {
		return result
	}
	return s.SendMsg(resp)
}
func (a *adapter) control(_ any, s grpc.ServerStream) error {
	method, _ := grpc.MethodFromServerStream(s)
	switch method {
	case control.Control_Session_FullMethodName:
		return status.Error(codes.Unimplemented, "Docker sessions use the session upgrade")
	case control.Control_Solve_FullMethodName:
		return a.solve(s)
	case control.Control_ListWorkers_FullMethodName:
		var req control.ListWorkersRequest
		if err := s.RecvMsg(&req); err != nil {
			return err
		}
		res, err := a.api.ListWorkers(outgoing(s.Context()), &req)
		if err != nil {
			return err
		}
		for _, w := range res.Record {
			delete(w.Labels, "org.mobyproject.buildkit.worker.snapshotter")
		}
		return s.SendMsg(res)
	}
	return forward(a.upstream)(nil, s)
}
func (t *target) receive(s grpc.ServerStream) error {
	if !t.started.CompareAndSwap(false, true) {
		return status.Error(codes.AlreadyExists, "duplicate image archive")
	}
	f, err := os.OpenFile(t.path, os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	var total int64
	for {
		var chunk filesync.BytesMessage
		err = s.RecvMsg(&chunk)
		if errors.Is(err, io.EOF) {
			if err := f.Close(); err != nil {
				return err
			}
			t.ready.Store(true)
			return nil
		}
		if err != nil {
			return err
		}
		total += int64(len(chunk.Data))
		if total > 4<<30 {
			return status.Error(codes.ResourceExhausted, "image archive exceeds 4 GiB")
		}
		if _, err = f.Write(chunk.Data); err != nil {
			return err
		}
	}
}

// awaitSession finds the session of a solve. The client opens the session and sends the solve concurrently, so the
// solve can arrive a moment before the session is claimed. The wait happens only inside a solve.
func (a *adapter) awaitSession(ctx context.Context, id string) (any, bool) {
	for range 250 {
		if state, ok := a.sessions.Load(id); ok {
			return state, true
		}
		select {
		case <-ctx.Done():
			return nil, false
		case <-time.After(20 * time.Millisecond):
		}
	}
	return nil, false
}

func (a *adapter) claimSession(id string) (*sessionState, func(), error) {
	if len(id) == 0 || len(id) > 128 || strings.IndexFunc(id, func(c rune) bool {
		return !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_')
	}) != -1 {
		return nil, nil, errors.New("invalid session ID")
	}
	owner := new(sessionState)
	if _, exists := a.sessions.LoadOrStore(id, owner); exists {
		return nil, nil, errors.New("session already in use")
	}
	return owner, func() { a.sessions.CompareAndDelete(id, owner) }, nil
}

func (a *adapter) session(ctx context.Context, c net.Conn, headers map[string][]string) error {
	id := headers["x-docker-expose-session-uuid"]
	if len(id) != 1 || id[0] == "" {
		return errors.New("missing session ID")
	}
	state, release, err := a.claimSession(id[0])
	if err != nil {
		return err
	}
	defer release()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	b := &budget{cancel: cancel}
	cli, err := client(&cancelOnReadError{c, cancel}, grpc.WithStatsHandler(b))
	if err != nil {
		return err
	}
	defer cli.Close()
	cli.Connect()
	headers["x-docker-expose-session-grpc-method"] = append(headers["x-docker-expose-session-grpc-method"], sendFile, policyMethod, contentInfo, contentRead)
	up, err := grpchijack.Dialer(a.api)(ctx, "h2c", headers)
	if err != nil {
		return err
	}
	defer up.Close()
	pass := forward(cli)
	serve(ctx, up, func(v any, s grpc.ServerStream) error {
		method, _ := grpc.MethodFromServerStream(s)
		switch {
		case method == secrets.Secrets_GetSecret_FullMethodName:
			var request secrets.GetSecretRequest
			if err := s.RecvMsg(&request); err != nil {
				return err
			}
			response, err := secrets.NewSecretsClient(cli).GetSecret(outgoing(s.Context()), &request)
			if err != nil {
				return err
			}
			if err := state.secrets.remember(string(response.Data)); err != nil {
				return err
			}
			return s.SendMsg(response)
		case method == policyMethod && state.active.Load():
			return a.checkPolicy(state, id[0], s)
		case method == contentInfo && ownsStore(s.Context()):
			return a.info(s)
		case method == contentRead && ownsStore(s.Context()):
			return a.read(s)
		}
		if method == sendFile {
			idx := 0
			values := metadata.ValueFromIncomingContext(s.Context(), "buildkit-attachable-exporter-id")
			if len(values) > 0 {
				var err error
				idx, err = strconv.Atoi(values[0])
				if err != nil {
					return err
				}
			}
			if output, ok := a.targets.Load(key{id[0], idx}); ok {
				return output.(*target).receive(s)
			}
		}
		return pass(v, s)
	})
	return nil
}

func (a *adapter) handle(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReaderSize(conn, 64<<10)
	line, err := r.ReadSlice('\n')
	if err != nil {
		return
	}
	var h struct {
		Mode    string
		Headers map[string][]string
	}
	if json.Unmarshal(line, &h) != nil {
		return
	}
	// Never record metadata or context content in the adapter log.
	c := connection{conn, r}
	ctx := context.Background()
	switch h.Mode {
	case "grpc":
		serve(ctx, c, a.control)
	case "session":
		_ = a.session(ctx, c, h.Headers)
	}
}

// A native client can disappear during a reverse filesync/SSH/auth RPC.
type cancelOnReadError struct {
	net.Conn
	cancel context.CancelFunc
}

func (c *cancelOnReadError) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if err != nil {
		c.cancel()
	}
	return n, err
}

// The VM and adapter belong to noodled even if the daemon is killed without cleanup.
func monitorParent(pid int, listener net.Listener) {
	kq, err := unix.Kqueue()
	if err != nil {
		listener.Close()
		return
	}
	defer unix.Close(kq)
	change := []unix.Kevent_t{{Ident: uint64(pid), Filter: unix.EVFILT_PROC, Flags: unix.EV_ADD | unix.EV_ONESHOT, Fflags: unix.NOTE_EXIT}}
	if _, err = unix.Kevent(kq, change, nil, nil); err != nil || os.Getppid() != pid {
		listener.Close()
		return
	}
	var ev [1]unix.Kevent_t
	for {
		_, err = unix.Kevent(kq, nil, ev[:], nil)
		if err != unix.EINTR {
			break
		}
	}
	listener.Close()
}

func main() {
	if len(os.Args) != 5 {
		os.Exit(2)
	}
	sock, tmp, dockerSock := os.Args[1], os.Args[2], os.Args[3]
	c, err := net.FileConn(os.Stdin)
	if err != nil {
		panic(err)
	}
	defer c.Close()
	api, err := client(c)
	if err != nil {
		panic(err)
	}
	defer api.Close()
	ln, err := net.Listen("unix", sock)
	if err != nil {
		panic(err)
	}
	defer ln.Close()
	parent, err := strconv.Atoi(os.Args[4])
	if err != nil || parent < 2 {
		os.Exit(2)
	}
	go monitorParent(parent, ln)
	if dir, err := os.Lstat(tmp); err == nil && dir.IsDir() && dir.Mode().Perm() == 0700 && filepath.Dir(sock) == tmp && filepath.Dir(tmp) == "/tmp" && filepath.Base(sock) == "adapter.sock" {
		defer os.RemoveAll(tmp)
	}
	if err = os.Chmod(sock, 0600); err != nil {
		panic(err)
	}
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", dockerSock)
	}, ResponseHeaderTimeout: 10 * time.Minute}
	tokenFile := filepath.Join(tmp, "import-token")
	token, err := os.ReadFile(tokenFile)
	if err != nil || len(token) != 36 {
		os.Exit(2)
	}
	if err = os.Remove(tokenFile); err != nil {
		os.Exit(2)
	}
	a := adapter{token: string(token), upstream: api, api: control.NewControlClient(api), docker: &http.Client{Transport: tr}, tmp: tmp}
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go a.handle(conn)
	}
}
