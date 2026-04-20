package entity

import (
	"time"

	"github.com/google/uuid"
)

type SystemConfig struct {
	Key   string
	Value string
}

type AuditLog struct {
	ID        uuid.UUID
	TenantID  uuid.UUID
	Action    string
	Actor     string
	Details   map[string]string
	CreatedAt time.Time
}
