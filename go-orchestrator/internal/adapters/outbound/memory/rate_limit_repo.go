package memory

import (
	"context"
	"sync"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type RateLimitRepository struct {
	mu      sync.RWMutex
	policies map[string]*entity.RateLimitPolicy
}

func NewRateLimitRepository() *RateLimitRepository {
	return &RateLimitRepository{
		policies: make(map[string]*entity.RateLimitPolicy),
	}
}

func policyKey(tenantID, resourceType string) string {
	return tenantID + ":" + resourceType
}

func (r *RateLimitRepository) SavePolicy(_ context.Context, policy *entity.RateLimitPolicy) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.policies[policyKey(policy.TenantID.String(), policy.ResourceType)] = policy
	return nil
}

func (r *RateLimitRepository) GetPolicy(_ context.Context, tenantID, resourceType string) (*entity.RateLimitPolicy, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.policies[policyKey(tenantID, resourceType)]
	if !ok {
		return nil, repository.ErrNotFound
	}
	return p, nil
}
