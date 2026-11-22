package guardfixture

import (
	"errors"
	"log"
)

const maxSize = 256

var (
	ErrForbidden = errors.New("forbidden")
	ErrTooLarge  = errors.New("too large")
)

func Authorize(owner, caller string) error {
	if caller == "" || owner != caller {
		log.Printf("denied %q access to a record owned by %q", caller, owner)
		return ErrForbidden
	}
	return nil
}

func CheckSize(n int) error {
	if n > maxSize {
		return ErrTooLarge
	}
	return nil
}
