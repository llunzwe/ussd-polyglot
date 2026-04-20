package aggregate

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/assert"
)

func TestSession_ApplyEvent_SessionCreated(t *testing.T) {
	s := &Session{}
	sessionID := uuid.Must(uuid.NewV7())
	tenantID := uuid.Must(uuid.NewV7())
	now := time.Now().UTC()

	event := SessionCreatedEvent{
		SessionID:      sessionID,
		TenantID:       tenantID,
		PhoneNumber:    "263712345678",
		OccurredAtTime: now,
	}

	s.ApplyEvent(event)

	assert.Equal(t, sessionID, s.ID)
	assert.Equal(t, tenantID, s.TenantID)
	assert.Equal(t, "263712345678", s.PhoneNumber)
	assert.Equal(t, SessionStatusActive, s.Status)
	assert.Equal(t, now, s.CreatedAt)
	assert.Equal(t, int64(1), s.Version)
}

func TestSession_ApplyEvent_MenuNavigated(t *testing.T) {
	s := &Session{Version: 1}
	now := time.Now().UTC()

	event := MenuNavigatedEvent{
		SessionID:      uuid.Must(uuid.NewV7()),
		MenuID:         "main_menu",
		OccurredAtTime: now,
	}

	s.ApplyEvent(event)

	assert.Equal(t, "main_menu", s.CurrentMenu)
	assert.Equal(t, now, s.LastActivity)
	assert.Equal(t, int64(2), s.Version)
}

func TestSession_ApplyEvent_InputReceived(t *testing.T) {
	s := &Session{Version: 2}
	now := time.Now().UTC()

	event := InputReceivedEvent{
		SessionID:      uuid.Must(uuid.NewV7()),
		Input:          "1",
		OccurredAtTime: now,
	}

	s.ApplyEvent(event)

	assert.Equal(t, now, s.LastActivity)
	assert.Equal(t, int64(3), s.Version)
}

func TestSession_ApplyEvent_SessionEnded(t *testing.T) {
	s := &Session{Version: 3}
	now := time.Now().UTC()

	event := SessionEndedEvent{
		SessionID:      uuid.Must(uuid.NewV7()),
		Reason:         "user_completed",
		OccurredAtTime: now,
	}

	s.ApplyEvent(event)

	assert.Equal(t, SessionStatusCompleted, s.Status)
	assert.Equal(t, now, s.LastActivity)
	assert.Equal(t, int64(4), s.Version)
}
