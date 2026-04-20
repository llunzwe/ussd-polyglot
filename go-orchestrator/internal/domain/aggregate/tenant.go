package aggregate

import "github.com/google/uuid"

type Tenant struct {
	ID           uuid.UUID
	Name         string
	ServiceCode  string
	Endpoint     string
	Active       bool
	RateLimitRPS int32
	Config       map[string]string
}
