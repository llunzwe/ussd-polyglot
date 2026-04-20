package observability

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	forwardUSSDTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "forward_ussd_total",
		Help: "Total number of ForwardUSSD requests",
	}, []string{"status"})

	appendEventTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "append_event_total",
		Help: "Total number of AppendEvent requests",
	}, []string{"status"})

	appendEventDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "append_event_duration_seconds",
		Help:    "Duration of AppendEvent requests in seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"status"})

	sessionReconstructDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "session_reconstruct_duration_seconds",
		Help:    "Duration of session reconstruction requests in seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"status"})

	tenantRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "tenant_request_duration_seconds",
		Help:    "Duration of tenant requests in seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"tenant_id"})

	rateLimitHitsTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "rate_limit_hits_total",
		Help: "Total number of rate limit hits",
	})

	grpcRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "grpc_request_duration_seconds",
		Help:    "Duration of gRPC requests in seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "status"})
)

func RecordForwardUSSD(status string) {
	forwardUSSDTotal.WithLabelValues(status).Inc()
}

func RecordAppendEvent(status string, duration float64) {
	appendEventTotal.WithLabelValues(status).Inc()
	appendEventDuration.WithLabelValues(status).Observe(duration)
}

func RecordSessionReconstruct(status string, duration float64) {
	sessionReconstructDuration.WithLabelValues(status).Observe(duration)
}

func RecordTenantRequest(tenantID string, duration float64) {
	tenantRequestDuration.WithLabelValues(tenantID).Observe(duration)
}

func RecordRateLimitHit() {
	rateLimitHitsTotal.Inc()
}

func RecordGRPCRequest(method, status string, duration float64) {
	grpcRequestDuration.WithLabelValues(method, status).Observe(duration)
}

func StartMetricsServer(port string) *http.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.Handle("/metrics", promhttp.Handler())

	srv := &http.Server{Addr: ":" + port, Handler: mux}
	go func() {
		_ = srv.ListenAndServe()
	}()
	return srv
}
