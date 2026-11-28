package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	gatewaypb "github.com/moby/buildkit/frontend/gateway/pb"
	opspb "github.com/moby/buildkit/solver/pb"
	policypb "github.com/moby/buildkit/sourcepolicy/pb"
	"github.com/moby/buildkit/sourcepolicy/policysession"
	"google.golang.org/grpc"
)

type policyStream struct {
	grpc.ServerStream
	identifier string
	response   *policysession.CheckPolicyResponse
}

func (s *policyStream) Context() context.Context { return context.Background() }

func (s *policyStream) RecvMsg(m any) error {
	m.(*policysession.CheckPolicyRequest).Source = &gatewaypb.ResolveSourceMetaResponse{Source: &opspb.SourceOp{Identifier: s.identifier}}
	return nil
}

func (s *policyStream) SendMsg(m any) error {
	s.response = m.(*policysession.CheckPolicyResponse)
	return nil
}

type baseResolver struct {
	digests map[string]string
	asked   []string
}

func (r *baseResolver) RoundTrip(req *http.Request) (*http.Response, error) {
	var in struct{ Ref string }
	if err := json.NewDecoder(req.Body).Decode(&in); err != nil {
		return nil, err
	}
	r.asked = append(r.asked, in.Ref)
	out, err := json.Marshal(struct{ Digest string }{r.digests[in.Ref]})
	if err != nil {
		return nil, err
	}
	return &http.Response{StatusCode: http.StatusOK, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(string(out)))}, nil
}

func decide(t *testing.T, a *adapter, st *sessionState, identifier string) *policysession.DecisionResponse {
	t.Helper()
	stream := &policyStream{identifier: identifier}
	if err := a.checkPolicy(st, "session-id", stream); err != nil {
		t.Fatal(err)
	}
	return stream.response.GetDecision()
}

// The frontend resolves FROM, then pins it to what the conversion returned, as a docker-image source. That second
// source must stay in the session's OCI store, or BuildKit fetches its layers from a registry that does not exist.
func TestConvertedBaseStaysLocalWhenFrontendPinsIt(t *testing.T) {
	const digest = "sha256:fea5b91588ca539ff8a89d7d5df6c6d65d6ab7bd89145ba57f32c302cf02ffbe"
	resolver := &baseResolver{digests: map[string]string{"docker.io/library/alpine:3.22": digest}}
	a := &adapter{docker: &http.Client{Transport: resolver}}
	st := &sessionState{}

	first := decide(t, a, st, "docker-image://docker.io/library/alpine:3.22")
	if first.Action != policypb.PolicyAction_CONVERT || first.Update.Identifier != "oci-layout://noodle.local/base@"+digest {
		t.Fatalf("first decision: %v", first)
	}
	second := decide(t, a, st, "docker-image://noodle.local/base@"+digest)
	if second.Action != policypb.PolicyAction_CONVERT || second.Update.Identifier != first.Update.Identifier {
		t.Fatalf("pinned decision: %v", second)
	}
	if got := second.Update.Attrs[opspb.AttrOCILayoutSessionID]; got != "session-id" {
		t.Fatalf("session attribute: %q", got)
	}
	if got := second.Update.Attrs[opspb.AttrOCILayoutStoreID]; got != baseStore {
		t.Fatalf("store attribute: %q", got)
	}
	if len(resolver.asked) != 1 {
		t.Fatalf("the Mac was asked %v", resolver.asked)
	}
}

// Naming the private repository buys nothing: a digest this session did not resolve is an ordinary reference.
func TestUnresolvedBaseRepositoryIsAnOrdinaryReference(t *testing.T) {
	const digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
	resolver := &baseResolver{}
	a := &adapter{docker: &http.Client{Transport: resolver}}

	decision := decide(t, a, &sessionState{}, "docker-image://noodle.local/base@"+digest)
	if decision.Action != policypb.PolicyAction_ALLOW {
		t.Fatalf("decision: %v", decision)
	}
	if len(resolver.asked) != 1 || resolver.asked[0] != "noodle.local/base@"+digest {
		t.Fatalf("the Mac was asked %v", resolver.asked)
	}
}
