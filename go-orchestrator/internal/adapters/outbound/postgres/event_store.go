package postgres

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type EventStore struct {
	db *sql.DB
}

func NewEventStore(db *sql.DB) *EventStore {
	return &EventStore{db: db}
}

func (s *EventStore) Append(ctx context.Context, events []entity.Event) error {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = s.AppendTx(ctx, tx, events)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *EventStore) AppendTx(ctx context.Context, tx *sql.Tx, events []entity.Event) ([]entity.StoredEventRecord, error) {
	records := make([]entity.StoredEventRecord, 0, len(events))
	for _, ev := range events {
		domEvent, ok := ev.(entity.DomainEvent)
		if !ok {
			return nil, fmt.Errorf("unsupported event type")
		}

		if domEvent.TenantID != uuid.Nil {
			_, err := tx.ExecContext(ctx, fmt.Sprintf("SET LOCAL app.current_tenant_id = '%s'", domEvent.TenantID.String()))
			if err != nil {
				return nil, err
			}
		}

		var prevHash string
		row := tx.QueryRowContext(ctx,
			`SELECT record_hash FROM events.event_store WHERE stream_id = $1 ORDER BY sequence_number DESC LIMIT 1`,
			domEvent.AggID.String())
		_ = row.Scan(&prevHash)

		payloadBytes, err := json.Marshal(domEvent.Payload)
		if err != nil {
			return nil, err
		}

		hashInput := prevHash + string(payloadBytes) + fmt.Sprintf("%d", domEvent.EventTime.UnixNano())
		recordHash := sha256.Sum256([]byte(hashInput))
		recordHashHex := hex.EncodeToString(recordHash[:])

		eventID := uuid.Must(uuid.NewV7()).String()

		metadata := map[string]interface{}{
			"tenant_id":       nullUUID(domEvent.TenantID),
			"session_id":      nullUUID(domEvent.SessionID),
			"idempotency_key": nullString(domEvent.Idempotency),
			"record_hash":     recordHashHex,
			"previous_hash":   prevHash,
		}
		metadataBytes, _ := json.Marshal(metadata)

		_, err = tx.ExecContext(ctx,
			`INSERT INTO events.event_store (
				event_id, event_type, event_version, stream_id, stream_type, sequence_number,
				payload, metadata, correlation_id, causation_id, triggered_by,
				occurred_at, recorded_at, aggregate_version, partition_date
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, NOW(), $13, CURRENT_DATE)`,
			eventID, domEvent.Type, 1, domEvent.AggID.String(), domEvent.AggregateType, domEvent.Version,
			payloadBytes, metadataBytes,
			nullString(domEvent.Correlation), nullString(domEvent.Causation), "go-orchestrator",
			domEvent.EventTime, domEvent.Version,
		)
		if err != nil {
			return nil, err
		}

		// Financial events also go to core.transaction_log
		if isFinancialEvent(domEvent.AggregateType) {
			if err := s.appendTransactionLog(ctx, tx, domEvent, recordHashHex, prevHash); err != nil {
				return nil, err
			}
		}

		records = append(records, entity.StoredEventRecord{
			EventID:      eventID,
			Version:      domEvent.Version,
			RecordedAt:   domEvent.EventTime,
			RecordHash:   recordHashHex,
			PreviousHash: prevHash,
		})
	}
	return records, nil
}

func isFinancialEvent(aggregateType string) bool {
	return aggregateType == "PAYMENT" || aggregateType == "Transaction"
}

func (s *EventStore) appendTransactionLog(ctx context.Context, tx *sql.Tx, ev entity.DomainEvent, recordHash, prevHash string) error {
	// Look up transaction type
	typeCode := "SYSTEM"
	if ev.Type == "PaymentInitiated" {
		typeCode = "PAYMENT"
	}
	var typeID uuid.UUID
	err := tx.QueryRowContext(ctx,
		`SELECT type_id FROM core.transaction_types WHERE type_code = $1 AND is_active = TRUE`,
		typeCode).Scan(&typeID)
	if err != nil {
		if err == sql.ErrNoRows {
			err = tx.QueryRowContext(ctx,
				`SELECT type_id FROM core.transaction_types WHERE type_code = 'SYSTEM' AND is_active = TRUE`,
			).Scan(&typeID)
			if err != nil {
				return fmt.Errorf("failed to resolve transaction type: %w", err)
			}
		} else {
			return fmt.Errorf("failed to lookup transaction type: %w", err)
		}
	}

	payloadBytes, _ := json.Marshal(ev.Payload)

	var amount interface{}
	var currency string
	if amt, ok := ev.Payload["amount"]; ok {
		amount = amt
	}
	if curr, ok := ev.Payload["currency"].(string); ok {
		currency = curr
	}

	idempotencyKey := ev.Idempotency
	if idempotencyKey == "" {
		idempotencyKey = fmt.Sprintf("fin-%s-%d", ev.AggID.String(), ev.Version)
	}
	if len(idempotencyKey) < 8 {
		idempotencyKey = idempotencyKey + "-padding"
	}

	systemAccount := uuid.MustParse("00000000-0000-0000-0000-000000000001")

	_, err = tx.ExecContext(ctx,
		`INSERT INTO core.transaction_log (
			transaction_uuid, idempotency_key, transaction_type_id, application_id,
			initiator_account_id, payload, amount, currency, status,
			committed_at, correlation_id, causation_id, record_hash, previous_hash
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'posted', $9, $10, $11, $12, $13)`,
		uuid.Must(uuid.NewV7()), idempotencyKey, typeID,
		nullUUID(ev.TenantID), systemAccount, payloadBytes, amount, currency,
		ev.EventTime, nullString(ev.Correlation), nullString(ev.Causation),
		recordHash, prevHash,
	)
	return err
}

