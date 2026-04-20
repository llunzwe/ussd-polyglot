package command

import (
	"context"
	"database/sql"
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
)

type mockEventRepo struct {
	mock.Mock
}

func (m *mockEventRepo) Append(ctx context.Context, events []entity.Event) error {
	args := m.Called(ctx, events)
	return args.Error(0)
}

func (m *mockEventRepo) AppendTx(ctx context.Context, tx *sql.Tx, events []entity.Event) ([]entity.StoredEventRecord, error) {
	args := m.Called(ctx, tx, events)
	if recs, ok := args.Get(0).([]entity.StoredEventRecord); ok {
		return recs, args.Error(1)
	}
	return nil, args.Error(1)
}

func (m *mockEventRepo) GetByAggregateID(ctx context.Context, aggregateID uuid.UUID, fromVersion int64) ([]entity.Event, error) {
	args := m.Called(ctx, aggregateID, fromVersion)
	if evs, ok := args.Get(0).([]entity.Event); ok {
		return evs, args.Error(1)
	}
	return nil, args.Error(1)
}

func (m *mockEventRepo) GetLatestVersion(ctx context.Context, aggregateID uuid.UUID) (int64, error) {
	args := m.Called(ctx, aggregateID)
	return args.Get(0).(int64), args.Error(1)
}

func (m *mockEventRepo) CheckIdempotency(ctx context.Context, key string) (bool, error) {
	args := m.Called(ctx, key)
	return args.Bool(0), args.Error(1)
}

func (m *mockEventRepo) StoreIdempotency(ctx context.Context, tx *sql.Tx, key string) error {
	args := m.Called(ctx, tx, key)
	return args.Error(0)
}

func (m *mockEventRepo) GetAllEvents(ctx context.Context, limit int32, offset int32) ([]entity.Event, error) {
	args := m.Called(ctx, limit, offset)
	if evs, ok := args.Get(0).([]entity.Event); ok {
		return evs, args.Error(1)
	}
	return nil, args.Error(1)
}

func (m *mockEventRepo) GetEventStats(ctx context.Context) (*entity.EventStats, error) {
	args := m.Called(ctx)
	if stats, ok := args.Get(0).(*entity.EventStats); ok {
		return stats, args.Error(1)
	}
	return nil, args.Error(1)
}

func TestAppendEventHandler_DuplicateEvent(t *testing.T) {
	repo := new(mockEventRepo)
	handler := &AppendEventHandler{eventRepo: repo}
	repo.On("CheckIdempotency", mock.Anything, "key-123").Return(true, nil)

	_, err := handler.Handle(context.Background(), AppendEventCommand{
		AggregateID:    uuid.Must(uuid.NewV7()),
		IdempotencyKey: "key-123",
	})

	assert.ErrorIs(t, err, ErrDuplicateEvent)
}

func TestAppendEventHandler_ConcurrencyConflict(t *testing.T) {
	repo := new(mockEventRepo)
	handler := &AppendEventHandler{eventRepo: repo}
	aggID := uuid.Must(uuid.NewV7())

	repo.On("CheckIdempotency", mock.Anything, "").Return(false, nil)
	repo.On("GetLatestVersion", mock.Anything, aggID).Return(int64(5), nil)

	_, err := handler.Handle(context.Background(), AppendEventCommand{
		AggregateID:     aggID,
		ExpectedVersion: 3,
	})

	assert.ErrorIs(t, err, ErrConcurrencyConflict)
}
