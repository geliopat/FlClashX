package core

import (
	"context"
	"errors"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func TestFailedRequestRetainsSelectedRouteAndMetadataSnapshot(t *testing.T) {
	metadata := &C.Metadata{Host: "example.test", DstGeoIP: []string{"DE"}}
	at := time.Now()
	request := newFailedRequest(metadata, nil, namedProxy("selected"), context.DeadlineExceeded, at)
	metadata.Host = "changed.test"
	metadata.DstGeoIP[0] = "FR"
	if request.Metadata.Host != "example.test" || request.Metadata.DstGeoIP[0] != "DE" {
		t.Fatal("failed request metadata aliases mutable input")
	}
	if len(request.Chains) != 1 || request.Chains[0] != "selected" {
		t.Fatalf("selected route = %v", request.Chains)
	}
	if request.Failure.Kind != FailureTimeout || !request.ClosedAt.Equal(at) {
		t.Fatalf("failed request = %+v", request)
	}
}

func TestNativeFailureClassification(t *testing.T) {
	for _, errno := range refusedErrnos {
		if got := failureKindOf(errno); got != FailureRefused {
			t.Fatalf("%v = %s, want refused", errno, got)
		}
	}
	if got := failureKindOf(errors.New("unclassified")); got != FailureOther {
		t.Fatalf("unclassified = %s", got)
	}
}
