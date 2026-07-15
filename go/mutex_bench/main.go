package main

// Contended counter on sync.Mutex: 4 goroutines x 100k lock/inc/unlock.
// Counterpart of mutex_bench_native. GOMAXPROCS is respected, so run with
// GOMAXPROCS=1 to compare against single-executor behavior.

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"time"
)

const (
	numWorkers = 4
	iterations = 100_000
)

func main() {
	var mu sync.Mutex
	var counter uint64
	var wg sync.WaitGroup

	start := time.Now()
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				mu.Lock()
				counter++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	d := time.Since(start)

	if counter != numWorkers*iterations {
		fmt.Fprintln(os.Stderr, "bad count")
		os.Exit(1)
	}
	fmt.Printf("Duration: %.3fms (go GOMAXPROCS=%d, %d locks, %.0f locks/s)\n",
		float64(d.Nanoseconds())/1e6, runtime.GOMAXPROCS(0), counter,
		float64(counter)/d.Seconds())
}
