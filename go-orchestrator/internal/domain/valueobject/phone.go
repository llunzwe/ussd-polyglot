package valueobject

import (
	"errors"
	"regexp"
)

var phoneRegex = regexp.MustCompile(`^2637[1378]\d{8}$`)

var ErrInvalidPhoneNumber = errors.New("invalid phone number")

type PhoneNumber struct {
	value string
}

func NewPhoneNumber(raw string) (PhoneNumber, error) {
	if !phoneRegex.MatchString(raw) {
		return PhoneNumber{}, ErrInvalidPhoneNumber
	}
	return PhoneNumber{value: raw}, nil
}

func (p PhoneNumber) String() string { return p.value }
