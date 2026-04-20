package command

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

var (
	ErrDuplicateEvent      = repository.ErrDuplicateEvent
	ErrConcurrencyConflict = errors.New("concurrency conflict")
)

type AppendEventCommand struct {
	EventType       string
	AggregateType   string
	AggregateID     uuid.UUID
	ExpectedVersion int64
	Payload         map[string]interface{}
	IdempotencyKey  string
	TenantID        uuid.UUID
	SessionID       uuid.UUID
	CorrelationID   string
	CausationID     string
}

type AppendEventResult struct {
	EventID      string
	Version      int64
	RecordedAt   time.Time
	RecordHash   string
	PreviousHash string
}

type AppendEventHandler struct {
	eventRepo repository.EventRepository
	db        *sql.DB
}

func NewAppendEventHandler(eventRepo repository.EventRepository, db *sql.DB) *AppendEventHandler {
	return &AppendEventHandler{eventRepo: eventRepo, db: db}
}

func (h *AppendEventHandler) Handle(ctx context.Context, cmd AppendEventCommand) (*AppendEventResult, error) {
	if cmd.IdempotencyKey != "" {
		exists, err := h.eventRepo.CheckIdempotency(ctx, cmd.IdempotencyKey)
		if err != nil {
			return nil, err
		}
		if exists {
			return nil, ErrDuplicateEvent
		}
	}

	latestVersion, err := h.eventRepo.GetLatestVersion(ctx, cmd.AggregateID)
	if err != nil {
		return nil, err
	}
	if cmd.ExpectedVersion >= 0 && latestVersion != cmd.ExpectedVersion {
		return nil, ErrConcurrencyConflict
	}

	tx, err := h.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Transactional idempotency check to close race condition
	if cmd.IdempotencyKey != "" {
		if err := h.eventRepo.StoreIdempotency(ctx, tx, cmd.IdempotencyKey); err != nil {
			if errors.Is(err, ErrDuplicateEvent) {
				return nil, ErrDuplicateEvent
			}
			return nil, err
		}
	}

	occurredAt := time.Now().UTC()
	event := entity.DomainEvent{
		Type:          cmd.EventType,
		AggregateType: cmd.AggregateType,
		AggID:         cmd.AggregateID,
		EventTime:     occurredAt,
		Payload:       cmd.Payload,
		Version:       latestVersion + 1,
		TenantID:      cmd.TenantID,
		SessionID:     cmd.SessionID,
		Correlation:   cmd.CorrelationID,
		Causation:     cmd.CausationID,
		Idempotency:   cmd.IdempotencyKey,
	}

	records, err := h.eventRepo.AppendTx(ctx, tx, []entity.Event{event})
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	if len(records) == 0 {
		return nil, errors.New("no event record returned")
	}

	return &AppendEventResult{
		EventID:      records[0].EventID,
		Version:      records[0].Version,
		RecordedAt:   records[0].RecordedAt,
		RecordHash:   records[0].RecordHash,
		PreviousHash: records[0].PreviousHash,
	}, nil
}
