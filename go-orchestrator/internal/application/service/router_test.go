package service

import (
	"context"
	"testing"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/aggregate"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/session"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/tenant_application"
)

type mockRateLimiter struct {
	mock.Mock
}

func (m *mockRateLimiter) Allow(ctx context.Context, key string, limit int) bool {
	args := m.Called(ctx, key, limit)
	return args.Bool(0)
}

func (m *mockRateLimiter) AllowTenant(ctx context.Context, tenantID string, limit int) bool {
	args := m.Called(ctx, tenantID, limit)
	return args.Bool(0)
}

type mockTenantRepo struct {
	mock.Mock
}

func (m *mockTenantRepo) GetByServiceCode(ctx context.Context, code string) (*aggregate.Tenant, error) {
	args := m.Called(ctx, code)
	if t, ok := args.Get(0).(*aggregate.Tenant); ok {
		return t, args.Error(1)
	}
	return nil, args.Error(1)
}

func (m *mockTenantRepo) GetByID(ctx context.Context, id uuid.UUID) (*aggregate.Tenant, error) {
	args := m.Called(ctx, id)
	if t, ok := args.Get(0).(*aggregate.Tenant); ok {
		return t, args.Error(1)
	}
	return nil, args.Error(1)
}

func (m *mockTenantRepo) Save(ctx context.Context, tenant *aggregate.Tenant) error {
	args := m.Called(ctx, tenant)
	return args.Error(0)
}

func (m *mockTenantRepo) List(ctx context.Context) ([]aggregate.Tenant, error) {
	args := m.Called(ctx)
	if ts, ok := args.Get(0).([]aggregate.Tenant); ok {
		return ts, args.Error(1)
	}
	return nil, args.Error(1)
}

type mockSessionClient struct {
	mock.Mock
}

func (m *mockSessionClient) ReconstructSession(ctx context.Context, in *session.ReconstructSessionRequest, opts ...grpc.CallOption) (*session.ReconstructSessionResponse, error) {
	args := m.Called(ctx, in)
	if resp, ok := args.Get(0).(*session.ReconstructSessionResponse); ok {
		return resp, args.Error(1)
	}
	return nil, args.Error(1)
}

func (m *mockSessionClient) ReconstructSessions(ctx context.Context, opts ...grpc.CallOption) (grpc.BidiStreamingClient[session.ReconstructSessionRequest, session.ReconstructSessionResponse], error) {
	return nil, nil
}

func (m *mockSessionClient) GetSessionEvents(ctx context.Context, in *session.GetSessionEventsRequest, opts ...grpc.CallOption) (grpc.ServerStreamingClient[session.SessionEvent], error) {
	return nil, nil
}

func (m *mockSessionClient) VerifySessionIntegrity(ctx context.Context, in *session.VerifySessionRequest, opts ...grpc.CallOption) (*session.VerifySessionResponse, error) {
	return nil, nil
}

func (m *mockSessionClient) GetIntegrityProof(ctx context.Context, in *session.GetIntegrityProofRequest, opts ...grpc.CallOption) (*session.IntegrityProof, error) {
	return nil, nil
}

func (m *mockSessionClient) CreateCheckpoint(ctx context.Context, in *session.CreateCheckpointRequest, opts ...grpc.CallOption) (*session.CreateCheckpointResponse, error) {
	return nil, nil
}

func (m *mockSessionClient) RestoreCheckpoint(ctx context.Context, in *session.RestoreCheckpointRequest, opts ...grpc.CallOption) (*session.RestoreCheckpointResponse, error) {
	return nil, nil
}

func (m *mockSessionClient) ListActiveSessions(ctx context.Context, in *session.ListActiveSessionsRequest, opts ...grpc.CallOption) (*session.ListActiveSessionsResponse, error) {
	return nil, nil
}

func (m *mockSessionClient) SearchSessions(ctx context.Context, in *session.SearchSessionsRequest, opts ...grpc.CallOption) (*session.SearchSessionsResponse, error) {
	return nil, nil
}

func (m *mockSessionClient) GetConcurrentSessions(ctx context.Context, in *session.GetConcurrentSessionsRequest, opts ...grpc.CallOption) (*session.GetConcurrentSessionsResponse, error) {
	return nil, nil
}

func (m *mockSessionClient) MergeSessions(ctx context.Context, in *session.MergeSessionsRequest, opts ...grpc.CallOption) (*session.MergeSessionsResponse, error) {
	return nil, nil
}

func (m *mockSessionClient) GetSessionMetrics(ctx context.Context, in *session.GetSessionMetricsRequest, opts ...grpc.CallOption) (*session.GetSessionMetricsResponse, error) {
	return nil, nil
}

func (m *mockSessionClient) InvalidateCache(ctx context.Context, in *session.InvalidateCacheRequest, opts ...grpc.CallOption) (*common.Empty, error) {
	return nil, nil
}

func (m *mockSessionClient) Health(ctx context.Context, in *common.HealthRequest, opts ...grpc.CallOption) (*common.HealthResponse, error) {
	return nil, nil
}

type mockTenantClient struct {
	mock.Mock
}

