package service

import (
	"context"
	"fmt"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/valueobject"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/common"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/payment"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/session"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/tenant_application"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/infrastructure/observability"
)

type SessionReconstructorClient interface {
	ReconstructSession(ctx context.Context, in *session.ReconstructSessionRequest, opts ...interface{}) (*session.ReconstructSessionResponse, error)
}

type TenantUSSDAppClient interface {
	HandleMenu(ctx context.Context, in *tenant_application.MenuRequest, opts ...interface{}) (*tenant_application.MenuResponse, error)
}

type TenantClientProvider interface {
	GetClient(endpoint string) (tenant_application.TenantUSSDAppClient, error)
	Close()
}

type PaymentEngineClient interface {
	InitiatePayment(ctx context.Context, in *payment.InitiatePaymentRequest, opts ...grpc.CallOption) (*payment.InitiatePaymentResponse, error)
}

type Router struct {
	rateLimiter    RateLimiter
	tenantRepo     repository.TenantRepository
	sessionCli     session.SessionReconstructorClient
	tenantProv     TenantClientProvider
	paymentCli     PaymentEngineClient
	circuitBreaker *CircuitBreaker
}

func NewRouter(
	rateLimiter RateLimiter,
	tenantRepo repository.TenantRepository,
	sessionCli session.SessionReconstructorClient,
	tenantProv TenantClientProvider,
	paymentCli PaymentEngineClient,
	circuitBreaker *CircuitBreaker,
) *Router {
	return &Router{
		rateLimiter:    rateLimiter,
		tenantRepo:     tenantRepo,
		sessionCli:     sessionCli,
		tenantProv:     tenantProv,
		paymentCli:     paymentCli,
		circuitBreaker: circuitBreaker,
	}
}

func (r *Router) RouteRequest(ctx context.Context, req *entity.RouteRequest) (*entity.RouteResponse, error) {
	if _, err := valueobject.NewPhoneNumber(req.PhoneNumber); err != nil {
		return nil, fmt.Errorf("invalid phone number: %w", err)
	}

	if !r.rateLimiter.Allow(ctx, req.PhoneNumber, 60) {
		observability.RecordRateLimitHit()
		return nil, fmt.Errorf("rate limit exceeded for phone number")
	}

	tenant, err := r.tenantRepo.GetByServiceCode(ctx, req.ServiceCode)
	if err != nil {
		return nil, fmt.Errorf("tenant not found: %w", err)
	}

	if !tenant.Active {
		return nil, fmt.Errorf("tenant inactive")
	}

	limit := int(tenant.RateLimitRPS)
	if limit == 0 {
		limit = 100
	}
	if !r.rateLimiter.AllowTenant(ctx, tenant.ID.String(), limit) {
		return nil, fmt.Errorf("rate limit exceeded for tenant")
	}

	sessionState, err := structpb.NewStruct(req.SessionState)
	if err != nil {
		return nil, err
	}

	sessCtx := &common.SessionContext{
		SessionId:   req.SessionID,
		PhoneNumber: req.PhoneNumber,
		TenantId:    tenant.ID.String(),
		StartedAt:   timestamppb.New(time.Now()),
	}

	sessResp, err := r.sessionCli.ReconstructSession(ctx, &session.ReconstructSessionRequest{
		SessionId:       req.SessionID,
		TenantId:        tenant.ID.String(),
		MaxEvents:       1000,
		IncludeMetadata: false,
		IncludePayload:  true,
		Tracing:         nil,
		RequestMetadata: nil,
	})
	if err != nil {
		return nil, fmt.Errorf("session reconstruction failed: %w", err)
	}

	if sessResp.GetState() != nil {
		sessionState = sessResp.GetState()
	}

	tenantCli, err := r.tenantProv.GetClient(tenant.Endpoint)
	if err != nil {
		return nil, fmt.Errorf("tenant client connection failed: %w", err)
	}

	menuResp, err := tenantCli.HandleMenu(ctx, &tenant_application.MenuRequest{
		SessionId:      req.SessionID,
		PhoneNumber:    req.PhoneNumber,
		UserInput:      req.UserInput,
		CurrentMenu:    req.CurrentMenu,
		SessionState:   sessionState,
		TenantId:       tenant.ID.String(),
		SessionContext: sessCtx,
	})
	if err != nil {
		return nil, fmt.Errorf("tenant handle menu failed: %w", err)
	}

	updatedState := map[string]interface{}{}
	if menuResp.GetUpdatedState() != nil {
		updatedState = menuResp.GetUpdatedState().AsMap()
	}

	resp := &entity.RouteResponse{
		MenuText:     menuResp.GetMessage(),
		NextMenu:     menuResp.GetNextMenu(),
		UpdatedState: updatedState,
		EndSession:   menuResp.GetType() == tenant_application.MenuResponse_END,
	}

	for _, opt := range menuResp.GetOptions() {
		resp.Options = append(resp.Options, opt.GetLabel())
	}

	// Handle payment request from tenant
	if payReq := menuResp.GetPayment(); payReq != nil && r.paymentCli != nil {
		if r.circuitBreaker != nil && !r.circuitBreaker.Allow() {
			resp.PaymentInitiated = false
			resp.PaymentStatus = "CIRCUIT_OPEN"
			resp.MenuText = resp.MenuText + "\n(Payment temporarily unavailable)"
		} else {
			provider := parseProvider(payReq.GetProvider())
			phone := payReq.GetPhoneNumber()
			if phone == "" {
				phone = req.PhoneNumber
			}

			initResp, payErr := r.paymentCli.InitiatePayment(ctx, &payment.InitiatePaymentRequest{
				PaymentId:   "",
				TenantId:    tenant.ID.String(),
				SessionId:   req.SessionID,
				Provider:    provider,
				PhoneNumber: phone,
				Amount:      payReq.GetAmount(),
				Reference:   payReq.GetReference(),
				Description: payReq.GetDescription(),
				IdempotencyKey: &common.IdempotencyKey{
					Value: fmt.Sprintf("%s-%s", req.SessionID, payReq.GetReference()),
				},
			})
			if payErr != nil {
				if r.circuitBreaker != nil {
					r.circuitBreaker.RecordFailure()
				}
				resp.PaymentInitiated = false
				resp.PaymentStatus = "FAILED"
				resp.MenuText = resp.MenuText + "\n(Payment initiation failed)"
			} else {
				if r.circuitBreaker != nil {
					r.circuitBreaker.RecordSuccess()
				}
				resp.PaymentInitiated = true
				resp.PaymentID = initResp.GetPaymentId()
				resp.ProviderReference = initResp.GetProviderReference()
				resp.PaymentStatus = initResp.GetStatus().String()
			}
		}
	}

	return resp, nil
}

func parseProvider(provider string) payment.MobileMoneyProvider {
	switch provider {
	case "ecocash":
		return payment.MobileMoneyProvider_ECOCASH
	case "onemoney":
		return payment.MobileMoneyProvider_ONEMONEY
	case "telecash":
		return payment.MobileMoneyProvider_TELECASH
	case "mtn_momo":
		return payment.MobileMoneyProvider_MTN_MOMO
	case "airtel_money":
		return payment.MobileMoneyProvider_AIRTEL_MONEY
	default:
		return payment.MobileMoneyProvider_PROVIDER_UNSPECIFIED
	}
}
