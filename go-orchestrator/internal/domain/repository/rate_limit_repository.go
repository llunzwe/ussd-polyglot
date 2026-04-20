package repository

import (
	"context"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
)

type RateLimitRepository interface {
	SavePolicy(ctx context.Context, policy *entity.RateLimitPolicy) error
	GetPolicy(ctx context.Context, tenantID, resourceType string) (*entity.RateLimitPolicy, error)
}
