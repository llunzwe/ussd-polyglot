package grpc

import (
	"fmt"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/application/service"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/tenant_application"
)

type TenantClientProvider struct {
	mu    sync.RWMutex
	conns map[string]*grpc.ClientConn
}

func NewTenantClientProvider() service.TenantClientProvider {
	return &TenantClientProvider{conns: make(map[string]*grpc.ClientConn)}
}

func (p *TenantClientProvider) GetClient(endpoint string) (tenant_application.TenantUSSDAppClient, error) {
	p.mu.RLock()
	conn, ok := p.conns[endpoint]
	p.mu.RUnlock()
	if ok {
		return tenant_application.NewTenantUSSDAppClient(conn), nil
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	conn, ok = p.conns[endpoint]
	if ok {
		return tenant_application.NewTenantUSSDAppClient(conn), nil
	}

	conn, err := grpc.NewClient(endpoint, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("failed to dial tenant %s: %w", endpoint, err)
	}
	p.conns[endpoint] = conn
	return tenant_application.NewTenantUSSDAppClient(conn), nil
}

func (p *TenantClientProvider) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, conn := range p.conns {
		_ = conn.Close()
	}
}