func (s *EventStore) setTenantRLS(ctx context.Context, tenantID uuid.UUID) error {
	if tenantID != uuid.Nil {
		_, err := s.db.ExecContext(ctx, fmt.Sprintf("SET LOCAL app.current_tenant_id = '%s'", tenantID.String()))
		return err
	}
	return nil
}

func (s *EventStore) GetByAggregateID(ctx context.Context, aggregateID uuid.UUID, fromVersion int64) ([]entity.Event, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT event_type, aggregate_id, version, payload, occurred_at 
		 FROM events.event_store
		 WHERE aggregate_id = $1 AND version >= $2 ORDER BY version ASC`,
		aggregateID.String(), fromVersion)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []entity.Event
	for rows.Next() {
		var eventType, aggID string
		var version int64
		var payloadBytes, metadataBytes []byte
		var occurredAt time.Time
		if err := rows.Scan(&eventType, &aggID, &version, &payloadBytes, &metadataBytes, &occurredAt); err != nil {
			return nil, err
		}
		id, _ := uuid.Parse(aggID)
		var payload map[string]interface{}
		_ = json.Unmarshal(payloadBytes, &payload)
		events = append(events, entity.DomainEvent{
			Type:      eventType,
			AggID:     id,
			EventTime: occurredAt,
			Payload:   payload,
			Version:   version,
		})
	}
	return events, rows.Err()
}

func (s *EventStore) GetAllEvents(ctx context.Context, limit int32, offset int32) ([]entity.Event, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT event_type, aggregate_id, version, payload, occurred_at 
		 FROM events.event_store
		 ORDER BY occurred_at DESC LIMIT $1 OFFSET $2`,
		limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []entity.Event
	for rows.Next() {
		var eventType, aggID string
		var version int64
		var payloadBytes, metadataBytes []byte
		var occurredAt time.Time
		if err := rows.Scan(&eventType, &aggID, &version, &payloadBytes, &metadataBytes, &occurredAt); err != nil {
			return nil, err
		}
		id, _ := uuid.Parse(aggID)
		var payload map[string]interface{}
		_ = json.Unmarshal(payloadBytes, &payload)
		events = append(events, entity.DomainEvent{
			Type:      eventType,
			AggID:     id,
			EventTime: occurredAt,
			Payload:   payload,
			Version:   version,
		})
	}
	return events, rows.Err()
}

func (s *EventStore) GetEventStats(ctx context.Context) (*entity.EventStats, error) {
	var totalEvents, totalAggregates int64
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*), COUNT(DISTINCT aggregate_id) FROM events.event_store`).Scan(&totalEvents, &totalAggregates)
	if err != nil {
		return nil, err
	}

	rows, err := s.db.QueryContext(ctx,
		`SELECT event_type, COUNT(*) FROM events.event_store GROUP BY event_type`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	types := make(map[string]int64)
	for rows.Next() {
		var eventType string
		var count int64
		if err := rows.Scan(&eventType, &count); err != nil {
			return nil, err
		}
		types[eventType] = count
	}

	return &entity.EventStats{
		TotalEvents:     totalEvents,
		TotalAggregates: totalAggregates,
		EventTypes:      types,
	}, rows.Err()
}

func (s *EventStore) GetLatestVersion(ctx context.Context, aggregateID uuid.UUID) (int64, error) {
	var version sql.NullInt64
	row := s.db.QueryRowContext(ctx,
		`SELECT MAX(version) FROM events.event_store WHERE aggregate_id = $1`, aggregateID.String())
	if err := row.Scan(&version); err != nil {
		return 0, err
	}
	if version.Valid {
		return version.Int64, nil
	}
	return 0, nil
}

func (s *EventStore) CheckIdempotency(ctx context.Context, key string) (bool, error) {
	var exists bool
	row := s.db.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM core.idempotency_keys WHERE idempotency_key = $1)`, key)
	err := row.Scan(&exists)
	return exists, err
}

func (s *EventStore) StoreIdempotency(ctx context.Context, tx *sql.Tx, key string) error {
	hashInput := sha256.Sum256([]byte(key))
	requestHash := hex.EncodeToString(hashInput[:])

	res, err := tx.ExecContext(ctx,
		`INSERT INTO core.idempotency_keys (
			idempotency_key, request_type, request_hash, expires_at
		) VALUES ($1, $2, $3, $4)
		ON CONFLICT (idempotency_key) DO NOTHING`,
		key, "event_append", requestHash, time.Now().UTC().Add(24*time.Hour),
	)
	if err != nil {
		return err
	}
	rowsAffected, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rowsAffected == 0 {
		return repository.ErrDuplicateEvent
	}
	return nil
}

func nullUUID(u uuid.UUID) interface{} {
	if u == uuid.Nil {
		return nil
	}
	return u.String()
}

func nullString(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}
