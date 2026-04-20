package repository

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
)

type AdminRepository interface {
	GetConfig(ctx context.Context, key string) (string, error)
	SetConfig(ctx context.Context, key, value string) error
	ListAuditLogs(ctx context.Context, tenantID uuid.UUID, from, to time.Time) ([]*entity.AuditLog, error)
	SaveAuditLog(ctx context.Context, log *entity.AuditLog) error
}
