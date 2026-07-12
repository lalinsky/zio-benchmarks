package main

import (
	"flag"
	"fmt"
	"sync"
	"time"
)

const bufferSize = 256

func work(seed uint64, iters uint64) uint64 {
	x := seed
	var acc uint64
	for i := uint64(0); i < iters; i++ {
		x = x*6364136223846793005 + 1442695040888963407
		acc ^= x >> 29
	}
	return acc
}

func producer(ch chan<- uint64, start, end uint64, wg *sync.WaitGroup) {
	defer wg.Done()
	for i := start; i < end; i++ {
		ch <- i + 1
	}
}

func consumer(ch <-chan uint64, workIters uint64, result *uint64, wg *sync.WaitGroup) {
	defer wg.Done()
	var acc uint64
	for item := range ch {
		acc ^= work(item, workIters)
	}
	*result = acc
}

func main() {
	numItems := flag.Uint64("num-items", 100000, "total items pushed through the queue")
	numProducers := flag.Uint64("num-producers", 1, "producer goroutines")
	numConsumers := flag.Uint64("num-consumers", 1000, "consumer goroutines")
	workIters := flag.Uint64("work", 64, "hash iterations per item")
	flag.Parse()

	ch := make(chan uint64, bufferSize)
	results := make([]uint64, *numConsumers)

	start := time.Now()

	var consumers sync.WaitGroup
	for i := uint64(0); i < *numConsumers; i++ {
		consumers.Add(1)
		go consumer(ch, *workIters, &results[i], &consumers)
	}

	var producers sync.WaitGroup
	for p := uint64(0); p < *numProducers; p++ {
		producers.Add(1)
		go producer(ch, p**numItems / *numProducers, (p+1)**numItems / *numProducers, &producers)
	}
	go func() {
		producers.Wait()
		close(ch)
	}()
	consumers.Wait()

	var checksum uint64
	for _, r := range results {
		checksum ^= r
	}

	dur := time.Since(start)
	rate := int64(float64(*numItems) / dur.Seconds())
	fmt.Printf("Duration: %v (%d items, %d producers, %d consumers, work=%d, %d msgs/s, checksum=%x)\n",
		dur, *numItems, *numProducers, *numConsumers, *workIters, rate, checksum)
}
