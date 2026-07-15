package main

import (
	"flag"
	"fmt"
	"net"
	"sync"
	"time"
)

// Golden TCP benchmark: -conns concurrent loopback connections, each doing
// -msgs request/response round-trips of -size bytes against a per-connection
// echo handler. Presets:
//
//	defaults (1000 conns x 100 msgs x 64B)  many-connection throughput
//	-conns=1 -msgs=100000 -size=4096        single-connection latency chain
const port = ":18766"

var (
	numConns    = flag.Int("conns", 1000, "concurrent connections")
	msgsPerConn = flag.Int("msgs", 100, "round-trips per connection")
	msgSize     = flag.Int("size", 64, "message size in bytes")
)

func readFull(conn net.Conn, buf []byte) error {
	for len(buf) > 0 {
		n, err := conn.Read(buf)
		buf = buf[n:]
		if err != nil {
			return err
		}
	}
	return nil
}

func echoHandler(conn net.Conn) {
	defer conn.Close()
	msg := make([]byte, *msgSize)
	for {
		if err := readFull(conn, msg); err != nil {
			return
		}
		if _, err := conn.Write(msg); err != nil {
			return
		}
	}
}

func server(ready chan struct{}) {
	ln, err := net.Listen("tcp", port)
	if err != nil {
		fmt.Printf("server: listen failed: %v\n", err)
		close(ready)
		return
	}
	defer ln.Close()

	close(ready)

	var handlers sync.WaitGroup
	for i := 0; i < *numConns; i++ {
		conn, err := ln.Accept()
		if err != nil {
			fmt.Printf("server: accept failed: %v\n", err)
			break
		}
		handlers.Add(1)
		go func() { defer handlers.Done(); echoHandler(conn) }()
	}
	handlers.Wait()
}

func client(ready chan struct{}) {
	<-ready

	conn, err := net.Dial("tcp", port)
	if err != nil {
		fmt.Printf("client: connect failed: %v\n", err)
		return
	}
	defer conn.Close()

	msg := make([]byte, *msgSize)
	for i := 0; i < *msgsPerConn; i++ {
		if _, err := conn.Write(msg); err != nil {
			return
		}
		if err := readFull(conn, msg); err != nil {
			return
		}
	}
}

func main() {
	flag.Parse()

	ready := make(chan struct{})

	start := time.Now()

	serverDone := make(chan struct{})
	go func() { defer close(serverDone); server(ready) }()

	var clients sync.WaitGroup
	for i := 0; i < *numConns; i++ {
		clients.Add(1)
		go func() { defer clients.Done(); client(ready) }()
	}
	clients.Wait()
	<-serverDone

	dur := time.Since(start)
	totalMsgs := *numConns * *msgsPerConn
	rate := int64(float64(totalMsgs) / dur.Seconds())
	fmt.Printf("Duration: %v (%d msgs over %d conns, size %d, %d msgs/s)\n", dur, totalMsgs, *numConns, *msgSize, rate)
}
