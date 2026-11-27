package core

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

type FailureKind string

const (
	FailureTimeout     FailureKind = "timeout"
	FailureRefused     FailureKind = "refused"
	FailureUnreachable FailureKind = "unreachable"
	FailureDns         FailureKind = "dns"
	FailureHandshake   FailureKind = "handshake"
	FailureOther       FailureKind = "other"
)

type RequestFailure struct {
	Kind    FailureKind `json:"kind"`
	Message string      `json:"message"`
}

type FailedRequest struct {
	Id string `json:"id"`
	Metadata *C.Metadata `json:"metadata"`
	Start time.Time `json:"start"`
	Chains []string `json:"chains"`
	Rule string `json:"rule"`
	RulePayload string `json:"rulePayload"`
	ClosedAt time.Time `json:"closedAt"`
	Failure RequestFailure `json:"failure"`
}

func newFailedRequest(metadata *C.Metadata, rule C.Rule, proxy C.Proxy, err error, at time.Time) *FailedRequest {
	// Capture the selected route, not a group's current leaf: it may have
	// changed since the failed dial. There is no successful tracker.
	snapshot := *metadata
	snapshot.SrcGeoIP = append([]string(nil), metadata.SrcGeoIP...)
	snapshot.DstGeoIP = append([]string(nil), metadata.DstGeoIP...)
	request := &FailedRequest{
		Id: utils.NewUUIDV4().String(),
		Metadata: &snapshot,
		Start: at,
		ClosedAt: at,
		Chains: []string{},
		Failure: RequestFailure{Kind: failureKindOf(err), Message: err.Error()},
	}
	if proxy != nil {
		request.Chains = append(request.Chains, proxy.Name())
	}
	if rule != nil {
		request.Rule = rule.RuleType().String()
		request.RulePayload = rule.Payload()
	}
	return request
}

func init() {
	tunnel.DefaultDialFailureNotify = func(metadata *C.Metadata, rule C.Rule, proxy C.Proxy, err error) {
		if hostWantsEvents() && metadata != nil && err != nil {
			sendMessage(RequestMessage, newFailedRequest(metadata, rule, proxy, err, time.Now()))
		}
	}
}

func failureKindOf(err error) FailureKind {
	var dnsErr *net.DNSError
	var netErr net.Error
	switch {
	case errors.Is(err, resolver.ErrIPNotFound),
		errors.Is(err, resolver.ErrIPVersion),
		errors.As(err, &dnsErr) && dnsErr.IsNotFound:
		return FailureDns
	case errors.Is(err, resolver.ErrIPv6Disabled):
		return FailureUnreachable
	case errors.Is(err, context.DeadlineExceeded),
		errors.Is(err, os.ErrDeadlineExceeded),
		errors.As(err, &netErr) && netErr.Timeout(),
		isErrno(err, timeoutErrnos):
		return FailureTimeout
	case isErrno(err, refusedErrnos):
		return FailureRefused
	case isErrno(err, unreachableErrnos):
		return FailureUnreachable
	case errors.Is(err, io.EOF),
		errors.Is(err, io.ErrUnexpectedEOF),
		errors.Is(err, net.ErrClosed),
		isErrno(err, handshakeErrnos):
		return FailureHandshake
	default:
		return FailureOther
	}
}

func isErrno[E error](err error, errnos []E) bool {
	for _, errno := range errnos {
		if errors.Is(err, errno) {
			return true
		}
	}
	return false
}
