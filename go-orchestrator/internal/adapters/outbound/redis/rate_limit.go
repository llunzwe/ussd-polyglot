package redis

import (
	"context"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

func AllowSlidingWindow(ctx context.Context, client *redis.Client, key string, limit int64, window time.Duration) bool {
	now := time.Now().UnixMilli()
	windowStart := now - window.Milliseconds()

	pipe := client.TxPipeline()
	pipe.ZRemRangeByScore(ctx, key, "0", strconv.FormatInt(windowStart, 10))
	pipe.ZCard(ctx, key)
	pipe.ZAdd(ctx, key, redis.Z{Score: float64(now), Member: now})
	pipe.Expire(ctx, key, window)
	cmds, err := pipe.Exec(ctx)
	if err != nil {
		return true // fail open
	}

	countCmd := cmds[1].(*redis.IntCmd)
	count, _ := countCmd.Result()
	return count <= limit
}
