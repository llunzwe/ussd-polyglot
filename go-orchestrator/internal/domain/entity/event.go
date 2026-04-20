package entity

import (
	"time"

	"github.com/google/uuid"
)

type Event interface {
	EventType() string
	AggregateID() uuid.UUID
	OccurredAt() time.Time
}

type DomainEvent struct {
	Type          string
	AggregateType string
	AggID         uuid.UUID
	EventTime     time.Time
	Payload       map[string]interface{}
	Version       int64
	TenantID      uuid.UUID
	SessionID     uuid.UUID
	Correlation   string
	Causation     string
	Idempotency   string
}

func (d DomainEvent) EventType() string      { return d.Type }
func (d DomainEvent) AggregateID() uuid.UUID { return d.AggID }
func (d DomainEvent) OccurredAt() time.Time  { return d.EventTime }

type StoredEventRecord struct {
	EventID      string
	Version      int64
	RecordedAt   time.Time
	RecordHash   string
	PreviousHash string
}

type EventStats struct {
	TotalEvents   int64
	TotalAggregates int64
	EventTypes    map[string]int64
}
