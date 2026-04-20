package repository

import (
	"context"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
)

type WebhookRepository interface {
	SaveSubscription(ctx context.Context, sub *entity.WebhookSubscription) error
	GetSubscription(ctx context.Context, id uuid.UUID) (*entity.WebhookSubscription, error)
	ListSubscriptions(ctx context.Context, tenantID uuid.UUID) ([]*entity.WebhookSubscription, error)
	DeleteSubscription(ctx context.Context, id uuid.UUID) error
	SaveDelivery(ctx context.Context, delivery *entity.WebhookDelivery) error
	GetDelivery(ctx context.Context, id uuid.UUID) (*entity.WebhookDelivery, error)
	ListPendingDeliveries(ctx context.Context, limit int) ([]*entity.WebhookDelivery, error)
}
