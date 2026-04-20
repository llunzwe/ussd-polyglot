package postgres

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/aggregate"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type TenantRepository struct {
	db *sql.DB
}

func NewTenantRepository(db *sql.DB) *TenantRepository {
	return &TenantRepository{db: db}
}

func (r *TenantRepository) GetByServiceCode(ctx context.Context, code string) (*aggregate.Tenant, error) {
	row := r.db.QueryRowContext(ctx,
		`SELECT application_id, app_name, app_code, 
		        COALESCE(metadata->>'endpoint', '') as endpoint,
		        (status = 'active') as active,
		        max_transactions_per_minute,
		        COALESCE(metadata->>'config', '{}') as configuration
		 FROM app.application_registry 
		 WHERE app_code = $1 OR metadata->>'service_code' = $1`,
		code)
	return r.scanTenant(row)
}

func (r *TenantRepository) GetByID(ctx context.Context, id uuid.UUID) (*aggregate.Tenant, error) {
	row := r.db.QueryRowContext(ctx,
		`SELECT application_id, app_name, app_code, 
		        COALESCE(metadata->>'endpoint', '') as endpoint,
		        (status = 'active') as active,
		        max_transactions_per_minute,
		        COALESCE(metadata->>'config', '{}') as configuration
		 FROM app.application_registry 
		 WHERE application_id = $1`,
		id.String())
	return r.scanTenant(row)
}

func (r *TenantRepository) Save(ctx context.Context, tenant *aggregate.Tenant) error {
	metadata := map[string]string{}
	if tenant.Endpoint != "" {
		metadata["endpoint"] = tenant.Endpoint
	}
	if len(tenant.Config) > 0 {
		configBytes, _ := json.Marshal(tenant.Config)
		metadata["config"] = string(configBytes)
	}
	metadataBytes, _ := json.Marshal(metadata)

	status := "suspended"
	if tenant.Active {
		status = "active"
	}

	systemAccount := uuid.MustParse("00000000-0000-0000-0000-000000000001")

	_, err := r.db.ExecContext(ctx,
		`INSERT INTO app.application_registry (
			application_id, app_name, app_code, metadata, status,
			max_transactions_per_minute, created_at, updated_at,
			created_by, updated_by, ledger_tenant_id, default_owner_account_id
		) VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW(), $7, $8, $9, $10)
		ON CONFLICT (application_id) DO UPDATE SET
			app_name = EXCLUDED.app_name,
			app_code = EXCLUDED.app_code,
			metadata = EXCLUDED.metadata,
			status = EXCLUDED.status,
			max_transactions_per_minute = EXCLUDED.max_transactions_per_minute,
			updated_at = NOW(),
			updated_by = EXCLUDED.updated_by`,
		tenant.ID, tenant.Name, tenant.ServiceCode, metadataBytes, status,
		tenant.RateLimitRPS, systemAccount, systemAccount, tenant.ID, systemAccount)
	return err
}

func (r *TenantRepository) List(ctx context.Context) ([]aggregate.Tenant, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT application_id, app_name, app_code, 
		        COALESCE(metadata->>'endpoint', '') as endpoint,
		        (status = 'active') as active,
		        max_transactions_per_minute,
		        COALESCE(metadata->>'config', '{}') as configuration
		 FROM app.application_registry`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tenants []aggregate.Tenant
	for rows.Next() {
		t, err := r.scanTenant(rows)
		if err != nil {
			return nil, err
		}
		tenants = append(tenants, *t)
	}
	return tenants, rows.Err()
}

func (r *TenantRepository) scanTenant(scanner interface {
	Scan(dest ...interface{}) error
}) (*aggregate.Tenant, error) {
	var t aggregate.Tenant
	var idStr string
	var configStr string
	err := scanner.Scan(&idStr, &t.Name, &t.ServiceCode, &t.Endpoint, &t.Active, &t.RateLimitRPS, &configStr)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, repository.ErrNotFound
		}
		return nil, err
	}
	t.ID, _ = uuid.Parse(idStr)
	if configStr != "" && configStr != "{}" {
		_ = json.Unmarshal([]byte(configStr), &t.Config)
	}
	if t.Config == nil {
		t.Config = map[string]string{}
	}
	return &t, nil
}
