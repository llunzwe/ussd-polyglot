package entity

import (
	"github.com/google/uuid"
)

type RateLimitPolicy struct {
	ID                uuid.UUID
	TenantID          uuid.UUID
	ResourceType      string
	RequestsPerMinute int64
	RequestsPerHour   int64
	RequestsPerDay    int64
	BurstCapacity     int64
}
