package grpc

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/application/command"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/application/service"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/common"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/orchestrator"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/infrastructure/observability"
)

type Server struct {
	orchestrator.UnimplementedOrchestratorServer
	sagaServer
	rateLimitServer
	router                *service.Router
	appendEventHandler    *command.AppendEventHandler
	createSessionHandler  *command.CreateSessionHandler
	registerTenantHandler *command.RegisterTenantHandler
	eventRepo             repository.EventRepository
	tenantRepo            repository.TenantRepository
	circuitBreaker        *service.CircuitBreaker
}

func (s *Server) ExecuteSaga(ctx context.Context, req *orchestrator.ExecuteSagaRequest) (*orchestrator.ExecuteSagaResponse, error) {
	return s.sagaServer.ExecuteSaga(ctx, req)
}

func (s *Server) GetSagaStatus(ctx context.Context, req *orchestrator.GetSagaStatusRequest) (*orchestrator.SagaStatusResponse, error) {
	return s.sagaServer.GetSagaStatus(ctx, req)
}

func (s *Server) CancelSaga(ctx context.Context, req *orchestrator.CancelSagaRequest) (*orchestrator.SagaStatusResponse, error) {
	return s.sagaServer.CancelSaga(ctx, req)
}

func (s *Server) GetRateLimitStatus(ctx context.Context, req *orchestrator.GetRateLimitStatusRequest) (*common.RateLimitStatus, error) {
	return s.rateLimitServer.GetRateLimitStatus(ctx, req)
}

func (s *Server) UpdateRateLimitPolicy(ctx context.Context, req *orchestrator.UpdateRateLimitPolicyRequest) (*orchestrator.RateLimitPolicy, error) {
	return s.rateLimitServer.UpdateRateLimitPolicy(ctx, req)
}

func NewServer(
	router *service.Router,
	appendEventHandler *command.AppendEventHandler,
	createSessionHandler *command.CreateSessionHandler,
	registerTenantHandler *command.RegisterTenantHandler,
	eventRepo repository.EventRepository,
	tenantRepo repository.TenantRepository,
	sagaEng *service.SagaEngine,
	rateLimSvc *service.RateLimitService,
	circuitBreaker *service.CircuitBreaker,
) *Server {
	return &Server{
		sagaServer:            newSagaServer(sagaEng),
		rateLimitServer:       newRateLimitServer(rateLimSvc),
		router:                router,
		appendEventHandler:    appendEventHandler,
		createSessionHandler:  createSessionHandler,
		registerTenantHandler: registerTenantHandler,
		eventRepo:             eventRepo,
		tenantRepo:            tenantRepo,
		circuitBreaker:        circuitBreaker,
	}
}

