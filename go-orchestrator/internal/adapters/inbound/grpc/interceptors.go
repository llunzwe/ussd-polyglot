package grpc

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/infrastructure/observability"
)

// UnaryTracingInterceptor injects OpenTelemetry-style trace context and
// request metadata into outgoing and incoming gRPC calls.
func UnaryTracingInterceptor() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		md, ok := metadata.FromOutgoingContext(ctx)
		if !ok {
			md = metadata.New(nil)
		}
		if len(md.Get("x-request-id")) == 0 {
			md.Set("x-request-id", generateRequestID())
		}
		ctx = metadata.NewOutgoingContext(ctx, md)
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}

// UnaryServerTracingInterceptor extracts trace context from incoming metadata.
func UnaryServerTracingInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		md, ok := metadata.FromIncomingContext(ctx)
		if ok {
			_ = md.Get("x-request-id")
			_ = md.Get("authorization")
		}
		return handler(ctx, req)
	}
}

func generateRequestID() string {
	id, err := uuid.NewV7()
	if err != nil {
		return uuid.Must(uuid.NewRandom()).String()
	}
	return id.String()
}

// RecoveryInterceptor recovers from panics in handlers.
func RecoveryInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp interface{}, err error) {
		defer func() {
			if r := recover(); r != nil {
				err = fmt.Errorf("panic recovered: %v", r)
			}
		}()
		return handler(ctx, req)
	}
}

// UnaryServerMetricsInterceptor records gRPC request duration and status code.
func UnaryServerMetricsInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		duration := time.Since(start).Seconds()

		statusCode := codes.OK
		if err != nil {
			if s, ok := status.FromError(err); ok {
				statusCode = s.Code()
			} else {
				statusCode = codes.Unknown
			}
		}
		observability.RecordGRPCRequest(info.FullMethod, statusCode.String(), duration)
		return resp, err
	}
}

// AdminAuthInterceptor blocks admin requests unless a valid admin API key is provided.
func AdminAuthInterceptor(expectedKey string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		if expectedKey == "" {
			return nil, status.Error(codes.PermissionDenied, "admin API key not configured")
		}
		md, ok := metadata.FromIncomingContext(ctx)
		if !ok {
			return nil, status.Error(codes.Unauthenticated, "missing metadata")
		}
		provided := md.Get("x-admin-api-key")
		if len(provided) == 0 || provided[0] != expectedKey {
			return nil, status.Error(codes.PermissionDenied, "invalid admin API key")
		}
		return handler(ctx, req)
	}
}
