package main

// Base images are resolved by noodled on the Mac, never by the guest. For every image source BuildKit asks the
// session's source policy, and the adapter answers it: when the Mac can supply the image (a local-only tag, a
// local tag that shadows a registry name, a loopback or credentialed registry) the source is converted to an
// OCI layout whose content the adapter serves from the Mac. Registry credentials stay in noodled.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	contentapi "github.com/containerd/containerd/api/services/content/v1"
	opspb "github.com/moby/buildkit/solver/pb"
	policypb "github.com/moby/buildkit/sourcepolicy/pb"
	"github.com/moby/buildkit/sourcepolicy/policysession"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const (
	baseStore       = "noodle"
	baseRepository  = "noodle.local/base"
	storeHeader     = "buildkit-attachable-store-id" // session/content.GRPCHeaderID
	policyMethod    = "/moby.buildkit.v1.sourcepolicy.policysession.PolicyVerifier/CheckPolicy"
	contentInfo     = "/containerd.services.content.v1.Content/Info"
	contentRead     = "/containerd.services.content.v1.Content/Read"
	blobChunk       = 2 << 20
	baseRequestMax  = 64 << 10
	errorMessageMax = 8 << 10
)

// sessionState is one build session. The solve fills in the options, the policy callback reads them.
type sessionState struct {
	secrets historySecrets
	pull    atomic.Bool
	active  atomic.Bool
	mu      sync.Mutex
	bases   map[string]string
}

func (st *sessionState) lookup(ref string) (string, bool) {
	st.mu.Lock()
	defer st.mu.Unlock()
	digest, ok := st.bases[ref]
	return digest, ok
}

func (st *sessionState) remember(ref, digest string) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.bases == nil {
		st.bases = map[string]string{}
	}
	st.bases[ref] = digest
	if digest != "" {
		// The Dockerfile frontend pins FROM to the identifier a converted source resolved to, without the oci-layout
		// scheme, so this session's own base comes back as an image reference. Left alone it is a registry pull from
		// a host that does not exist: BuildKit finds the manifest it just read and only the layer fetch fails.
		st.bases[baseRepository+"@"+digest] = digest
	}
}

func (a *adapter) noodle(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, "http://noodle/"+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("X-Noodle-Build-Token", a.token)
	return a.docker.Do(request)
}

func failure(response *http.Response) error {
	var payload struct{ Message string }
	_ = json.NewDecoder(io.LimitReader(response.Body, errorMessageMax)).Decode(&payload)
	if payload.Message == "" {
		payload.Message = fmt.Sprintf("Noodle returned HTTP %d", response.StatusCode)
	}
	return status.Error(codes.FailedPrecondition, payload.Message)
}

// resolveBase returns the manifest digest of an image the Mac supplies, or "" when the builder should pull it.
func (a *adapter) resolveBase(ctx context.Context, st *sessionState, ref string) (string, error) {
	if digest, ok := st.lookup(ref); ok {
		return digest, nil
	}
	payload, err := json.Marshal(struct {
		Ref  string
		Pull bool
	}{ref, st.pull.Load()})
	if err != nil {
		return "", err
	}
	response, err := a.noodle(ctx, "POST", "noodle/buildkit/base", payload)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", failure(response)
	}
	var out struct{ Digest string }
	if err := json.NewDecoder(io.LimitReader(response.Body, baseRequestMax)).Decode(&out); err != nil {
		return "", err
	}
	st.remember(ref, out.Digest)
	return out.Digest, nil
}

func (a *adapter) checkPolicy(st *sessionState, sid string, s grpc.ServerStream) error {
	var req policysession.CheckPolicyRequest
	if err := s.RecvMsg(&req); err != nil {
		return err
	}
	decision := &policysession.DecisionResponse{Action: policypb.PolicyAction_ALLOW}
	if src := req.GetSource().GetSource(); src != nil && strings.HasPrefix(src.Identifier, "docker-image://") {
		digest, err := a.resolveBase(s.Context(), st, strings.TrimPrefix(src.Identifier, "docker-image://"))
		if err != nil {
			return err
		}
		if digest != "" {
			decision = &policysession.DecisionResponse{Action: policypb.PolicyAction_CONVERT, Update: &opspb.SourceOp{
				Identifier: "oci-layout://" + baseRepository + "@" + digest,
				Attrs: map[string]string{
					opspb.AttrOCILayoutSessionID: sid,
					opspb.AttrOCILayoutStoreID:   baseStore,
				},
			}}
		}
	}
	return s.SendMsg(&policysession.CheckPolicyResponse{Result: &policysession.CheckPolicyResponse_Decision{Decision: decision}})
}

// ownsStore is true for content calls aimed at the store this adapter serves.
func ownsStore(ctx context.Context) bool {
	return strings.Join(metadata.ValueFromIncomingContext(ctx, storeHeader), ",") == "oci:"+baseStore
}

func (a *adapter) blob(ctx context.Context, digest string, offset, length int64) ([]byte, int64, error) {
	query := url.Values{"offset": {strconv.FormatInt(offset, 10)}, "length": {strconv.FormatInt(length, 10)}}
	response, err := a.noodle(ctx, "GET", "noodle/buildkit/blob/"+url.PathEscape(digest)+"?"+query.Encode(), nil)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, 0, status.Error(codes.NotFound, "blob "+digest+" is not available")
	}
	size, err := strconv.ParseInt(response.Header.Get("X-Noodle-Blob-Size"), 10, 64)
	if err != nil {
		return nil, 0, err
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, length+1))
	return data, size, err
}

func (a *adapter) info(s grpc.ServerStream) error {
	var req contentapi.InfoRequest
	if err := s.RecvMsg(&req); err != nil {
		return err
	}
	_, size, err := a.blob(s.Context(), req.Digest, 0, 0)
	if err != nil {
		return err
	}
	return s.SendMsg(&contentapi.InfoResponse{Info: &contentapi.Info{Digest: req.Digest, Size: size}})
}

func (a *adapter) read(s grpc.ServerStream) error {
	var req contentapi.ReadContentRequest
	if err := s.RecvMsg(&req); err != nil {
		return err
	}
	_, size, err := a.blob(s.Context(), req.Digest, 0, 0)
	if err != nil {
		return err
	}
	offset, end := req.Offset, size
	if req.Size > 0 && offset+req.Size < end {
		end = offset + req.Size
	}
	for offset < end {
		data, _, err := a.blob(s.Context(), req.Digest, offset, min(blobChunk, end-offset))
		if err != nil {
			return err
		}
		if len(data) == 0 {
			return status.Error(codes.DataLoss, "blob "+req.Digest+" ended early")
		}
		if err := s.SendMsg(&contentapi.ReadContentResponse{Offset: offset, Data: data}); err != nil {
			return err
		}
		offset += int64(len(data))
	}
	return nil
}
