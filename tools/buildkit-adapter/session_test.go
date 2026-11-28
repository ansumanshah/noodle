package main

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"

	control "github.com/moby/buildkit/api/services/control"
	"github.com/moby/buildkit/session"
	"github.com/moby/buildkit/session/grpchijack"
	"github.com/moby/buildkit/session/secrets"
	"github.com/moby/buildkit/session/secrets/secretsprovider"
	"google.golang.org/grpc"
	"google.golang.org/grpc/test/bufconn"
)

type sessionWorker struct {
	control.UnimplementedControlServer
	manager *session.Manager
}

func (w *sessionWorker) Session(s control.Control_SessionServer) error {
	conn, done, meta := grpchijack.Hijack(s)
	defer conn.Close()
	ctx, cancel := context.WithCancel(s.Context())
	defer cancel()
	go func() {
		select {
		case <-done:
			cancel()
		case <-ctx.Done():
		}
	}()
	return w.manager.HandleConn(ctx, conn, meta)
}

// Two real reverse BuildKit sessions can carry the same secret name. A third
// connection reusing the first UUID must neither replace nor unregister it.
func TestDuplicateSessionCannotRedirectSecrets(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	manager, err := session.NewManager()
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	control.RegisterControlServer(server, &sessionWorker{manager: manager})
	listener := bufconn.Listen(1 << 20)
	go server.Serve(listener)
	defer server.Stop()
	socket, err := listener.Dial()
	if err != nil {
		t.Fatal(err)
	}
	cc, err := client(socket)
	if err != nil {
		t.Fatal(err)
	}
	defer cc.Close()
	a := adapter{api: control.NewControlClient(cc)}
	connect := func(id, value string) <-chan error {
		s, err := session.NewSession(ctx, "")
		if err != nil {
			t.Fatal(err)
		}
		s.Allow(secretsprovider.FromMap(map[string][]byte{"same-key": []byte(value)}))
		done := make(chan error, 1)
		go s.Run(ctx, func(ctx context.Context, _ string, meta map[string][]string) (net.Conn, error) {
			headers := map[string][]string{}
			for k, v := range meta {
				headers[strings.ToLower(k)] = v
			}
			headers["x-docker-expose-session-uuid"] = []string{id}
			incoming, outgoing := net.Pipe()
			go func() { defer outgoing.Close(); done <- a.session(ctx, outgoing, headers) }()
			return incoming, nil
		})
		return done
	}
	secret := func(id, want string) {
		caller, err := manager.Get(ctx, id, false)
		if err != nil {
			t.Fatal(err)
		}
		res, err := secrets.NewSecretsClient(caller.Conn()).GetSecret(ctx, &secrets.GetSecretRequest{ID: "same-key"})
		if err != nil {
			t.Fatal(err)
		}
		if string(res.Data) != want {
			t.Fatal("session returned another client's secret")
		}
	}
	connect("first", "alpha")
	connect("second", "bravo")
	secret("first", "alpha")
	secret("second", "bravo")
	select {
	case err := <-connect("first", "intruder"):
		if err == nil {
			t.Fatal("duplicate UUID accepted")
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	secret("first", "alpha")
	secret("second", "bravo")
}
