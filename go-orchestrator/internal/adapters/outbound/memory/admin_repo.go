package memory

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type AdminRepository struct {
	mu        sync.RWMutex
	configs   map[string]string
	auditLogs []*entity.AuditLog
}

func NewAdminRepository() *AdminRepository {
	return &AdminRepository{
		configs:   make(map[string]string),
		auditLogs: make([]*entity.AuditLog, 0),
	}
}

func (r *AdminRepository) GetConfig(_ context.Context, key string) (string, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	v, ok := r.configs[key]
	if !ok {
		return "", repository.ErrNotFound
	}
	return v, nil
}

func (r *AdminRepository) SetConfig(_ context.Context, key, value string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.configs[key] = value
	return nil
}

func (r *AdminRepository) ListAuditLogs(_ context.Context, tenantID uuid.UUID, from, to time.Time) ([]*entity.AuditLog, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []*entity.AuditLog
	for _, log := range r.auditLogs {
		if tenantID != uuid.Nil && log.TenantID != tenantID {
			continue
		}
		if !from.IsZero() && log.CreatedAt.Before(from) {
			continue
		}
		if !to.IsZero() && log.CreatedAt.After(to) {
			continue
		}
		out = append(out, log)
	}
	return out, nil
}

func (r *AdminRepository) SaveAuditLog(_ context.Context, log *entity.AuditLog) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if log.ID == uuid.Nil {
		log.ID = uuid.Must(uuid.NewV7())
	}
	if log.CreatedAt.IsZero() {
		log.CreatedAt = time.Now().UTC()
	}
	r.auditLogs = append(r.auditLogs, log)
	return nil
}
