package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"time"
)

const limit = 100_000
const port = ":18765"
const msgSize = 4096

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

func server(ready chan struct{}) {
	ln, err := net.Listen("tcp", port)
	if err != nil {
		fmt.Printf("server: listen failed: %v\n", err)
		close(ready)
		return
	}
	defer ln.Close()

	close(ready)

	conn, err := ln.Accept()
	if err != nil {
		fmt.Printf("server: accept failed: %v\n", err)
		return
	}
	defer conn.Close()

	msg := make([]byte, msgSize)
	binary.BigEndian.PutUint64(msg, 0)
	if _, err := conn.Write(msg); err != nil {
		return
	}

	for {
		if err := readFull(conn, msg); err != nil {
			return
		}
		val := binary.BigEndian.Uint64(msg)
		next := val + 1
		if next >= limit {
			return
		}
		binary.BigEndian.PutUint64(msg, next)
		if _, err := conn.Write(msg); err != nil {
			return
		}
	}
}

func client(ready chan struct{}) {
	<-ready

	conn, err := net.Dial("tcp", port)
	if err != nil {
		fmt.Printf("client: connect failed: %v\n", err)
		return
	}
	defer conn.Close()

	msg := make([]byte, msgSize)

	for {
		if err := readFull(conn, msg); err != nil {
			return
		}
		val := binary.BigEndian.Uint64(msg)
		next := val + 1
		if next >= limit {
			return
		}
		binary.BigEndian.PutUint64(msg, next)
		if _, err := conn.Write(msg); err != nil {
			return
		}
	}
}

func main() {
	ready := make(chan struct{})
	serverDone := make(chan struct{})
	clientDone := make(chan struct{})

	start := time.Now()

	go func() { defer close(serverDone); server(ready) }()
	go func() { defer close(clientDone); client(ready) }()

	<-serverDone
	<-clientDone

	fmt.Printf("Duration: %v\n", time.Since(start))
}
