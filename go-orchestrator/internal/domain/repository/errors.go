package repository

import "errors"

var (
	ErrNotFound     = errors.New("not found")
	ErrDuplicateEvent = errors.New("duplicate event")
)
