package repository

import (
	"context"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/aggregate"
)

type TenantRepository interface {
	GetByServiceCode(ctx context.Context, code string) (*aggregate.Tenant, error)
	GetByID(ctx context.Context, id uuid.UUID) (*aggregate.Tenant, error)
	Save(ctx context.Context, tenant *aggregate.Tenant) error
	List(ctx context.Context) ([]aggregate.Tenant, error)
}
