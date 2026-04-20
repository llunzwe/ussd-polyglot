package service

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type RateLimitService struct {
	repo        repository.RateLimitRepository
	cache       repository.Cache
	limiter     RateLimiter
}

func NewRateLimitService(repo repository.RateLimitRepository, cache repository.Cache, limiter RateLimiter) *RateLimitService {
	return &RateLimitService{
		repo:    repo,
		cache:   cache,
		limiter: limiter,
	}
}

func (s *RateLimitService) UpdatePolicy(ctx context.Context, tenantID, resourceType string, rpm, rph, rpd, burst int64) (*entity.RateLimitPolicy, error) {
	policy := &entity.RateLimitPolicy{
		ID:                uuid.Must(uuid.NewV7()),
		TenantID:          uuid.Must(uuid.Parse(tenantID)),
		ResourceType:      resourceType,
		RequestsPerMinute: rpm,
		RequestsPerHour:   rph,
		RequestsPerDay:    rpd,
		BurstCapacity:     burst,
	}
	if err := s.repo.SavePolicy(ctx, policy); err != nil {
		return nil, fmt.Errorf("save policy: %w", err)
	}
	return policy, nil
}

func (s *RateLimitService) GetPolicy(ctx context.Context, tenantID, resourceType string) (*entity.RateLimitPolicy, error) {
	return s.repo.GetPolicy(ctx, tenantID, resourceType)
}

func (s *RateLimitService) GetStatus(ctx context.Context, tenantID, resourceType string) (int64, int64, int64, error) {
	policy, err := s.repo.GetPolicy(ctx, tenantID, resourceType)
	if err != nil {
		// return default status if no policy
		return 1000, 0, 1000, nil
	}

	key := fmt.Sprintf("rl:status:%s:%s", tenantID, resourceType)
	countStr, err := s.cache.Get(ctx, key)
	var count int64
	if err == nil {
		fmt.Sscanf(countStr, "%d", &count)
	}

	return policy.RequestsPerMinute, count, policy.BurstCapacity, nil
}

func (s *RateLimitService) Allow(ctx context.Context, tenantID, resourceType string) bool {
	policy, err := s.repo.GetPolicy(ctx, tenantID, resourceType)
	if err != nil {
		return true // fail open
	}
	limit := int(policy.RequestsPerMinute)
	if limit == 0 {
		limit = 100
	}
	return s.limiter.AllowTenant(ctx, tenantID, limit)
}

func (s *RateLimitService) RecordRequest(ctx context.Context, tenantID, resourceType string) error {
	key := fmt.Sprintf("rl:status:%s:%s", tenantID, resourceType)
	_, err := s.cache.Incr(ctx, key)
	if err != nil {
		return err
	}
	return s.cache.Expire(ctx, key, time.Minute)
}