func (s *Server) ForwardUSSD(ctx context.Context, req *orchestrator.ForwardUSSDRequest) (*orchestrator.ForwardUSSDResponse, error) {
	start := time.Now()
	sessionState := req.GetSessionState()
	if sessionState == nil {
		sessionState = &structpb.Struct{}
	}

	traceID := observability.ExtractTraceContext(ctx)
	sessionID := req.GetSession().GetSessionId()

	routeReq := &entity.RouteRequest{
		SessionID:    sessionID,
		PhoneNumber:  req.GetSession().GetPhoneNumber(),
		UserInput:    req.GetUserInput(),
		CurrentMenu:  req.GetCurrentMenu(),
		ServiceCode:  req.GetServiceCode(),
		SessionState: sessionState.AsMap(),
		TenantID:     req.GetSession().GetTenantId(),
	}

	routeResp, err := s.router.RouteRequest(ctx, routeReq)
	statusLabel := "success"
	if err != nil {
		statusLabel = "error"
		slog.Error("ForwardUSSD failed",
			slog.String("trace_id", traceID),
			slog.String("session_id", sessionID),
			slog.String("error", err.Error()),
		)
		observability.RecordForwardUSSD(statusLabel)
		return nil, mapError(err)
	}

	// Append SessionProcessed event to immutable ledger
	sessionUUID, _ := uuid.Parse(sessionID)
	tenantUUID, _ := uuid.Parse(req.GetSession().GetTenantId())
	if sessionUUID != uuid.Nil {
		_, appendErr := s.appendEventHandler.Handle(ctx, command.AppendEventCommand{
			EventType:     "SessionProcessed",
			AggregateType: "USR_SESSION",
			AggregateID:   sessionUUID,
			Payload: map[string]interface{}{
				"session_id":   sessionID,
				"phone_number": req.GetSession().GetPhoneNumber(),
				"service_code": req.GetServiceCode(),
				"user_input":   req.GetUserInput(),
				"current_menu": req.GetCurrentMenu(),
				"next_menu":    routeResp.NextMenu,
				"end_session":  routeResp.EndSession,
			},
			IdempotencyKey: fmt.Sprintf("sess-%s-%d", sessionID, time.Now().Unix()),
			TenantID:       tenantUUID,
			SessionID:      sessionUUID,
			CorrelationID:  traceID,
		})
		if appendErr != nil {
			slog.Error("failed to append SessionProcessed event",
				slog.String("trace_id", traceID),
				slog.String("error", appendErr.Error()),
			)
		}

		// Append PaymentInitiated event if payment was triggered
		if routeResp.PaymentInitiated {
			_, appendErr = s.appendEventHandler.Handle(ctx, command.AppendEventCommand{
				EventType:     "PaymentInitiated",
				AggregateType: "PAYMENT",
				AggregateID:   sessionUUID,
				Payload: map[string]interface{}{
					"session_id":         sessionID,
					"payment_id":         routeResp.PaymentID,
					"provider_reference": routeResp.ProviderReference,
					"payment_status":     routeResp.PaymentStatus,
				},
				IdempotencyKey: fmt.Sprintf("pay-%s-%s", sessionID, routeResp.PaymentID),
				TenantID:       tenantUUID,
				SessionID:      sessionUUID,
				CorrelationID:  traceID,
			})
			if appendErr != nil {
				slog.Error("failed to append PaymentInitiated event",
					slog.String("trace_id", traceID),
					slog.String("error", appendErr.Error()),
				)
			}
		}
	}

	duration := time.Since(start).Seconds()
	observability.RecordForwardUSSD(statusLabel)
	observability.RecordSessionReconstruct(statusLabel, duration)
	observability.RecordTenantRequest(req.GetSession().GetTenantId(), duration)

	slog.Info("ForwardUSSD completed",
		slog.String("trace_id", traceID),
		slog.String("session_id", sessionID),
		slog.Float64("duration_seconds", duration),
	)

	updatedState, _ := structpb.NewStruct(routeResp.UpdatedState)
	respType := orchestrator.ForwardUSSDResponse_CON
	if routeResp.EndSession {
		respType = orchestrator.ForwardUSSDResponse_END
	}

	var options []*orchestrator.MenuOption
	for i, opt := range routeResp.Options {
		options = append(options, &orchestrator.MenuOption{
			Id:    fmt.Sprintf("%d", i+1),
			Label: opt,
		})
	}

	return &orchestrator.ForwardUSSDResponse{
		Type:             respType,
		MenuText:         routeResp.MenuText,
		Options:          options,
		NextMenu:         routeResp.NextMenu,
		UpdatedState:     updatedState,
		ProcessingTimeMs: time.Since(start).Milliseconds(),
	}, nil
}

