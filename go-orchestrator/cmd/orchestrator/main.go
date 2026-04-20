package main

import (
	"context"
	"crypto/tls"
	"log"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"

	inboundgrpc "github.com/openai-ussd-kernel/go-orchestrator/internal/adapters/inbound/grpc"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/adapters/outbound/memory"
	outboundgrpc "github.com/openai-ussd-kernel/go-orchestrator/internal/adapters/outbound/grpc"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/adapters/outbound/postgres"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/adapters/outbound/redis"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/application/command"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/application/service"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/admin"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/orchestrator"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/webhook"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/infrastructure/config"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/infrastructure/observability"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/infrastructure/security"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	cfg := config.Load()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	shutdownTracing, err := observability.InitTracing(ctx, "go-orchestrator")
	if err != nil {
		log.Fatalf("failed to init tracing: %v", err)
	}
	defer shutdownTracing()

	metricsSrv := observability.StartMetricsServer(cfg.HTTPPort)

	db, err := postgres.NewConnection(cfg.Database)
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer db.Close()

	cache := redis.NewCache(cfg.Redis)

	eventStore := postgres.NewEventStore(db)
	tenantRepo := postgres.NewTenantRepository(db)

	var clientTLS *tls.Config
	if cfg.TLSEnabled && cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" && cfg.TLSCAFile != "" {
		clientTLS, err = security.LoadClientTLSConfig(cfg.TLSCertFile, cfg.TLSKeyFile, cfg.TLSCAFile)
		if err != nil {
			log.Fatalf("failed to load client TLS config: %v", err)
		}
	}

	sessionCli, err := outboundgrpc.NewSessionClient(cfg.SessionServiceAddr, clientTLS)
	if err != nil {
		log.Fatalf("failed to connect to session service: %v", err)
	}
	defer sessionCli.Close()

	paymentCli, err := outboundgrpc.NewPaymentClient(cfg.PaymentServiceAddr, clientTLS)
	if err != nil {
		log.Fatalf("failed to connect to payment service: %v", err)
	}
	defer paymentCli.Close()

	tenantProv := outboundgrpc.NewTenantClientProvider()
	defer tenantProv.Close()

	rateLimiter := service.NewTokenBucketRateLimiter(cache)
	circuitBreaker := service.NewCircuitBreaker()

	appendHandler := command.NewAppendEventHandler(eventStore, db)
	createSessionHandler := command.NewCreateSessionHandler(eventStore)
	registerTenantHandler := command.NewRegisterTenantHandler(tenantRepo)

	// New services
	webhookRepo := postgres.NewWebhookRepository(db)
	adminRepo := memory.NewAdminRepository()
	sagaRepo := memory.NewSagaRepository()
	rateLimitRepo := memory.NewRateLimitRepository()

	webhookDispatcher := service.NewWebhookDispatcher(webhookRepo)
	webhookDispatcher.Start()
	defer webhookDispatcher.Stop()

	stepHandler := service.NewServiceStepHandler(paymentCli.Client(), sessionCli.Client())
	sagaEngine := service.NewSagaEngine(sagaRepo, stepHandler)
	rateLimitService := service.NewRateLimitService(rateLimitRepo, cache, rateLimiter)

	outboxPoller := service.NewOutboxPoller(db, eventStore)
	outboxPoller.Start()
	defer outboxPoller.Stop()

	grpcServer := newGRPCServer(cfg)
	router := service.NewRouter(rateLimiter, tenantRepo, sessionCli.Client(), tenantProv, paymentCli.Client(), circuitBreaker)
	orchestratorServer := inboundgrpc.NewServer(
		router,
		appendHandler,
		createSessionHandler,
		registerTenantHandler,
		eventStore,
		tenantRepo,
		sagaEngine,
		rateLimitService,
		circuitBreaker,
	)
	orchestrator.RegisterOrchestratorServer(grpcServer, orchestratorServer)

	webhookServer := inboundgrpc.NewWebhookServer(webhookRepo, webhookDispatcher)
	webhook.RegisterWebhookServiceServer(grpcServer, webhookServer)

	// Admin service runs on a separate port with admin-only auth
	adminServer := inboundgrpc.NewAdminServer(adminRepo, db)
	adminGRPCServer := newAdminGRPCServer(cfg)
	admin.RegisterAdminServiceServer(adminGRPCServer, adminServer)

	adminLis, err := net.Listen("tcp", ":"+cfg.AdminGRPCPort)
	if err != nil {
		log.Fatalf("failed to listen on admin port: %v", err)
	}
	go func() {
		log.Printf("admin gRPC server listening on :%s", cfg.AdminGRPCPort)
		if err := adminGRPCServer.Serve(adminLis); err != nil {
			log.Printf("admin gRPC server error: %v", err)
		}
	}()

	lis, err := net.Listen("tcp", ":"+cfg.GRPCPort)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	go func() {
		log.Printf("gRPC server listening on :%s", cfg.GRPCPort)
		if err := grpcServer.Serve(lis); err != nil {
			log.Printf("gRPC server error: %v", err)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("shutting down gracefully...")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	grpcServer.GracefulStop()
	adminGRPCServer.GracefulStop()
	_ = metricsSrv.Shutdown(shutdownCtx)
}

func newAdminGRPCServer(cfg config.Config) *grpc.Server {
	opts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			inboundgrpc.RecoveryInterceptor(),
			inboundgrpc.AdminAuthInterceptor(cfg.AdminAPIKey),
			inboundgrpc.UnaryServerTracingInterceptor(),
			inboundgrpc.UnaryServerMetricsInterceptor(),
		),
	}

	if cfg.TLSEnabled && cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" && cfg.TLSCAFile != "" {
		tlsConfig, err := security.LoadServerTLSConfig(cfg.TLSCertFile, cfg.TLSKeyFile, cfg.TLSCAFile)
		if err != nil {
			log.Fatalf("failed to load TLS credentials: %v", err)
		}
		opts = append(opts, grpc.Creds(credentials.NewTLS(tlsConfig)))
	} else if cfg.TLSEnabled && cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" {
		creds, err := credentials.NewServerTLSFromFile(cfg.TLSCertFile, cfg.TLSKeyFile)
		if err != nil {
			log.Fatalf("failed to load TLS credentials: %v", err)
		}
		opts = append(opts, grpc.Creds(creds))
	}

	return grpc.NewServer(opts...)
}

func newGRPCServer(cfg config.Config) *grpc.Server {
	opts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			inboundgrpc.RecoveryInterceptor(),
			inboundgrpc.UnaryServerTracingInterceptor(),
			inboundgrpc.UnaryServerMetricsInterceptor(),
		),
	}

	if cfg.TLSEnabled && cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" && cfg.TLSCAFile != "" {
		tlsConfig, err := security.LoadServerTLSConfig(cfg.TLSCertFile, cfg.TLSKeyFile, cfg.TLSCAFile)
		if err != nil {
			log.Fatalf("failed to load TLS credentials: %v", err)
		}
		opts = append(opts, grpc.Creds(credentials.NewTLS(tlsConfig)))
	} else if cfg.TLSEnabled && cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" {
		creds, err := credentials.NewServerTLSFromFile(cfg.TLSCertFile, cfg.TLSKeyFile)
		if err != nil {
			log.Fatalf("failed to load TLS credentials: %v", err)
		}
		opts = append(opts, grpc.Creds(creds))
	}

	return grpc.NewServer(opts...)
}
