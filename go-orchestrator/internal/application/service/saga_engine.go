package service

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/entity"
	"github.com/openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

type StepHandler interface {
	Execute(ctx context.Context, step entity.SagaStep) (map[string]interface{}, error)
	Compensate(ctx context.Context, step entity.SagaStep) error
}

type SagaEngine struct {
	repo    repository.SagaRepository
	handler StepHandler
	mu      sync.RWMutex
	running map[uuid.UUID]context.CancelFunc
}

func NewSagaEngine(repo repository.SagaRepository, handler StepHandler) *SagaEngine {
	return &SagaEngine{
		repo:    repo,
		handler: handler,
		running: make(map[uuid.UUID]context.CancelFunc),
	}
}

func (e *SagaEngine) StartSaga(ctx context.Context, saga *entity.Saga) error {
	saga.Status = "running"
	saga.CurrentStep = 0
	if err := e.repo.SaveSaga(ctx, saga); err != nil {
		return fmt.Errorf("save saga: %w", err)
	}

	sagaCtx, cancel := context.WithCancel(context.Background())
	e.mu.Lock()
	e.running[saga.ID] = cancel
	e.mu.Unlock()

	go e.executeSaga(sagaCtx, saga)
	return nil
}

func (e *SagaEngine) GetSaga(ctx context.Context, id uuid.UUID) (*entity.Saga, error) {
	return e.repo.GetSaga(ctx, id)
}

func (e *SagaEngine) CancelSaga(ctx context.Context, id uuid.UUID) error {
	e.mu.Lock()
	cancel, ok := e.running[id]
	e.mu.Unlock()
	if ok {
		cancel()
	}

	saga, err := e.repo.GetSaga(ctx, id)
	if err != nil {
		return err
	}
	saga.Status = "cancelled"
	now := time.Now().UTC()
	saga.CompletedAt = &now
	return e.repo.SaveSaga(ctx, saga)
}

func (e *SagaEngine) executeSaga(ctx context.Context, saga *entity.Saga) {
	defer func() {
		e.mu.Lock()
		delete(e.running, saga.ID)
		e.mu.Unlock()
	}()

	for i := range saga.Steps {
		select {
		case <-ctx.Done():
			saga.Status = "cancelled"
			now := time.Now().UTC()
			saga.CompletedAt = &now
			_ = e.repo.SaveSaga(context.Background(), saga)
			return
		default:
		}

		saga.CurrentStep = i + 1
		step := &saga.Steps[i]
		step.Status = "running"

		if err := e.repo.SaveSaga(context.Background(), saga); err != nil {
			slog.Error("failed to persist saga step", slog.String("saga_id", saga.ID.String()), slog.String("error", err.Error()))
		}

		output, err := e.handler.Execute(ctx, *step)
		if err != nil {
			step.Status = "failed"
			step.Error = err.Error()
			_ = e.repo.SaveSaga(context.Background(), saga)
			e.compensate(ctx, saga, i)
			return
		}

		step.Status = "completed"
		step.Output = output
		_ = e.repo.SaveSaga(context.Background(), saga)
	}

	saga.Status = "completed"
	now := time.Now().UTC()
	saga.CompletedAt = &now
	_ = e.repo.SaveSaga(context.Background(), saga)
}

func (e *SagaEngine) compensate(ctx context.Context, saga *entity.Saga, failedStep int) {
	saga.Status = "compensating"
	_ = e.repo.SaveSaga(context.Background(), saga)

	for i := failedStep; i >= 0; i-- {
		step := saga.Steps[i]
		if step.CompensationAction == "" {
			continue
		}
		if err := e.handler.Compensate(ctx, step); err != nil {
			slog.Error("compensation failed",
				slog.String("saga_id", saga.ID.String()),
				slog.Int("step", i),
				slog.String("error", err.Error()))
		}
		step.Status = "compensated"
		_ = e.repo.SaveSaga(context.Background(), saga)
	}

	saga.Status = "failed"
	now := time.Now().UTC()
	saga.CompletedAt = &now
	_ = e.repo.SaveSaga(context.Background(), saga)
}
