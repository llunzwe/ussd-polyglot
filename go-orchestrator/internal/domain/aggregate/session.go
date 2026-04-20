package aggregate

import (
	"time"

	"github.com/google/uuid"
)

type SessionStatus string

const (
	SessionStatusActive    SessionStatus = "active"
	SessionStatusExpired   SessionStatus = "expired"
	SessionStatusCompleted SessionStatus = "completed"
	SessionStatusAborted   SessionStatus = "aborted"
)

type Session struct {
	ID           uuid.UUID
	TenantID     uuid.UUID
	PhoneNumber  string
	CurrentMenu  string
	State        map[string]interface{}
	Version      int64
	CreatedAt    time.Time
	LastActivity time.Time
	ExpiresAt    time.Time
	Status       SessionStatus
}

type SessionCreatedEvent struct {
	SessionID      uuid.UUID
	TenantID       uuid.UUID
	PhoneNumber    string
	OccurredAtTime time.Time
}

func (e SessionCreatedEvent) EventType() string      { return "SessionCreated" }
func (e SessionCreatedEvent) AggregateID() uuid.UUID { return e.SessionID }
func (e SessionCreatedEvent) OccurredAt() time.Time  { return e.OccurredAtTime }

type MenuNavigatedEvent struct {
	SessionID      uuid.UUID
	MenuID         string
	OccurredAtTime time.Time
}

func (e MenuNavigatedEvent) EventType() string      { return "MenuNavigated" }
func (e MenuNavigatedEvent) AggregateID() uuid.UUID { return e.SessionID }
func (e MenuNavigatedEvent) OccurredAt() time.Time  { return e.OccurredAtTime }

type InputReceivedEvent struct {
	SessionID      uuid.UUID
	Input          string
	OccurredAtTime time.Time
}

func (e InputReceivedEvent) EventType() string      { return "InputReceived" }
func (e InputReceivedEvent) AggregateID() uuid.UUID { return e.SessionID }
func (e InputReceivedEvent) OccurredAt() time.Time  { return e.OccurredAtTime }

type SessionEndedEvent struct {
	SessionID      uuid.UUID
	Reason         string
	OccurredAtTime time.Time
}

func (e SessionEndedEvent) EventType() string      { return "SessionEnded" }
func (e SessionEndedEvent) AggregateID() uuid.UUID { return e.SessionID }
func (e SessionEndedEvent) OccurredAt() time.Time  { return e.OccurredAtTime }

func (s *Session) ApplyEvent(event interface{}) {
	switch e := event.(type) {
	case SessionCreatedEvent:
		s.ID = e.SessionID
		s.TenantID = e.TenantID
		s.PhoneNumber = e.PhoneNumber
		s.Status = SessionStatusActive
		s.CreatedAt = e.OccurredAtTime
		s.LastActivity = e.OccurredAtTime
		s.Version++
	case MenuNavigatedEvent:
		s.CurrentMenu = e.MenuID
		s.LastActivity = e.OccurredAtTime
		s.Version++
	case InputReceivedEvent:
		s.LastActivity = e.OccurredAtTime
		s.Version++
	case SessionEndedEvent:
		s.Status = SessionStatusCompleted
		s.LastActivity = e.OccurredAtTime
		s.Version++
	}
}
