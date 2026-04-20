package service

import (
	"context"
	"fmt"
	"time"

	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type RateLimiter interface {
	Allow(ctx context.Context, key string, limit int) bool
	AllowTenant(ctx context.Context, tenantID string, limit int) bool
}

type TokenBucketRateLimiter struct {
	cache repository.Cache
}

func NewTokenBucketRateLimiter(cache repository.Cache) *TokenBucketRateLimiter {
	return &TokenBucketRateLimiter{cache: cache}
}

func (r *TokenBucketRateLimiter) Allow(ctx context.Context, key string, limit int) bool {
	return r.allowKey(ctx, fmt.Sprintf("rl:phone:%s", key), limit)
}

func (r *TokenBucketRateLimiter) AllowTenant(ctx context.Context, tenantID string, limit int) bool {
	return r.allowKey(ctx, fmt.Sprintf("rl:tenant:%s", tenantID), limit)
}

func (r *TokenBucketRateLimiter) allowKey(ctx context.Context, key string, limit int) bool {
	count, err := r.cache.Incr(ctx, key)
	if err != nil {
		return true // fail open
	}
	if count == 1 {
		_ = r.cache.Expire(ctx, key, time.Minute)
	}
	return count <= int64(limit)
}
