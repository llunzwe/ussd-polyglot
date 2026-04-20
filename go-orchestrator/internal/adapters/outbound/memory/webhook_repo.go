package memory

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type WebhookRepository struct {
	mu            sync.RWMutex
	subscriptions map[uuid.UUID]*entity.WebhookSubscription
	deliveries    map[uuid.UUID]*entity.WebhookDelivery
}

func NewWebhookRepository() *WebhookRepository {
	return &WebhookRepository{
		subscriptions: make(map[uuid.UUID]*entity.WebhookSubscription),
		deliveries:    make(map[uuid.UUID]*entity.WebhookDelivery),
	}
}

func (r *WebhookRepository) SaveSubscription(_ context.Context, sub *entity.WebhookSubscription) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if sub.ID == uuid.Nil {
		sub.ID = uuid.Must(uuid.NewV7())
	}
	if sub.CreatedAt.IsZero() {
		sub.CreatedAt = time.Now().UTC()
	}
	r.subscriptions[sub.ID] = sub
	return nil
}

func (r *WebhookRepository) GetSubscription(_ context.Context, id uuid.UUID) (*entity.WebhookSubscription, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	sub, ok := r.subscriptions[id]
	if !ok {
		return nil, repository.ErrNotFound
	}
	return sub, nil
}

func (r *WebhookRepository) ListSubscriptions(_ context.Context, tenantID uuid.UUID) ([]*entity.WebhookSubscription, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []*entity.WebhookSubscription
	for _, sub := range r.subscriptions {
		if tenantID == uuid.Nil || sub.TenantID == tenantID {
			out = append(out, sub)
		}
	}
	return out, nil
}

func (r *WebhookRepository) DeleteSubscription(_ context.Context, id uuid.UUID) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.subscriptions, id)
	return nil
}

func (r *WebhookRepository) SaveDelivery(_ context.Context, delivery *entity.WebhookDelivery) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if delivery.ID == uuid.Nil {
		delivery.ID = uuid.Must(uuid.NewV7())
	}
	r.deliveries[delivery.ID] = delivery
	return nil
}

func (r *WebhookRepository) GetDelivery(_ context.Context, id uuid.UUID) (*entity.WebhookDelivery, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	d, ok := r.deliveries[id]
	if !ok {
		return nil, repository.ErrNotFound
	}
	return d, nil
}

func (r *WebhookRepository) ListPendingDeliveries(_ context.Context, limit int) ([]*entity.WebhookDelivery, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []*entity.WebhookDelivery
	for _, d := range r.deliveries {
		if d.Status == "pending" {
			out = append(out, d)
			if len(out) >= limit {
				break
			}
		}
	}
	return out, nil
}
