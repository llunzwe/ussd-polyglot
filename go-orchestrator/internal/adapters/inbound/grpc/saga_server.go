package grpc

import (
	"context"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/application/service"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/orchestrator"
)

type sagaServer struct {
	engine *service.SagaEngine
}

func newSagaServer(engine *service.SagaEngine) sagaServer {
	return sagaServer{engine: engine}
}

func (s *sagaServer) ExecuteSaga(ctx context.Context, req *orchestrator.ExecuteSagaRequest) (*orchestrator.ExecuteSagaResponse, error) {
	sagaID := req.GetSagaId()
	if sagaID == "" {
		sagaID = uuid.Must(uuid.NewV7()).String()
	}

	tenantID, err := uuid.Parse(req.GetTenantId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid tenant_id")
	}

	steps := make([]entity.SagaStep, 0, len(req.GetSteps()))
	for i, ps := range req.GetSteps() {
		step := entity.SagaStep{
			ID:                 uuid.Must(uuid.NewV7()),
			StepNumber:         i + 1,
			Service:            ps.GetService(),
			Action:             ps.GetAction(),
			Status:             "pending",
			CompensationAction: ps.GetCompensationAction(),
		}
		if ps.GetPayload() != nil {
			step.Input = ps.GetPayload().AsMap()
		}
		steps = append(steps, step)
	}

	saga := &entity.Saga{
		ID:         uuid.Must(uuid.Parse(sagaID)),
		TenantID:   tenantID,
		Status:     "pending",
		TotalSteps: len(steps),
		Steps:      steps,
		CreatedAt:  time.Now().UTC(),
	}

	if err := s.engine.StartSaga(ctx, saga); err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}

	return &orchestrator.ExecuteSagaResponse{
		SagaId: sagaID,
		Status: orchestrator.ExecuteSagaResponse_PENDING,
	}, nil
}

func (s *sagaServer) GetSagaStatus(ctx context.Context, req *orchestrator.GetSagaStatusRequest) (*orchestrator.SagaStatusResponse, error) {
	id, err := uuid.Parse(req.GetSagaId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid saga_id")
	}

	saga, err := s.engine.GetSaga(ctx, id)
	if err != nil {
		return nil, mapError(err)
	}

	return &orchestrator.SagaStatusResponse{
		SagaId:      saga.ID.String(),
		Status:      statusToProto(saga.Status),
		CurrentStep: int32(saga.CurrentStep),
		TotalSteps:  int32(saga.TotalSteps),
	}, nil
}

func (s *sagaServer) CancelSaga(ctx context.Context, req *orchestrator.CancelSagaRequest) (*orchestrator.SagaStatusResponse, error) {
	id, err := uuid.Parse(req.GetSagaId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid saga_id")
	}

	if err := s.engine.CancelSaga(ctx, id); err != nil {
		return nil, mapError(err)
	}

	return &orchestrator.SagaStatusResponse{
		SagaId: req.GetSagaId(),
		Status: orchestrator.ExecuteSagaResponse_CANCELLED,
	}, nil
}

func statusToProto(status string) orchestrator.ExecuteSagaResponse_SagaStatus {
	switch status {
	case "pending":
		return orchestrator.ExecuteSagaResponse_PENDING
	case "running":
		return orchestrator.ExecuteSagaResponse_RUNNING
	case "completed":
		return orchestrator.ExecuteSagaResponse_COMPLETED
	case "compensating":
		return orchestrator.ExecuteSagaResponse_COMPENSATING
	case "compensated":
		return orchestrator.ExecuteSagaResponse_COMPENSATED
	case "failed":
		return orchestrator.ExecuteSagaResponse_FAILED
	case "cancelled":
		return orchestrator.ExecuteSagaResponse_CANCELLED
	default:
		return orchestrator.ExecuteSagaResponse_PENDING
	}
}
