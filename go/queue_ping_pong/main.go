package main

import (
	"fmt"
	"time"
)

const limit = 100_000

func taskA(aToB chan<- uint64, bToA <-chan uint64) {
	aToB <- 0
	for val := range bToA {
		next := val + 1
		if next >= limit {
			close(aToB)
			return
		}
		aToB <- next
	}
}

func taskB(aToB <-chan uint64, bToA chan<- uint64) {
	for val := range aToB {
		next := val + 1
		if next >= limit {
			close(bToA)
			return
		}
		bToA <- next
	}
}

func main() {
	aToB := make(chan uint64, 1)
	bToA := make(chan uint64, 1)

	start := time.Now()

	done := make(chan struct{})
	go func() { defer close(done); taskA(aToB, bToA) }()
	taskB(aToB, bToA)
	<-done

	fmt.Printf("Duration: %v\n", time.Since(start))
}
