// TCP load driver on Go: one goroutine per connection over the runtime's
// netpoller, so N connections cost ~GOMAXPROCS OS threads instead of N. A
// lower-overhead alternative to the old C driver (one blocking OS thread per
// connection), which becomes the bottleneck at high connection counts. Same
// flags, modes, and output as the C driver, so it is a drop-in replacement.
//
//	echo   write --size bytes, read them back, --msgs times per connection;
//	       --pipeline P keeps P messages in flight
//	send   stream --mb total (split across conns) to a sink server
//	recv   read --mb total (split across conns) from a source server
package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

func main() {
	mode := flag.String("mode", "echo", "echo|send|recv")
	host := flag.String("host", "127.0.0.1", "server host")
	port := flag.Int("port", 18800, "server port")
	conns := flag.Int("conns", 1, "connections")
	msgs := flag.Int("msgs", 100000, "echo messages per connection")
	size := flag.Int("size", 64, "message / chunk size")
	pipeline := flag.Int("pipeline", 1, "echo messages kept in flight")
	mb := flag.Int64("mb", 4096, "send/recv total MB")
	flag.Parse()
	if *conns < 1 || *size < 1 || *pipeline < 1 {
		fmt.Fprintln(os.Stderr, "usage: tcp_driver --mode=echo|send|recv [--host=H] [--port=P] [--conns=N] [--msgs=N] [--size=N] [--pipeline=N] [--mb=N]")
		os.Exit(2)
	}
	addr := fmt.Sprintf("%s:%d", *host, *port)

	// Two barriers: connect everyone first, then start the timed work together.
	var connected, done sync.WaitGroup
	connected.Add(*conns)
	done.Add(*conns)
	start := make(chan struct{})
	results := make([]error, *conns)

	for i := 0; i < *conns; i++ {
		go func(i int) {
			defer done.Done()
			c, err := connectRetry(addr)
			if err != nil {
				fmt.Fprintln(os.Stderr, "connect failed")
				results[i] = err
				connected.Done()
				return
			}
			defer c.Close()
			connected.Done()
			<-start
			results[i] = work(c, *mode, *msgs, *size, *pipeline, *mb, int64(*conns))
		}(i)
	}

	connected.Wait() // all connected, start together
	t0 := time.Now()
	close(start)
	done.Wait()
	secs := time.Since(t0).Seconds()

	failed := 0
	for _, e := range results {
		if e != nil {
			failed++
		}
	}
	if failed > 0 {
		fmt.Fprintf(os.Stderr, "%d/%d connections failed\n", failed, *conns)
		os.Exit(1)
	}

	if *mode == "echo" {
		total := int64(*msgs) * int64(*conns)
		fmt.Printf("echo: %.3f ms, %d msgs over %d conns, size %d, pipeline %d, %.0f msgs/s\n",
			secs*1000, total, *conns, *size, *pipeline, float64(total)/secs)
	} else {
		perConn := *mb * 1024 * 1024 / int64(*conns)
		gb := float64(perConn*int64(*conns)) / 1e9
		fmt.Printf("%s: %.3f ms, %d MB over %d conns, chunk %d, %.2f GB/s\n",
			*mode, secs*1000, *mb, *conns, *size, gb/secs)
	}
}

func connectRetry(addr string) (net.Conn, error) {
	for attempt := 0; attempt < 200; attempt++ {
		c, err := net.Dial("tcp", addr) // Go enables TCP_NODELAY by default
		if err == nil {
			return c, nil
		}
		time.Sleep(10 * time.Millisecond) // server may still be starting
	}
	return nil, fmt.Errorf("connect failed")
}

func work(c net.Conn, mode string, msgs, size, pipeline int, mb, conns int64) error {
	buf := make([]byte, size)
	switch mode {
	case "echo":
		inflight := pipeline
		if inflight > msgs {
			inflight = msgs
		}
		sent, got := 0, 0
		for ; sent < inflight; sent++ {
			if _, err := c.Write(buf); err != nil {
				return err
			}
		}
		for got < msgs {
			if _, err := io.ReadFull(c, buf); err != nil {
				return err
			}
			got++
			if sent < msgs {
				if _, err := c.Write(buf); err != nil {
					return err
				}
				sent++
			}
		}
	case "send":
		left := mb * 1024 * 1024 / conns
		for left > 0 {
			n := int64(size)
			if left < n {
				n = left
			}
			if _, err := c.Write(buf[:n]); err != nil {
				return err
			}
			left -= n
		}
	case "recv":
		left := mb * 1024 * 1024 / conns
		for left > 0 {
			n := int64(size)
			if left < n {
				n = left
			}
			m, err := c.Read(buf[:n])
			if m > 0 {
				left -= int64(m)
			}
			if err != nil {
				break
			}
		}
		if left > 0 {
			return fmt.Errorf("short recv")
		}
	default:
		return fmt.Errorf("unknown mode %q", mode)
	}
	return nil
}
