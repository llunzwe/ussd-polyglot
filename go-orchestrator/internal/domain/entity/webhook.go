package entity

import (
	"time"

	"github.com/google/uuid"
)

type WebhookSubscription struct {
	ID        uuid.UUID
	TenantID  uuid.UUID
	URL       string
	Events    []string
	Secret    string
	Active    bool
	CreatedAt time.Time
}

type WebhookDelivery struct {
	ID             uuid.UUID
	SubscriptionID uuid.UUID
	EventType      string
	Payload        map[string]interface{}
	Status         string // pending, delivered, failed
	HttpStatus     int
	AttemptCount   int
	LastAttemptAt  *time.Time
	NextRetryAt    *time.Time
}
