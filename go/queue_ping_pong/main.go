package main

import (
	"flag"
	"fmt"
	"sync"
	"time"
)

// -pairs=N runs N independent ping-pong pairs concurrently, splitting a fixed
// total of `total` messages evenly (each pair bounces total/N).
const total = 100_000

func taskA(aToB chan<- uint64, bToA <-chan uint64, limit uint64) {
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

func taskB(aToB <-chan uint64, bToA chan<- uint64, limit uint64) {
	for val := range aToB {
		next := val + 1
		if next >= limit {
			close(bToA)
			return
		}
		bToA <- next
	}
}

// One pair: owns its two channels and runs the two ping-pong tasks to completion.
func pair(limit uint64) {
	aToB := make(chan uint64, 1)
	bToA := make(chan uint64, 1)
	done := make(chan struct{})
	go func() { defer close(done); taskA(aToB, bToA, limit) }()
	taskB(aToB, bToA, limit)
	<-done
}

func main() {
	pairs := flag.Uint64("pairs", 1, "concurrent ping-pong pairs")
	flag.Parse()
	if *pairs == 0 {
		*pairs = 1
	}
	perPair := total / *pairs
	if perPair < 1 {
		perPair = 1
	}

	start := time.Now()
	var wg sync.WaitGroup
	for i := uint64(0); i < *pairs; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); pair(perPair) }()
	}
	wg.Wait()

	fmt.Printf("Duration: %v (%d pairs, %d msgs each)\n", time.Since(start), *pairs, perPair)
}