func (s *Server) AppendEvent(ctx context.Context, req *orchestrator.AppendEventRequest) (*orchestrator.AppendEventResponse, error) {
	start := time.Now()
	aggID, err := uuid.Parse(req.GetAggregateId())
	if err != nil {
		observability.RecordAppendEvent("invalid_argument", time.Since(start).Seconds())
		return nil, status.Error(codes.InvalidArgument, "invalid aggregate_id")
	}

	var tenantID uuid.UUID
	if req.GetContext() != nil && req.GetContext().GetTenantId() != "" {
		tenantID, _ = uuid.Parse(req.GetContext().GetTenantId())
	}

	var sessionID uuid.UUID
	if req.GetContext() != nil && req.GetContext().GetSessionId() != "" {
		sessionID, _ = uuid.Parse(req.GetContext().GetSessionId())
	}

	idempotencyKey := ""
	if req.GetIdempotencyKey() != nil {
		idempotencyKey = req.GetIdempotencyKey().GetValue()
	}

	payload := map[string]interface{}{}
	if req.GetPayload() != nil {
		payload = req.GetPayload().AsMap()
	}

	cmd := command.AppendEventCommand{
		EventType:       req.GetEventType(),
		AggregateType:   req.GetAggregateType(),
		AggregateID:     aggID,
		ExpectedVersion: req.GetExpectedVersion(),
		Payload:         payload,
		IdempotencyKey:  idempotencyKey,
		TenantID:        tenantID,
		SessionID:       sessionID,
		CorrelationID:   req.GetCorrelationId(),
		CausationID:     req.GetCausationId(),
	}

	result, err := s.appendEventHandler.Handle(ctx, cmd)
	statusLabel := "success"
	if err != nil {
		statusLabel = "error"
	}
	observability.RecordAppendEvent(statusLabel, time.Since(start).Seconds())

	traceID := observability.ExtractTraceContext(ctx)
	if err != nil {
		slog.Error("AppendEvent failed",
			slog.String("trace_id", traceID),
			slog.String("aggregate_id", aggID.String()),
			slog.String("error", err.Error()),
		)
		return nil, mapError(err)
	}

	slog.Info("AppendEvent completed",
		slog.String("trace_id", traceID),
		slog.String("aggregate_id", aggID.String()),
		slog.Int64("version", result.Version),
	)

	return &orchestrator.AppendEventResponse{
		EventId:      result.EventID,
		Version:      result.Version,
		RecordedAt:   timestamppb.New(result.RecordedAt),
		RecordHash:   result.RecordHash,
		PreviousHash: result.PreviousHash,
		WasDuplicate: false,
	}, nil
}

func (s *Server) AppendEventsBatch(ctx context.Context, req *orchestrator.AppendEventsBatchRequest) (*orchestrator.AppendEventsBatchResponse, error) {
	var results []*orchestrator.AppendEventResponse
	for _, ev := range req.GetEvents() {
		aggID, err := uuid.Parse(ev.GetAggregateId())
		if err != nil {
			return nil, status.Error(codes.InvalidArgument, "invalid aggregate_id")
		}
		var tenantID, sessionID uuid.UUID
		if ev.GetContext() != nil {
			tenantID, _ = uuid.Parse(ev.GetContext().GetTenantId())
			sessionID, _ = uuid.Parse(ev.GetContext().GetSessionId())
		}

		result, err := s.appendEventHandler.Handle(ctx, command.AppendEventCommand{
			EventType:       ev.GetEventType(),
			AggregateType:   ev.GetAggregateType(),
			AggregateID:     aggID,
			ExpectedVersion: ev.GetExpectedVersion(),
			Payload:         ev.GetPayload().AsMap(),
			IdempotencyKey:  ev.GetIdempotencyKey().GetValue(),
			TenantID:        tenantID,
			SessionID:       sessionID,
			CorrelationID:   ev.GetCorrelationId(),
			CausationID:     ev.GetCausationId(),
		})
		if err != nil {
			return nil, mapError(err)
		}

		results = append(results, &orchestrator.AppendEventResponse{
			EventId:      result.EventID,
			Version:      result.Version,
			RecordedAt:   timestamppb.New(result.RecordedAt),
			RecordHash:   result.RecordHash,
			PreviousHash: result.PreviousHash,
			WasDuplicate: false,
		})
	}

	return &orchestrator.AppendEventsBatchResponse{
		Responses:    results,
		AllSucceeded: true,
		BatchId:      uuid.Must(uuid.NewV7()).String(),
	}, nil
}

func (s *Server) CreateSession(ctx context.Context, req *orchestrator.CreateSessionRequest) (*orchestrator.CreateSessionResponse, error) {
	tenantID, err := uuid.Parse(req.GetTenantId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid tenant_id")
	}

	result, err := s.createSessionHandler.Handle(ctx, command.CreateSessionCommand{
		PhoneNumber: req.GetPhoneNumber(),
		TenantID:    tenantID,
		ServiceCode: req.GetServiceCode(),
	})
	if err != nil {
		return nil, mapError(err)
	}

	return &orchestrator.CreateSessionResponse{
		SessionId: result.SessionID,
		CreatedAt: timestamppb.New(time.Now().UTC()),
	}, nil
}

