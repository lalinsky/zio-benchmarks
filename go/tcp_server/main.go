// TCP benchmark subject, driven by driver/tcp_driver.c. Accepts connections
// forever (the bench runner kills the process); one goroutine per connection.
//
//	echo    write back whatever arrives (works with driver pipelining)
//	sink    read and discard until EOF
//	source  write zeros until the client closes
package main

import (
	"flag"
	"fmt"
	"net"
)

const bufSize = 64 * 1024

var (
	mode = flag.String("mode", "echo", "echo|sink|source")
	port = flag.Int("port", 18800, "listen port")
)

func handler(conn net.Conn) {
	defer conn.Close()
	buf := make([]byte, bufSize)
	switch *mode {
	case "echo":
		for {
			n, err := conn.Read(buf)
			if err != nil {
				return
			}
			if _, err := conn.Write(buf[:n]); err != nil {
				return
			}
		}
	case "sink":
		for {
			if _, err := conn.Read(buf); err != nil {
				return
			}
		}
	case "source":
		for {
			if _, err := conn.Write(buf); err != nil {
				return
			}
		}
	}
}

func main() {
	flag.Parse()
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		panic(err)
	}
	fmt.Printf("tcp_server_go listening on 127.0.0.1:%d (%s)\n", *port, *mode)
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go handler(conn)
	}
}
