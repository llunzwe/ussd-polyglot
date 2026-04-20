package service

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/common"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/payment"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/session"
)

// ServiceStepHandler executes saga steps by calling real gRPC services.
type ServiceStepHandler struct {
	paymentCli payment.PaymentEngineClient
	sessionCli session.SessionReconstructorClient
}

// NewServiceStepHandler creates a step handler wired to real service clients.
func NewServiceStepHandler(paymentCli payment.PaymentEngineClient, sessionCli session.SessionReconstructorClient) *ServiceStepHandler {
	return &ServiceStepHandler{
		paymentCli: paymentCli,
		sessionCli: sessionCli,
	}
}

func (h *ServiceStepHandler) Execute(ctx context.Context, step entity.SagaStep) (map[string]interface{}, error) {
	slog.Info("executing saga step",
		slog.String("service", step.Service),
		slog.String("action", step.Action),
		slog.Int("step_number", step.StepNumber),
	)

	switch step.Service {
	case "payment":
		return h.executePaymentStep(ctx, step)
	case "session":
		return h.executeSessionStep(ctx, step)
	default:
		slog.Warn("unknown saga step service", slog.String("service", step.Service))
		return map[string]interface{}{"success": true}, nil
	}
}

func (h *ServiceStepHandler) Compensate(ctx context.Context, step entity.SagaStep) error {
	slog.Info("compensating saga step",
		slog.String("service", step.Service),
		slog.String("compensation_action", step.CompensationAction),
		slog.Int("step_number", step.StepNumber),
	)

	switch step.Service {
	case "payment":
		return h.compensatePaymentStep(ctx, step)
	default:
		return nil
	}
}

func (h *ServiceStepHandler) executePaymentStep(ctx context.Context, step entity.SagaStep) (map[string]interface{}, error) {
	switch step.Action {
	case "InitiatePayment":
		amountCents := int64(0)
		if v, ok := step.Input["amount_cents"]; ok {
			amountCents = int64(v.(float64))
		}
		req := &payment.InitiatePaymentRequest{
			TenantId: step.Input["tenant_id"].(string),
			SessionId: step.Input["session_id"].(string),
			Provider: parseProviderInput(step.Input["provider"]),
			PhoneNumber: step.Input["phone_number"].(string),
			Amount: &common.Money{AmountCents: amountCents, CurrencyCode: "USD"},
			Reference: step.Input["reference"].(string),
			IdempotencyKey: &common.IdempotencyKey{Value: step.Input["idempotency_key"].(string)},
		}
		resp, err := h.paymentCli.InitiatePayment(ctx, req)
		if err != nil {
			return nil, fmt.Errorf("payment initiation failed: %w", err)
		}
		return map[string]interface{}{
			"success":           true,
			"payment_id":        resp.GetPaymentId(),
			"provider_reference": resp.GetProviderReference(),
			"status":            resp.GetStatus().String(),
		}, nil
	case "GetPaymentStatus":
		req := &payment.GetPaymentStatusRequest{
			PaymentId: step.Input["payment_id"].(string),
		}
		resp, err := h.paymentCli.GetPaymentStatus(ctx, req)
		if err != nil {
			return nil, err
		}
		return map[string]interface{}{
			"success": true,
			"status":  resp.GetStatus().String(),
		}, nil
	default:
		return map[string]interface{}{"success": true}, nil
	}
}

func (h *ServiceStepHandler) compensatePaymentStep(ctx context.Context, step entity.SagaStep) error {
	paymentID, ok := step.Output["payment_id"].(string)
	if !ok || paymentID == "" {
		slog.Warn("no payment_id to compensate", slog.String("step", step.Action))
		return nil
	}

	req := &payment.RefundPaymentRequest{
		OriginalPaymentId: paymentID,
		Reason:            fmt.Sprintf("saga compensation for step %d", step.StepNumber),
	}
	_, err := h.paymentCli.RefundPayment(ctx, req)
	if err != nil {
		return fmt.Errorf("refund failed: %w", err)
	}
	return nil
}

func (h *ServiceStepHandler) executeSessionStep(ctx context.Context, step entity.SagaStep) (map[string]interface{}, error) {
	switch step.Action {
	case "ReconstructSession":
		req := &session.ReconstructSessionRequest{
			SessionId: step.Input["session_id"].(string),
			TenantId:  step.Input["tenant_id"].(string),
			MaxEvents: 1000,
		}
		resp, err := h.sessionCli.ReconstructSession(ctx, req)
		if err != nil {
			return nil, err
		}
		return map[string]interface{}{
			"success": true,
			"state":   resp.GetState(),
		}, nil
	default:
		return map[string]interface{}{"success": true}, nil
	}
}

func parseProviderInput(v interface{}) payment.MobileMoneyProvider {
	s, ok := v.(string)
	if !ok {
		return payment.MobileMoneyProvider_PROVIDER_UNSPECIFIED
	}
	switch s {
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