func (s *Server) EndSession(ctx context.Context, req *orchestrator.EndSessionRequest) (*orchestrator.EndSessionResponse, error) {
	sessionID, err := uuid.Parse(req.GetSessionId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid session_id")
	}

	var tenantID uuid.UUID
	if req.GetTenantId() != "" {
		tenantID, _ = uuid.Parse(req.GetTenantId())
	}

	cmd := command.AppendEventCommand{
		EventType:   "SessionEnded",
		AggregateID: sessionID,
		TenantID:    tenantID,
		SessionID:   sessionID,
		Payload: map[string]interface{}{
			"reason": req.GetReason(),
		},
	}
	_, err = s.appendEventHandler.Handle(ctx, cmd)
	if err != nil {
		return nil, mapError(err)
	}

	return &orchestrator.EndSessionResponse{
		Success: true,
		EndedAt: timestamppb.New(time.Now().UTC()),
	}, nil
}

func (s *Server) GetSessionState(ctx context.Context, req *orchestrator.GetSessionStateRequest) (*orchestrator.GetSessionStateResponse, error) {
	sessionID, err := uuid.Parse(req.GetSessionId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid session_id")
	}

	events, err := s.eventRepo.GetByAggregateID(ctx, sessionID, 0)
	if err != nil {
		return nil, mapError(err)
	}

	state := map[string]interface{}{}
	for _, ev := range events {
		if de, ok := ev.(entity.DomainEvent); ok && de.Payload != nil {
			for k, v := range de.Payload {
				state[k] = v
			}
		}
	}

	stateStruct, _ := structpb.NewStruct(state)
	return &orchestrator.GetSessionStateResponse{
		SessionId:      req.GetSessionId(),
		State:          stateStruct,
		CurrentVersion: int64(len(events)),
	}, nil
}

func (s *Server) RegisterTenant(ctx context.Context, req *orchestrator.RegisterTenantRequest) (*orchestrator.RegisterTenantResponse, error) {
	id := uuid.Must(uuid.NewV7())
	if req.GetTenantId() != "" {
		parsed, err := uuid.Parse(req.GetTenantId())
		if err == nil {
			id = parsed
		}
	}

	serviceCode := ""
	if len(req.GetServiceCodes()) > 0 {
		serviceCode = req.GetServiceCodes()[0]
	}

	result, err := s.registerTenantHandler.Handle(ctx, command.RegisterTenantCommand{
		ID:           id,
		Name:         req.GetName(),
		ServiceCode:  serviceCode,
		Endpoint:     req.GetEndpoint(),
		RateLimitRPS: req.GetRateLimitRps(),
		Config:       req.GetConfiguration(),
	})
	if err != nil {
		return nil, mapError(err)
	}

	return &orchestrator.RegisterTenantResponse{
		TenantId: result.TenantID,
		ApiKey:   "",
	}, nil
}

func (s *Server) UpdateTenant(ctx context.Context, req *orchestrator.UpdateTenantRequest) (*orchestrator.UpdateTenantResponse, error) {
	id, err := uuid.Parse(req.GetTenantId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid tenant_id")
	}

	tenant, err := s.tenantRepo.GetByID(ctx, id)
	if err != nil {
		return nil, mapError(err)
	}

	if req.Name != nil {
		tenant.Name = *req.Name
	}
	if req.Endpoint != nil {
		tenant.Endpoint = *req.Endpoint
	}
	if req.RateLimitRps != nil {
		tenant.RateLimitRPS = *req.RateLimitRps
	}
	if req.Active != nil {
		tenant.Active = *req.Active
	}
	if req.Configuration != nil {
		tenant.Config = req.Configuration
	}

	if err := s.tenantRepo.Save(ctx, tenant); err != nil {
		return nil, mapError(err)
	}

	configStruct := mapToStruct(tenant.Config)
	return &orchestrator.UpdateTenantResponse{
		Tenant: &orchestrator.Tenant{
			TenantId:      tenant.ID.String(),
			Name:          tenant.Name,
			Endpoint:      tenant.Endpoint,
			Active:        tenant.Active,
			RateLimitRps:  tenant.RateLimitRPS,
			Configuration: configStruct,
			ServiceCodes:  []string{tenant.ServiceCode},
		},
	}, nil
}

func (s *Server) GetTenant(ctx context.Context, req *orchestrator.GetTenantRequest) (*orchestrator.GetTenantResponse, error) {
	id, err := uuid.Parse(req.GetTenantId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid tenant_id")
	}

	tenant, err := s.tenantRepo.GetByID(ctx, id)
	if err != nil {
		return nil, mapError(err)
	}

	configStruct := mapToStruct(tenant.Config)
	return &orchestrator.GetTenantResponse{
		Tenant: &orchestrator.Tenant{
			TenantId:      tenant.ID.String(),
			Name:          tenant.Name,
			Endpoint:      tenant.Endpoint,
			Active:        tenant.Active,
			RateLimitRps:  tenant.RateLimitRPS,
			Configuration: configStruct,
			ServiceCodes:  []string{tenant.ServiceCode},
		},
	}, nil
}

