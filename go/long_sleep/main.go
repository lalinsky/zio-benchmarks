package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	const n = 10000
	var wg sync.WaitGroup
	wg.Add(n)

	start := time.Now()

	for range n {
		go func() {
			defer wg.Done()
			time.Sleep(10 * time.Second)
		}()
	}

	wg.Wait()
	fmt.Printf("Duration: %v\n", time.Since(start))
}
