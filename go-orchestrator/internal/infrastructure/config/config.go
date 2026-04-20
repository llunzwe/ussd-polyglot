package config

import (
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	Database           DatabaseConfig
	Redis              RedisConfig
	GRPCPort           string
	HTTPPort           string
	TLSEnabled         bool
	TLSCertFile        string
	TLSKeyFile         string
	TLSCAFile          string
	SessionServiceAddr string
	PaymentServiceAddr string
	AdminGRPCPort      string
	AdminAPIKey        string
}

type DatabaseConfig struct {
	Host     string
	Port     string
	User     string
	Password string
	Name     string
}

type RedisConfig struct {
	Host     string
	Port     string
	Password string
}

func (r RedisConfig) Addr() string {
	return fmt.Sprintf("%s:%s", r.Host, r.Port)
}

func Load() Config {
	return Config{
		Database: DatabaseConfig{
			Host:     getEnv("DB_HOST", "localhost"),
			Port:     getEnv("DB_PORT", "5432"),
			User:     getEnv("DB_USER", "postgres"),
			Password: getEnv("DB_PASSWORD", ""),
			Name:     getEnv("DB_NAME", "ussd_kernel"),
		},
		Redis: RedisConfig{
			Host:     getEnv("REDIS_HOST", "localhost"),
			Port:     getEnv("REDIS_PORT", "6379"),
			Password: getEnv("REDIS_PASSWORD", ""),
		},
		GRPCPort:           getEnv("GRPC_PORT", "9090"),
		HTTPPort:           getEnv("HTTP_PORT", "8080"),
		TLSEnabled:         getEnvBool("TLS_ENABLED", false),
		TLSCertFile:        getEnv("TLS_CERT_FILE", ""),
		TLSKeyFile:         getEnv("TLS_KEY_FILE", ""),
		TLSCAFile:          getEnv("TLS_CA_FILE", ""),
		SessionServiceAddr: getEnv("SESSION_SERVICE_ADDR", "localhost:50051"),
		PaymentServiceAddr: getEnv("PAYMENT_SERVICE_ADDR", "localhost:50052"),
		AdminGRPCPort:      getEnv("ADMIN_GRPC_PORT", "9091"),
		AdminAPIKey:        getEnv("ADMIN_API_KEY", ""),
	}
}

func getEnv(key, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}

func getEnvBool(key string, defaultValue bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return defaultValue
	}
	b, _ := strconv.ParseBool(v)
	return b
}
