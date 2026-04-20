package observability

import (
	"context"

	"google.golang.org/grpc/metadata"
)

func InitTracing(ctx context.Context, serviceName string) (func(), error) {
	// Stub: in production, initialize an OTLP exporter here.
	return func() {}, nil
}

// StartSpan extracts trace ID from gRPC metadata and creates a child context.
func StartSpan(ctx context.Context, name string) context.Context {
	md, ok := metadata.FromIncomingContext(ctx)
	if ok {
		traceIDs := md.Get("x-trace-id")
		if len(traceIDs) > 0 {
			ctx = context.WithValue(ctx, "trace_id", traceIDs[0])
		}
	}
	return context.WithValue(ctx, "span_name", name)
}

// ExtractTraceContext returns the trace_id from context, or empty string.
func ExtractTraceContext(ctx context.Context) string {
	if v := ctx.Value("trace_id"); v != nil {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}
