package entity

import (
	"time"

	"github.com/google/uuid"
)

type Saga struct {
	ID          uuid.UUID
	TenantID    uuid.UUID
	Status      string // pending, running, completed, failed, cancelled
	CurrentStep int
	TotalSteps  int
	Steps       []SagaStep
	CreatedAt   time.Time
	CompletedAt *time.Time
}

type SagaStep struct {
	ID                 uuid.UUID
	SagaID             uuid.UUID
	StepNumber         int
	Service            string
	Action             string
	Status             string
	CompensationAction string
	Input              map[string]interface{}
	Output             map[string]interface{}
	Error              string
}
