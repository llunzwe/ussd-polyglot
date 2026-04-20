package grpc

import (
	"crypto/tls"
	"fmt"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/payment"
)

type PaymentClient struct {
	conn *grpc.ClientConn
	cli  payment.PaymentEngineClient
}

func NewPaymentClient(addr string, tlsConfig *tls.Config) (*PaymentClient, error) {
	var opts []grpc.DialOption
	if tlsConfig != nil {
		opts = append(opts, grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	conn, err := grpc.NewClient(addr, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to payment service: %w", err)
	}
	return &PaymentClient{
		conn: conn,
		cli:  payment.NewPaymentEngineClient(conn),
	}, nil
}

func (c *PaymentClient) Client() payment.PaymentEngineClient {
	return c.cli
}

func (c *PaymentClient) Close() error {
	return c.conn.Close()
}
