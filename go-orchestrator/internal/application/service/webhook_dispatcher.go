package service

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type WebhookDispatcher struct {
	repo   repository.WebhookRepository
	client *http.Client
	ticker *time.Ticker
	done   chan struct{}
}

func NewWebhookDispatcher(repo repository.WebhookRepository) *WebhookDispatcher {
	return &WebhookDispatcher{
		repo:   repo,
		client: &http.Client{Timeout: 10 * time.Second},
		done:   make(chan struct{}),
	}
}

func (d *WebhookDispatcher) Start() {
	d.ticker = time.NewTicker(10 * time.Second)
	go d.dispatchLoop()
}

func (d *WebhookDispatcher) Stop() {
	if d.ticker != nil {
		d.ticker.Stop()
	}
	close(d.done)
}

func (d *WebhookDispatcher) dispatchLoop() {
	for {
		select {
		case <-d.ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			d.processPending(ctx)
			cancel()
		case <-d.done:
			return
		}
	}
}

func (d *WebhookDispatcher) processPending(ctx context.Context) {
	deliveries, err := d.repo.ListPendingDeliveries(ctx, 100)
	if err != nil {
		slog.Error("failed to list pending deliveries", slog.String("error", err.Error()))
		return
	}
	for _, delivery := range deliveries {
		d.dispatchDelivery(ctx, delivery)
	}
}

func (d *WebhookDispatcher) dispatchDelivery(ctx context.Context, delivery *entity.WebhookDelivery) {
	sub, err := d.repo.GetSubscription(ctx, delivery.SubscriptionID)
	if err != nil {
		slog.Error("failed to get subscription for delivery",
			slog.String("delivery_id", delivery.ID.String()),
			slog.String("error", err.Error()))
		return
	}
	if !sub.Active {
		return
	}

	payload, _ := json.Marshal(delivery.Payload)
	signature := signWebhookPayload(sub.Secret, payload)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.URL, bytes.NewReader(payload))
	if err != nil {
		slog.Error("failed to create webhook request",
			slog.String("delivery_id", delivery.ID.String()),
			slog.String("error", err.Error()))
		d.recordAttempt(ctx, delivery, 0, err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Webhook-Signature", signature)
	req.Header.Set("X-Event-Type", delivery.EventType)

	resp, err := d.client.Do(req)
	if err != nil {
		slog.Error("webhook delivery failed",
			slog.String("delivery_id", delivery.ID.String()),
			slog.String("error", err.Error()))
		d.recordAttempt(ctx, delivery, 0, err)
		return
	}
	defer resp.Body.Close()

	d.recordAttempt(ctx, delivery, resp.StatusCode, nil)

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		slog.Info("webhook delivered",
			slog.String("delivery_id", delivery.ID.String()),
			slog.Int("status_code", resp.StatusCode))
	} else {
		slog.Warn("webhook delivery received non-2xx",
			slog.String("delivery_id", delivery.ID.String()),
			slog.Int("status_code", resp.StatusCode))
	}
}

func (d *WebhookDispatcher) recordAttempt(ctx context.Context, delivery *entity.WebhookDelivery, statusCode int, err error) {
	delivery.AttemptCount++
	now := time.Now().UTC()
	delivery.LastAttemptAt = &now
	delivery.HttpStatus = statusCode

	if statusCode >= 200 && statusCode < 300 {
		delivery.Status = "delivered"
		delivery.NextRetryAt = nil
	} else if delivery.AttemptCount >= 5 {
		delivery.Status = "failed"
		delivery.NextRetryAt = nil
	} else {
		delivery.Status = "pending"
		backoff := time.Duration(math.Pow(2, float64(delivery.AttemptCount))) * time.Second
		next := now.Add(backoff)
		delivery.NextRetryAt = &next
	}

	if saveErr := d.repo.SaveDelivery(ctx, delivery); saveErr != nil {
		slog.Error("failed to save delivery attempt",
			slog.String("delivery_id", delivery.ID.String()),
			slog.String("error", saveErr.Error()))
	}
}

func signWebhookPayload(secret string, payload []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(payload)
	return hex.EncodeToString(mac.Sum(nil))
}

func (d *WebhookDispatcher) DispatchEvent(ctx context.Context, tenantID string, eventType string, payload map[string]interface{}) error {
	var tenantUUID uuid.UUID
	if tenantID != "" {
		var err error
		tenantUUID, err = uuid.Parse(tenantID)
		if err != nil {
			return err
		}
	}
	subs, err := d.repo.ListSubscriptions(ctx, tenantUUID)
	if err != nil {
		return fmt.Errorf("list subscriptions: %w", err)
	}
	for _, sub := range subs {
		if !sub.Active {
			continue
		}
		matched := false
		for _, e := range sub.Events {
			if e == eventType || e == "ALL_EVENTS" {
				matched = true
				break
			}
		}
		if !matched {
			continue
		}
		delivery := &entity.WebhookDelivery{
			SubscriptionID: sub.ID,
			EventType:      eventType,
			Payload:        payload,
			Status:         "pending",
		}
		if saveErr := d.repo.SaveDelivery(ctx, delivery); saveErr != nil {
			slog.Error("failed to save delivery", slog.String("error", saveErr.Error()))
		}
	}
	return nil
}
