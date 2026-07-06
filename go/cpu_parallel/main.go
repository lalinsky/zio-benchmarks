package main

import (
	"fmt"
	"sync"
	"time"
)

const totalIters = 4_000_000_000
const numChunks = 64
const perChunk = totalIters / numChunks

func work(seed, iters uint64) uint64 {
	x := seed
	var acc uint64 = 0
	for i := uint64(0); i < iters; i++ {
		x = x*6364136223846793005 + 1442695040888963407
		acc ^= x >> 29
	}
	return acc
}

func main() {
	results := make([]uint64, numChunks)

	start := time.Now()

	var wg sync.WaitGroup
	for i := 0; i < numChunks; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = work(uint64(idx+1), perChunk)
		}(i)
	}
	wg.Wait()

	var checksum uint64 = 0
	for _, r := range results {
		checksum ^= r
	}

	dur := time.Since(start)
	fmt.Printf("Duration: %v (%d iters, %d chunks, checksum=%x)\n", dur, totalIters, numChunks, checksum)
}