func (m *mockTenantClient) HandleMenu(ctx context.Context, in *tenant_application.MenuRequest, opts ...grpc.CallOption) (*tenant_application.MenuResponse, error) {
	args := m.Called(ctx, in)
	if resp, ok := args.Get(0).(*tenant_application.MenuResponse); ok {
		return resp, args.Error(1)
	}
	return nil, args.Error(1)
}

func (m *mockTenantClient) HandlePaymentConfirmation(ctx context.Context, in *tenant_application.PaymentConfirmationRequest, opts ...grpc.CallOption) (*tenant_application.MenuResponse, error) {
	return nil, nil
}

func (m *mockTenantClient) HandleError(ctx context.Context, in *tenant_application.ErrorContextRequest, opts ...grpc.CallOption) (*tenant_application.MenuResponse, error) {
	return nil, nil
}

func (m *mockTenantClient) GetTenantConfig(ctx context.Context, in *tenant_application.GetTenantConfigRequest, opts ...grpc.CallOption) (*tenant_application.TenantAppConfig, error) {
	return nil, nil
}

func (m *mockTenantClient) Health(ctx context.Context, in *common.HealthRequest, opts ...grpc.CallOption) (*common.HealthResponse, error) {
	return nil, nil
}

type mockTenantProvider struct {
	mock.Mock
}

func (m *mockTenantProvider) GetClient(endpoint string) (tenant_application.TenantUSSDAppClient, error) {
	args := m.Called(endpoint)
	if cli, ok := args.Get(0).(tenant_application.TenantUSSDAppClient); ok {
		return cli, args.Error(1)
	}
	return nil, args.Error(1)
}

func (m *mockTenantProvider) Close() {}

func TestRouter_RouteRequest_InvalidPhone(t *testing.T) {
	r := NewRouter(nil, nil, nil, nil, nil)
	_, err := r.RouteRequest(context.Background(), &entity.RouteRequest{
		PhoneNumber: "invalid",
	})
	assert.Error(t, err)
}

func TestRouter_RouteRequest_RateLimited(t *testing.T) {
	rl := new(mockRateLimiter)
	rl.On("Allow", mock.Anything, "2637123456789", 60).Return(false)

	r := NewRouter(rl, nil, nil, nil, nil)
	_, err := r.RouteRequest(context.Background(), &entity.RouteRequest{
		PhoneNumber: "2637123456789",
	})
	assert.Error(t, err)
}

func TestRouter_RouteRequest_TenantNotFound(t *testing.T) {
	rl := new(mockRateLimiter)
	repo := new(mockTenantRepo)

	rl.On("Allow", mock.Anything, "2637123456789", 60).Return(true)
	repo.On("GetByServiceCode", mock.Anything, "*123#").Return(nil, repository.ErrNotFound)

	r := NewRouter(rl, repo, nil, nil, nil)
	_, err := r.RouteRequest(context.Background(), &entity.RouteRequest{
		PhoneNumber: "2637123456789",
		ServiceCode: "*123#",
	})
	assert.Error(t, err)
}

func TestRouter_RouteRequest_Success(t *testing.T) {
	rl := new(mockRateLimiter)
	tenantRepo := new(mockTenantRepo)
	sessionCli := new(mockSessionClient)
	tenantProv := new(mockTenantProvider)
	tenantCli := new(mockTenantClient)

	tenantID := uuid.Must(uuid.NewV7())

	rl.On("Allow", mock.Anything, "2637123456789", 60).Return(true)
	rl.On("AllowTenant", mock.Anything, tenantID.String(), 10).Return(true)
	tenantRepo.On("GetByServiceCode", mock.Anything, "*123#").Return(&aggregate.Tenant{
		ID:           tenantID,
		ServiceCode:  "*123#",
		Endpoint:     "localhost:50053",
		Active:       true,
		RateLimitRPS: 10,
	}, nil)

	state, _ := structpb.NewStruct(map[string]interface{}{"foo": "bar"})
	sessionCli.On("ReconstructSession", mock.Anything, mock.Anything).Return(&session.ReconstructSessionResponse{
		State: state,
	}, nil)

	tenantProv.On("GetClient", "localhost:50053").Return(tenantCli, nil)

	respState, _ := structpb.NewStruct(map[string]interface{}{"step": 2})
	tenantCli.On("HandleMenu", mock.Anything, mock.Anything).Return(&tenant_application.MenuResponse{
		Type:         tenant_application.MenuResponse_CON,
		Message:      "Welcome",
		NextMenu:     "menu_2",
		UpdatedState: respState,
		Options: []*tenant_application.MenuOption{
			{Label: "Option 1"},
		},
	}, nil)

	router := NewRouter(rl, tenantRepo, sessionCli, tenantProv, nil)
	resp, err := router.RouteRequest(context.Background(), &entity.RouteRequest{
		SessionID:   "sess-1",
		PhoneNumber: "2637123456789",
		UserInput:   "1",
		CurrentMenu: "menu_1",
		ServiceCode: "*123#",
	})

	assert.NoError(t, err)
	assert.Equal(t, "Welcome", resp.MenuText)
	assert.Equal(t, "menu_2", resp.NextMenu)
	assert.False(t, resp.EndSession)
	assert.Len(t, resp.Options, 1)
}
