package command

import (
	"context"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/aggregate"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type RegisterTenantCommand struct {
	ID           uuid.UUID
	Name         string
	ServiceCode  string
	Endpoint     string
	RateLimitRPS int32
	Config       map[string]string
}

type RegisterTenantResult struct {
	TenantID string
}

type RegisterTenantHandler struct {
	tenantRepo repository.TenantRepository
}

func NewRegisterTenantHandler(tenantRepo repository.TenantRepository) *RegisterTenantHandler {
	return &RegisterTenantHandler{tenantRepo: tenantRepo}
}

func (h *RegisterTenantHandler) Handle(ctx context.Context, cmd RegisterTenantCommand) (*RegisterTenantResult, error) {
	tenant := &aggregate.Tenant{
		ID:           cmd.ID,
		Name:         cmd.Name,
		ServiceCode:  cmd.ServiceCode,
		Endpoint:     cmd.Endpoint,
		Active:       true,
		RateLimitRPS: cmd.RateLimitRPS,
		Config:       cmd.Config,
	}

	if err := h.tenantRepo.Save(ctx, tenant); err != nil {
		return nil, err
	}

	return &RegisterTenantResult{TenantID: tenant.ID.String()}, nil
}
