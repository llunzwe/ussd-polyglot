package grpc

import (
	"crypto/tls"
	"fmt"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/gen/session"
)

type SessionClient struct {
	conn *grpc.ClientConn
	cli  session.SessionReconstructorClient
}

func NewSessionClient(addr string, tlsConfig *tls.Config) (*SessionClient, error) {
	var opts []grpc.DialOption
	if tlsConfig != nil {
		opts = append(opts, grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	conn, err := grpc.NewClient(addr, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to session service: %w", err)
	}
	return &SessionClient{
		conn: conn,
		cli:  session.NewSessionReconstructorClient(conn),
	}, nil
}

func (c *SessionClient) Client() session.SessionReconstructorClient {
	return c.cli
}

func (c *SessionClient) Close() error {
	return c.conn.Close()
}
