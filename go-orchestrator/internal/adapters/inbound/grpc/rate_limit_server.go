package grpc

import (
	"context"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/application/service"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/common"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/orchestrator"
)

type rateLimitServer struct {
	svc *service.RateLimitService
}

func newRateLimitServer(svc *service.RateLimitService) rateLimitServer {
	return rateLimitServer{svc: svc}
}

func (s *rateLimitServer) GetRateLimitStatus(ctx context.Context, req *orchestrator.GetRateLimitStatusRequest) (*common.RateLimitStatus, error) {
	limit, count, burst, err := s.svc.GetStatus(ctx, req.GetTenantId(), req.GetResourceType())
	if err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}

	refillRate := float64(limit) / 60.0
	if refillRate == 0 {
		refillRate = 10
	}

	return &common.RateLimitStatus{
		ResourceType:        req.GetResourceType(),
		TokensRemaining:     float64(limit - count),
		BucketCapacity:      float64(burst),
		RefillRatePerSecond: refillRate,
		LastRefillAt:        timestamppb.New(time.Now().UTC()),
		IsBlocked:           count >= limit,
		TotalRequests:       int32(count),
		ThrottledRequests:   0,
	}, nil
}

func (s *rateLimitServer) UpdateRateLimitPolicy(ctx context.Context, req *orchestrator.UpdateRateLimitPolicyRequest) (*orchestrator.RateLimitPolicy, error) {
	policy, err := s.svc.UpdatePolicy(ctx,
		req.GetTenantId(),
		req.GetResourceType(),
		int64(req.GetRequestsPerMinute()),
		int64(req.GetRequestsPerHour()),
		int64(req.GetRequestsPerDay()),
		int64(req.GetBurstCapacity()),
	)
	if err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}

	return &orchestrator.RateLimitPolicy{
		PolicyId:          policy.ID.String(),
		TenantId:          policy.TenantID.String(),
		ResourceType:      policy.ResourceType,
		RequestsPerMinute: int32(policy.RequestsPerMinute),
		RequestsPerHour:   int32(policy.RequestsPerHour),
		RequestsPerDay:    int32(policy.RequestsPerDay),
		BurstCapacity:     int32(policy.BurstCapacity),
		CreatedAt:         timestamppb.New(time.Now().UTC()),
		UpdatedAt:         timestamppb.New(time.Now().UTC()),
	}, nil
}
