package memory

import (
	"context"
	"sync"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type SagaRepository struct {
	mu    sync.RWMutex
	sagas map[uuid.UUID]*entity.Saga
}

func NewSagaRepository() *SagaRepository {
	return &SagaRepository{
		sagas: make(map[uuid.UUID]*entity.Saga),
	}
}

func (r *SagaRepository) SaveSaga(_ context.Context, saga *entity.Saga) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sagas[saga.ID] = saga
	return nil
}

func (r *SagaRepository) GetSaga(_ context.Context, id uuid.UUID) (*entity.Saga, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	saga, ok := r.sagas[id]
	if !ok {
		return nil, repository.ErrNotFound
	}
	return saga, nil
}

func (r *SagaRepository) ListSagas(_ context.Context, tenantID uuid.UUID) ([]*entity.Saga, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []*entity.Saga
	for _, saga := range r.sagas {
		if tenantID == uuid.Nil || saga.TenantID == tenantID {
			out = append(out, saga)
		}
	}
	return out, nil
}