func (s *Server) ListTenants(ctx context.Context, req *orchestrator.ListTenantsRequest) (*orchestrator.ListTenantsResponse, error) {
	tenants, err := s.tenantRepo.List(ctx)
	if err != nil {
		return nil, mapError(err)
	}

	var items []*orchestrator.Tenant
	for _, t := range tenants {
		configStruct := mapToStruct(t.Config)
		items = append(items, &orchestrator.Tenant{
			TenantId:      t.ID.String(),
			Name:          t.Name,
			Endpoint:      t.Endpoint,
			Active:        t.Active,
			RateLimitRps:  t.RateLimitRPS,
			Configuration: configStruct,
			ServiceCodes:  []string{t.ServiceCode},
		})
	}

	return &orchestrator.ListTenantsResponse{
		Tenants: items,
	}, nil
}

func (s *Server) RotateTenantAPIKey(ctx context.Context, req *orchestrator.RotateTenantAPIKeyRequest) (*orchestrator.RotateTenantAPIKeyResponse, error) {
	return &orchestrator.RotateTenantAPIKeyResponse{
		NewApiKey: "",
	}, nil
}

func (s *Server) GetCircuitBreakerStatus(ctx context.Context, req *orchestrator.GetCircuitBreakerStatusRequest) (*orchestrator.CircuitBreakerStatus, error) {
	state := s.circuitBreaker.State()
	var protoState orchestrator.CircuitBreakerStatus_State
	switch state {
	case service.StateClosed:
		protoState = orchestrator.CircuitBreakerStatus_CLOSED
	case service.StateOpen:
		protoState = orchestrator.CircuitBreakerStatus_OPEN
	case service.StateHalfOpen:
		protoState = orchestrator.CircuitBreakerStatus_HALF_OPEN
	}
	return &orchestrator.CircuitBreakerStatus{
		Identifier: req.GetRouteId(),
		State:      protoState,
	}, nil
}

func (s *Server) ResetCircuitBreaker(ctx context.Context, req *orchestrator.ResetCircuitBreakerRequest) (*common.Empty, error) {
	s.circuitBreaker.Reset()
	return &common.Empty{}, nil
}

func (s *Server) GetSystemMetrics(ctx context.Context, req *orchestrator.GetSystemMetricsRequest) (*orchestrator.GetSystemMetricsResponse, error) {
	return &orchestrator.GetSystemMetricsResponse{
		TotalEvents:       0,
		EventsPerSecond:   0,
		ActiveSessions:    0,
		ActiveTenants:     0,
		AverageLatencyMs:  45.0,
		TenantLatencyMs:   map[string]float64{},
		TenantEventCounts: map[string]int64{},
	}, nil
}

func (s *Server) GetEventStats(ctx context.Context, req *orchestrator.GetEventStatsRequest) (*orchestrator.GetEventStatsResponse, error) {
	stats, err := s.eventRepo.GetEventStats(ctx)
	if err != nil {
		return nil, mapError(err)
	}

	return &orchestrator.GetEventStatsResponse{
		TotalEvents:  stats.TotalEvents,
		EventsByType: stats.EventTypes,
		EventsByDay:  map[string]int64{},
	}, nil
}

func (s *Server) Health(ctx context.Context, req *common.HealthRequest) (*common.HealthResponse, error) {
	return &common.HealthResponse{
		Status:    common.HealthResponse_SERVING,
		Version:   "1.0.0",
		Timestamp: timestamppb.New(time.Now().UTC()),
	}, nil
}

