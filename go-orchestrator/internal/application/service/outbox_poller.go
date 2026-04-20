package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type OutboxPoller struct {
	db        *sql.DB
	eventRepo repository.EventRepository
	interval  time.Duration
	done      chan struct{}
}

func NewOutboxPoller(db *sql.DB, eventRepo repository.EventRepository) *OutboxPoller {
	return &OutboxPoller{
		db:        db,
		eventRepo: eventRepo,
		interval:  5 * time.Second,
		done:      make(chan struct{}),
	}
}

func (p *OutboxPoller) Start() {
	ticker := time.NewTicker(p.interval)
	go p.loop(ticker)
}

func (p *OutboxPoller) Stop() {
	close(p.done)
}

func (p *OutboxPoller) loop(ticker *time.Ticker) {
	for {
		select {
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			p.PollOutbox(ctx)
			cancel()
		case <-p.done:
			ticker.Stop()
			return
		}
	}
}

func (p *OutboxPoller) PollOutbox(ctx context.Context) {
	rows, err := p.db.QueryContext(ctx,
		`SELECT outbox_id, aggregate_type, aggregate_id, event_type, payload, tenant_id
		 FROM events.cdc_outbox
		 WHERE processed_at IS NULL AND retry_count < 10
		 ORDER BY created_at ASC
		 LIMIT 100`)
	if err != nil {
		slog.Error("outbox poll failed", slog.String("error", err.Error()))
		return
	}
	defer rows.Close()

	for rows.Next() {
		var outboxID uuid.UUID
		var aggregateType, eventType string
		var aggregateID uuid.UUID
		var payloadBytes []byte
		var tenantID uuid.UUID
		if err := rows.Scan(&outboxID, &aggregateType, &aggregateID, &eventType, &payloadBytes, &tenantID); err != nil {
			slog.Error("outbox scan failed", slog.String("error", err.Error()))
			continue
		}

		var payload map[string]interface{}
		_ = json.Unmarshal(payloadBytes, &payload)

		event := entity.DomainEvent{
			Type:          eventType,
			AggregateType: aggregateType,
			AggID:         aggregateID,
			EventTime:     time.Now().UTC(),
			Payload:       payload,
			Version:       1,
			TenantID:      tenantID,
		}

		if err := p.eventRepo.Append(ctx, []entity.Event{event}); err != nil {
			slog.Error("outbox append failed", slog.String("error", err.Error()), slog.String("outbox_id", outboxID.String()))
			_, _ = p.db.ExecContext(ctx,
				`UPDATE events.cdc_outbox SET retry_count = retry_count + 1, next_retry_at = NOW() + INTERVAL '5 seconds' WHERE outbox_id = $1`,
				outboxID)
			continue
		}

		_, _ = p.db.ExecContext(ctx,
			`UPDATE events.cdc_outbox SET processed_at = NOW(), processor_id = 'go-orchestrator' WHERE outbox_id = $1`,
			outboxID)
	}
}
