// Golden sleep/spawn benchmark: -tasks goroutines each sleeping -sleep-ms,
// wait for all. -sleep-ms=0 is a pure no-op spawn benchmark.
package main

import (
	"flag"
	"fmt"
	"sync"
	"time"
)

var (
	numTasks = flag.Int("tasks", 10000, "concurrent tasks")
	sleepMs  = flag.Int("sleep-ms", 1, "sleep per task in milliseconds")
)

func main() {
	flag.Parse()

	var wg sync.WaitGroup
	wg.Add(*numTasks)

	start := time.Now()

	d := time.Duration(*sleepMs) * time.Millisecond
	for i := 0; i < *numTasks; i++ {
		go func() {
			defer wg.Done()
			if d > 0 {
				time.Sleep(d)
			}
		}()
	}

	wg.Wait()
	fmt.Printf("Duration: %v (%d tasks, sleep %dms)\n", time.Since(start), *numTasks, *sleepMs)
}
