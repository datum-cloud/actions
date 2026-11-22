package guardfixture

import (
	"errors"
	"testing"
)

func TestAuthorizeRejectsAnotherCaller(t *testing.T) {
	if err := Authorize("alice", "bob"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("got %v, want ErrForbidden", err)
	}
}

func TestAuthorizeRejectsAnEmptyCaller(t *testing.T) {
	if err := Authorize("", ""); !errors.Is(err, ErrForbidden) {
		t.Fatalf("got %v, want ErrForbidden", err)
	}
}

func TestAuthorizeAllowsTheOwner(t *testing.T) {
	if err := Authorize("alice", "alice"); err != nil {
		t.Fatalf("got %v, want nil", err)
	}
}

func TestCheckSizeAcceptsASmallRecord(t *testing.T) {
	if err := CheckSize(1); err != nil {
		t.Fatalf("got %v, want nil", err)
	}
}
