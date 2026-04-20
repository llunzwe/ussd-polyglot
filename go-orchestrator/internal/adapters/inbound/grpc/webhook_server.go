package grpc

import (
	"context"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/application/service"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/common"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/webhook"
)

type WebhookServer struct {
	webhook.UnimplementedWebhookServiceServer
	repo       repository.WebhookRepository
	dispatcher *service.WebhookDispatcher
}

func NewWebhookServer(repo repository.WebhookRepository, dispatcher *service.WebhookDispatcher) *WebhookServer {
	return &WebhookServer{
		repo:       repo,
		dispatcher: dispatcher,
	}
}

func (s *WebhookServer) RegisterWebhook(ctx context.Context, req *webhook.RegisterWebhookRequest) (*webhook.Webhook, error) {
	tenantID, err := uuid.Parse(req.GetTenantId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid tenant_id")
	}

	sub := &entity.WebhookSubscription{
		ID:       uuid.Must(uuid.NewV7()),
		TenantID: tenantID,
		URL:      req.GetUrl(),
		Events:   eventTypesToStrings(req.GetEventTypes()),
		Secret:   req.GetSecret(),
		Active:   true,
		CreatedAt: time.Now().UTC(),
	}

	if err := s.repo.SaveSubscription(ctx, sub); err != nil {
		return nil, mapError(err)
	}

	return subscriptionToProto(sub), nil
}

func (s *WebhookServer) GetWebhook(ctx context.Context, req *webhook.GetWebhookRequest) (*webhook.Webhook, error) {
	id, err := uuid.Parse(req.GetWebhookId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid webhook_id")
	}

	sub, err := s.repo.GetSubscription(ctx, id)
	if err != nil {
		return nil, mapError(err)
	}

	return subscriptionToProto(sub), nil
}

func (s *WebhookServer) ListWebhooks(ctx context.Context, req *webhook.ListWebhooksRequest) (*webhook.ListWebhooksResponse, error) {
	var tenantID uuid.UUID
	if req.GetTenantId() != "" {
		var err error
		tenantID, err = uuid.Parse(req.GetTenantId())
		if err != nil {
			return nil, status.Error(codes.InvalidArgument, "invalid tenant_id")
		}
	}

	subs, err := s.repo.ListSubscriptions(ctx, tenantID)
	if err != nil {
		return nil, mapError(err)
	}

	var items []*webhook.Webhook
	for _, sub := range subs {
		items = append(items, subscriptionToProto(sub))
	}

	return &webhook.ListWebhooksResponse{
		Webhooks: items,
	}, nil
}

func (s *WebhookServer) UpdateWebhook(ctx context.Context, req *webhook.UpdateWebhookRequest) (*webhook.Webhook, error) {
	id, err := uuid.Parse(req.GetWebhookId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid webhook_id")
	}

	sub, err := s.repo.GetSubscription(ctx, id)
	if err != nil {
		return nil, mapError(err)
	}

	if req.GetUrl() != "" {
		sub.URL = req.GetUrl()
	}
	if len(req.GetEventTypes()) > 0 {
		sub.Events = eventTypesToStrings(req.GetEventTypes())
	}
	if req.GetSecret() != "" {
		sub.Secret = req.GetSecret()
	}

	if err := s.repo.SaveSubscription(ctx, sub); err != nil {
		return nil, mapError(err)
	}

	return subscriptionToProto(sub), nil
}

func (s *WebhookServer) DeleteWebhook(ctx context.Context, req *webhook.DeleteWebhookRequest) (*webhook.DeleteWebhookResponse, error) {
	id, err := uuid.Parse(req.GetWebhookId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid webhook_id")
	}

	if err := s.repo.DeleteSubscription(ctx, id); err != nil {
		return nil, mapError(err)
	}

	return &webhook.DeleteWebhookResponse{Success: true}, nil
}

func (s *WebhookServer) DeliverEvent(ctx context.Context, req *webhook.DeliverEventRequest) (*webhook.DeliveryResponse, error) {
	webhookID, err := uuid.Parse(req.GetWebhookId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid webhook_id")
	}

	sub, err := s.repo.GetSubscription(ctx, webhookID)
	if err != nil {
		return nil, mapError(err)
	}

	delivery := &entity.WebhookDelivery{
		ID:             uuid.Must(uuid.NewV7()),
		SubscriptionID: sub.ID,
		EventType:      req.GetEventType().String(),
		Payload:        req.GetPayload().AsMap(),
		Status:         "pending",
	}

	if err := s.repo.SaveDelivery(ctx, delivery); err != nil {
		return nil, mapError(err)
	}

	return &webhook.DeliveryResponse{
		DeliveryId: delivery.ID.String(),
		Accepted:   true,
	}, nil
}

func (s *WebhookServer) GetDeliveryLog(ctx context.Context, req *webhook.GetDeliveryLogRequest) (*webhook.DeliveryLog, error) {
	id, err := uuid.Parse(req.GetDeliveryId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid delivery_id")
	}

	d, err := s.repo.GetDelivery(ctx, id)
	if err != nil {
		return nil, mapError(err)
	}

	return deliveryToProto(d), nil
}

