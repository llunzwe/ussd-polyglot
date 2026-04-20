package repository

import (
	"context"
	"database/sql"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
)

type EventRepository interface {
	Append(ctx context.Context, events []entity.Event) error
	AppendTx(ctx context.Context, tx *sql.Tx, events []entity.Event) ([]entity.StoredEventRecord, error)
	GetByAggregateID(ctx context.Context, aggregateID uuid.UUID, fromVersion int64) ([]entity.Event, error)
	GetAllEvents(ctx context.Context, limit int32, offset int32) ([]entity.Event, error)
	GetEventStats(ctx context.Context) (*entity.EventStats, error)
	GetLatestVersion(ctx context.Context, aggregateID uuid.UUID) (int64, error)
	CheckIdempotency(ctx context.Context, key string) (bool, error)
	StoreIdempotency(ctx context.Context, tx *sql.Tx, key string) error
}
