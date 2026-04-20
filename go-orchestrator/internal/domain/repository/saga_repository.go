package repository

import (
	"context"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
)

type SagaRepository interface {
	SaveSaga(ctx context.Context, saga *entity.Saga) error
	GetSaga(ctx context.Context, id uuid.UUID) (*entity.Saga, error)
	ListSagas(ctx context.Context, tenantID uuid.UUID) ([]*entity.Saga, error)
}