func (s *Server) GetEvents(req *orchestrator.GetEventsRequest, stream grpc.ServerStreamingServer[common.EventEnvelope]) error {
	aggID, err := uuid.Parse(req.GetAggregateId())
	if err != nil {
		return status.Error(codes.InvalidArgument, "invalid aggregate_id")
	}

	events, err := s.eventRepo.GetByAggregateID(stream.Context(), aggID, req.GetFromVersion())
	if err != nil {
		return mapError(err)
	}

	for _, ev := range events {
		domEvent := ev.(entity.DomainEvent)
		payload, _ := structpb.NewStruct(domEvent.Payload)
		if err := stream.Send(&common.EventEnvelope{
			EventType:   domEvent.Type,
			AggregateId: domEvent.AggID.String(),
			Version:     domEvent.Version,
			Payload:     payload,
			OccurredAt:  timestamppb.New(domEvent.EventTime),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) ReplayEvents(req *orchestrator.ReplayEventsRequest, stream grpc.ServerStreamingServer[common.EventEnvelope]) error {
	limit := req.GetLimit()
	if limit == 0 {
		limit = 100
	}

	events, err := s.eventRepo.GetAllEvents(stream.Context(), limit, 0)
	if err != nil {
		return mapError(err)
	}

	for _, ev := range events {
		domEvent := ev.(entity.DomainEvent)
		payload, _ := structpb.NewStruct(domEvent.Payload)
		if err := stream.Send(&common.EventEnvelope{
			EventType:   domEvent.Type,
			AggregateId: domEvent.AggID.String(),
			Version:     domEvent.Version,
			Payload:     payload,
			OccurredAt:  timestamppb.New(domEvent.EventTime),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) StreamEvents(req *orchestrator.StreamEventsRequest, stream grpc.ServerStreamingServer[common.EventEnvelope]) error {
	limit := int32(100)
	offset := int32(0)
	maxBatches := int32(10)

	for {
		events, err := s.eventRepo.GetAllEvents(stream.Context(), limit, offset)
		if err != nil {
			return mapError(err)
		}
		if len(events) == 0 {
			break
		}

		for _, ev := range events {
			domEvent := ev.(entity.DomainEvent)
			payload, _ := structpb.NewStruct(domEvent.Payload)
			if err := stream.Send(&common.EventEnvelope{
				EventType:   domEvent.Type,
				AggregateId: domEvent.AggID.String(),
				Version:     domEvent.Version,
				Payload:     payload,
				OccurredAt:  timestamppb.New(domEvent.EventTime),
			}); err != nil {
				return err
			}
		}

		offset += limit
		if offset/limit >= maxBatches {
			break
		}
	}
	return nil
}

func (s *Server) ValidateIdempotencyKey(ctx context.Context, req *orchestrator.ValidateIdempotencyKeyRequest) (*orchestrator.ValidateIdempotencyKeyResponse, error) {
	exists, err := s.eventRepo.CheckIdempotency(ctx, req.GetIdempotencyKey())
	if err != nil {
		return nil, mapError(err)
	}
	return &orchestrator.ValidateIdempotencyKeyResponse{IsValid: !exists}, nil
}

func (s *Server) DeleteTenant(ctx context.Context, req *orchestrator.DeleteTenantRequest) (*orchestrator.DeleteTenantResponse, error) {
	tenantID, err := uuid.Parse(req.GetTenantId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid tenant_id")
	}

	// Soft delete by marking inactive rather than hard delete to preserve ledger integrity
	tenant, err := s.tenantRepo.GetByID(ctx, tenantID)
	if err != nil {
		return nil, mapError(err)
	}

	tenant.Active = false
	if err := s.tenantRepo.Save(ctx, tenant); err != nil {
		return nil, mapError(err)
	}

	return &orchestrator.DeleteTenantResponse{
		Success: true,
		Message: "tenant deactivated successfully",
	}, nil
}

func mapToStruct(m map[string]string) *structpb.Struct {
	if m == nil {
		return nil
	}
	out := make(map[string]interface{}, len(m))
	for k, v := range m {
		out[k] = v
	}
	s, _ := structpb.NewStruct(out)
	return s
}

func mapError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, command.ErrDuplicateEvent) {
		return status.Error(codes.AlreadyExists, err.Error())
	}
	if errors.Is(err, command.ErrConcurrencyConflict) {
		return status.Error(codes.FailedPrecondition, err.Error())
	}
	if errors.Is(err, repository.ErrNotFound) {
		return status.Error(codes.NotFound, err.Error())
	}
	if err.Error() == "rate limit exceeded" || err.Error() == "rate limit exceeded for phone number" || err.Error() == "rate limit exceeded for tenant" {
		return status.Error(codes.ResourceExhausted, err.Error())
	}
	return status.Error(codes.Internal, err.Error())
}