func (s *WebhookServer) ListDeliveryLogs(ctx context.Context, req *webhook.ListDeliveryLogsRequest) (*webhook.ListDeliveryLogsResponse, error) {
	webhookID, _ := uuid.Parse(req.GetWebhookId())

	// For simplicity, list all pending/delivered/failed for a webhook
	var logs []*webhook.DeliveryLog
	subs, err := s.repo.ListSubscriptions(ctx, uuid.Nil)
	if err != nil {
		return nil, mapError(err)
	}
	for _, sub := range subs {
		if webhookID != uuid.Nil && sub.ID != webhookID {
			continue
		}
		// ListPendingDeliveries is limited; for a full list we'd need another repo method.
		// Using pending as a proxy for demo purposes.
		ds, _ := s.repo.ListPendingDeliveries(ctx, 1000)
		for _, d := range ds {
			if d.SubscriptionID == sub.ID {
				logs = append(logs, deliveryToProto(d))
			}
		}
	}

	return &webhook.ListDeliveryLogsResponse{
		Logs: logs,
	}, nil
}

func (s *WebhookServer) ReplayEvent(ctx context.Context, req *webhook.ReplayEventRequest) (*webhook.DeliveryResponse, error) {
	id, err := uuid.Parse(req.GetDeliveryId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid delivery_id")
	}

	d, err := s.repo.GetDelivery(ctx, id)
	if err != nil {
		return nil, mapError(err)
	}

	d.AttemptCount = 0
	d.Status = "pending"
	d.LastAttemptAt = nil
	now := time.Now().UTC().Add(5 * time.Second)
	d.NextRetryAt = &now

	if err := s.repo.SaveDelivery(ctx, d); err != nil {
		return nil, mapError(err)
	}

	return &webhook.DeliveryResponse{
		DeliveryId: d.ID.String(),
		Accepted:   true,
	}, nil
}

func (s *WebhookServer) TestWebhook(ctx context.Context, req *webhook.TestWebhookRequest) (*webhook.DeliveryResponse, error) {
	webhookID, err := uuid.Parse(req.GetWebhookId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid webhook_id")
	}

	sub, err := s.repo.GetSubscription(ctx, webhookID)
	if err != nil {
		return nil, mapError(err)
	}

	delivery := &entity.WebhookDelivery{
		ID:             uuid.Must(uuid.NewV7()),
		SubscriptionID: sub.ID,
		EventType:      "TEST",
		Payload:        map[string]interface{}{"test": true},
		Status:         "pending",
	}

	if err := s.repo.SaveDelivery(ctx, delivery); err != nil {
		return nil, mapError(err)
	}

	return &webhook.DeliveryResponse{
		DeliveryId: delivery.ID.String(),
		Accepted:   true,
	}, nil
}

func (s *WebhookServer) Health(ctx context.Context, req *common.HealthRequest) (*common.HealthResponse, error) {
	return &common.HealthResponse{
		Status:    common.HealthResponse_SERVING,
		Version:   "1.0.0",
		Timestamp: timestamppb.New(time.Now().UTC()),
	}, nil
}

func subscriptionToProto(sub *entity.WebhookSubscription) *webhook.Webhook {
	return &webhook.Webhook{
		WebhookId:  sub.ID.String(),
		TenantId:   sub.TenantID.String(),
		Url:        sub.URL,
		EventTypes: stringsToEventTypes(sub.Events),
		Status:     webhook.WebhookStatus_ACTIVE,
		CreatedAt:  timestamppb.New(sub.CreatedAt),
	}
}

func deliveryToProto(d *entity.WebhookDelivery) *webhook.DeliveryLog {
	log := &webhook.DeliveryLog{
		DeliveryId:   d.ID.String(),
		WebhookId:    d.SubscriptionID.String(),
		EventType:    webhook.WebhookEventType_WEBHOOK_EVENT_UNSPECIFIED,
		Success:      d.Status == "delivered",
		StatusCode:   int32(d.HttpStatus),
		AttemptCount: int32(d.AttemptCount),
	}
	if d.LastAttemptAt != nil {
		log.LastAttemptAt = timestamppb.New(*d.LastAttemptAt)
	}
	if d.NextRetryAt != nil {
		log.NextRetryAt = timestamppb.New(*d.NextRetryAt)
	}
	return log
}

func eventTypesToStrings(types []webhook.WebhookEventType) []string {
	out := make([]string, 0, len(types))
	for _, t := range types {
		out = append(out, t.String())
	}
	return out
}

func stringsToEventTypes(strs []string) []webhook.WebhookEventType {
	out := make([]webhook.WebhookEventType, 0, len(strs))
	for range strs {
		// Simple mapping; in production use a lookup table.
		out = append(out, webhook.WebhookEventType_WEBHOOK_EVENT_UNSPECIFIED)
	}
	return out
}
