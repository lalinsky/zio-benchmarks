package main

import (
	"fmt"
	"net"
	"sync"
	"time"
)

func main() {
	const n = 10_000
	const concurrency = 1_000

	sem := make(chan struct{}, concurrency)
	var wg sync.WaitGroup
	wg.Add(n)

	start := time.Now()

	for range n {
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			net.LookupHost("example.com")
		}()
	}

	wg.Wait()
	fmt.Printf("Duration: %v\n", time.Since(start))
}
