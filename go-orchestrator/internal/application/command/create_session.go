package command

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/aggregate"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type CreateSessionCommand struct {
	PhoneNumber string
	TenantID    uuid.UUID
	ServiceCode string
}

type CreateSessionResult struct {
	SessionID string
	Version   int64
}

type CreateSessionHandler struct {
	eventRepo repository.EventRepository
}

func NewCreateSessionHandler(eventRepo repository.EventRepository) *CreateSessionHandler {
	return &CreateSessionHandler{eventRepo: eventRepo}
}

func (h *CreateSessionHandler) Handle(ctx context.Context, cmd CreateSessionCommand) (*CreateSessionResult, error) {
	sessionID := uuid.Must(uuid.NewV7())
	occurredAt := time.Now().UTC()

	event := aggregate.SessionCreatedEvent{
		SessionID:      sessionID,
		TenantID:       cmd.TenantID,
		PhoneNumber:    cmd.PhoneNumber,
		OccurredAtTime: occurredAt,
	}

	err := h.eventRepo.Append(ctx, []entity.Event{event})
	if err != nil {
		return nil, err
	}

	return &CreateSessionResult{
		SessionID: sessionID.String(),
		Version:   1,
	}, nil
}
