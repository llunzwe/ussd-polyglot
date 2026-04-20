package postgres

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type WebhookRepository struct {
	db *sql.DB
}

func NewWebhookRepository(db *sql.DB) *WebhookRepository {
	return &WebhookRepository{db: db}
}

func (r *WebhookRepository) setTenant(ctx context.Context, tenantID uuid.UUID) error {
	if tenantID == uuid.Nil {
		return nil
	}
	_, err := r.db.ExecContext(ctx, fmt.Sprintf("SET LOCAL app.current_tenant_id = '%s'", tenantID.String()))
	return err
}

func (r *WebhookRepository) SaveSubscription(ctx context.Context, sub *entity.WebhookSubscription) error {
	if sub.ID == uuid.Nil {
		sub.ID = uuid.Must(uuid.NewV7())
	}
	if sub.CreatedAt.IsZero() {
		sub.CreatedAt = time.Now().UTC()
	}

	r.setTenant(ctx, sub.TenantID)

	eventsJSON, _ := json.Marshal(sub.Events)
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO events.webhook_subscriptions (
			subscription_id, application_id, endpoint_url, endpoint_secret,
			event_types, is_active, created_at, updated_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
		ON CONFLICT (subscription_id) DO UPDATE SET
			endpoint_url = EXCLUDED.endpoint_url,
			endpoint_secret = EXCLUDED.endpoint_secret,
			event_types = EXCLUDED.event_types,
			is_active = EXCLUDED.is_active,
			updated_at = NOW()`,
		sub.ID, sub.TenantID, sub.URL, sub.Secret, eventsJSON, sub.Active, sub.CreatedAt,
	)
	return err
}

func (r *WebhookRepository) GetSubscription(ctx context.Context, id uuid.UUID) (*entity.WebhookSubscription, error) {
	var sub entity.WebhookSubscription
	var eventsRaw []byte
	var tenantID uuid.UUID
	err := r.db.QueryRowContext(ctx,
		`SELECT subscription_id, application_id, endpoint_url, endpoint_secret, event_types, is_active, created_at
		 FROM events.webhook_subscriptions WHERE subscription_id = $1`, id,
	).Scan(&sub.ID, &tenantID, &sub.URL, &sub.Secret, &eventsRaw, &sub.Active, &sub.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, repository.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	sub.TenantID = tenantID
	_ = json.Unmarshal(eventsRaw, &sub.Events)
	return &sub, nil
}

func (r *WebhookRepository) ListSubscriptions(ctx context.Context, tenantID uuid.UUID) ([]*entity.WebhookSubscription, error) {
	r.setTenant(ctx, tenantID)

	var rows *sql.Rows
	var err error
	if tenantID == uuid.Nil {
		rows, err = r.db.QueryContext(ctx,
			`SELECT subscription_id, application_id, endpoint_url, endpoint_secret, event_types, is_active, created_at
			 FROM events.webhook_subscriptions WHERE is_active = true`)
	} else {
		rows, err = r.db.QueryContext(ctx,
			`SELECT subscription_id, application_id, endpoint_url, endpoint_secret, event_types, is_active, created_at
			 FROM events.webhook_subscriptions WHERE application_id = $1 AND is_active = true`, tenantID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []*entity.WebhookSubscription
	for rows.Next() {
		var sub entity.WebhookSubscription
		var eventsRaw []byte
		var tid uuid.UUID
		if err := rows.Scan(&sub.ID, &tid, &sub.URL, &sub.Secret, &eventsRaw, &sub.Active, &sub.CreatedAt); err != nil {
			return nil, err
		}
		sub.TenantID = tid
		_ = json.Unmarshal(eventsRaw, &sub.Events)
		out = append(out, &sub)
	}
	return out, rows.Err()
}

func (r *WebhookRepository) DeleteSubscription(ctx context.Context, id uuid.UUID) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE events.webhook_subscriptions SET is_active = false, deactivated_at = NOW() WHERE subscription_id = $1`, id)
	return err
}

func (r *WebhookRepository) SaveDelivery(ctx context.Context, delivery *entity.WebhookDelivery) error {
	if delivery.ID == uuid.Nil {
		delivery.ID = uuid.Must(uuid.NewV7())
	}

	payloadJSON, _ := json.Marshal(delivery.Payload)
	var lastAttempt *time.Time
	if delivery.LastAttemptAt != nil {
		t := *delivery.LastAttemptAt
		lastAttempt = &t
	}
	var nextRetry *time.Time
	if delivery.NextRetryAt != nil {
		t := *delivery.NextRetryAt
		nextRetry = &t
	}

	_, err := r.db.ExecContext(ctx,
		`INSERT INTO events.webhook_deliveries (
			delivery_id, subscription_id, event_type, event_id, event_data,
			idempotency_key, attempt_number, response_status, status,
			sent_at, completed_at, next_retry_at, error_message, will_retry, created_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, NOW())
		ON CONFLICT (delivery_id) DO UPDATE SET
			attempt_number = EXCLUDED.attempt_number,
			response_status = EXCLUDED.response_status,
			status = EXCLUDED.status,
			sent_at = EXCLUDED.sent_at,
			completed_at = EXCLUDED.completed_at,
			next_retry_at = EXCLUDED.next_retry_at,
			error_message = EXCLUDED.error_message,
			will_retry = EXCLUDED.will_retry`,
		delivery.ID, delivery.SubscriptionID, delivery.EventType, uuid.Nil, payloadJSON,
		delivery.ID.String(), delivery.AttemptCount, delivery.HttpStatus, delivery.Status,
		lastAttempt, lastAttempt, nextRetry, nil, nextRetry != nil,
	)
	return err
}

func (r *WebhookRepository) GetDelivery(ctx context.Context, id uuid.UUID) (*entity.WebhookDelivery, error) {
	var d entity.WebhookDelivery
	var payloadRaw []byte
	var eventID uuid.UUID
	err := r.db.QueryRowContext(ctx,
		`SELECT delivery_id, subscription_id, event_type, event_id, event_data, response_status, status, attempt_number, created_at
		 FROM events.webhook_deliveries WHERE delivery_id = $1`, id,
	).Scan(&d.ID, &d.SubscriptionID, &d.EventType, &eventID, &payloadRaw, &d.HttpStatus, &d.Status, &d.AttemptCount, &d.LastAttemptAt)
	if err == sql.ErrNoRows {
		return nil, repository.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	_ = json.Unmarshal(payloadRaw, &d.Payload)
	return &d, nil
}

func (r *WebhookRepository) ListPendingDeliveries(ctx context.Context, limit int) ([]*entity.WebhookDelivery, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT delivery_id, subscription_id, event_type, event_data, response_status, status, attempt_number, created_at
		 FROM events.webhook_deliveries
		 WHERE status IN ('pending', 'retrying')
		   AND (next_retry_at IS NULL OR next_retry_at <= NOW())
		 ORDER BY created_at ASC
		 LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []*entity.WebhookDelivery
	for rows.Next() {
		var d entity.WebhookDelivery
		var payloadRaw []byte
		var createdAt time.Time
		if err := rows.Scan(&d.ID, &d.SubscriptionID, &d.EventType, &payloadRaw, &d.HttpStatus, &d.Status, &d.AttemptCount, &createdAt); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(payloadRaw, &d.Payload)
		d.LastAttemptAt = &createdAt
		out = append(out, &d)
	}
	return out, rows.Err()
}
