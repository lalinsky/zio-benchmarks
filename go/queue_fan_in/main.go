package main

import (
	"fmt"
	"sync"
	"time"
)

const numProducers = 1000
const perProducer = 100
const total = numProducers * perProducer
const bufferSize = 256

func producer(ch chan<- uint64) {
	for i := 0; i < perProducer; i++ {
		ch <- 1
	}
}

func consumer(ch <-chan uint64, done chan<- struct{}) {
	defer close(done)
	for count := 0; count < total; count++ {
		<-ch
	}
}

func main() {
	ch := make(chan uint64, bufferSize)

	start := time.Now()

	done := make(chan struct{})
	go consumer(ch, done)

	var producers sync.WaitGroup
	for i := 0; i < numProducers; i++ {
		producers.Add(1)
		go func() { defer producers.Done(); producer(ch) }()
	}
	producers.Wait()
	<-done

	dur := time.Since(start)
	rate := int64(float64(total) / dur.Seconds())
	fmt.Printf("Duration: %v (%d msgs, %d producers, %d msgs/s)\n", dur, total, numProducers, rate)
}
