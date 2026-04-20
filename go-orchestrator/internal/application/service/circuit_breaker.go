package service

import (
	"sync"
	"time"
)

type CircuitBreakerState int32

const (
	StateClosed CircuitBreakerState = iota
	StateOpen
	StateHalfOpen
)

type CircuitBreaker struct {
	mu               sync.RWMutex
	state            CircuitBreakerState
	failures         int
	lastFailureTime  time.Time
	openDuration     time.Duration
	failureThreshold int
}

func NewCircuitBreaker() *CircuitBreaker {
	return &CircuitBreaker{
		state:            StateClosed,
		openDuration:     30 * time.Second,
		failureThreshold: 5,
	}
}

func (cb *CircuitBreaker) Allow() bool {
	cb.mu.RLock()
	defer cb.mu.RUnlock()

	switch cb.state {
	case StateClosed:
		return true
	case StateOpen:
		if time.Since(cb.lastFailureTime) > cb.openDuration {
			cb.mu.RUnlock()
			cb.mu.Lock()
			if cb.state == StateOpen && time.Since(cb.lastFailureTime) > cb.openDuration {
				cb.state = StateHalfOpen
				cb.failures = 0
			}
			cb.mu.Unlock()
			cb.mu.RLock()
			return cb.state == StateHalfOpen
		}
		return false
	case StateHalfOpen:
		return true
	}
	return true
}

func (cb *CircuitBreaker) RecordSuccess() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	switch cb.state {
	case StateHalfOpen:
		cb.state = StateClosed
		cb.failures = 0
	case StateClosed:
		cb.failures = 0
	}
}

func (cb *CircuitBreaker) RecordFailure() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.failures++
	cb.lastFailureTime = time.Now()

	switch cb.state {
	case StateClosed:
		if cb.failures >= cb.failureThreshold {
			cb.state = StateOpen
		}
	case StateHalfOpen:
		cb.state = StateOpen
	}
}

func (cb *CircuitBreaker) State() CircuitBreakerState {
	cb.mu.RLock()
	defer cb.mu.RUnlock()
	return cb.state
}

func (cb *CircuitBreaker) Reset() {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	cb.state = StateClosed
	cb.failures = 0
}
