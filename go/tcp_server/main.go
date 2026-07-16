// TCP benchmark subject, driven by driver/tcp_driver.go. Accepts connections
// forever (the bench runner kills the process); one goroutine per connection.
//
//	echo    write back whatever arrives (works with driver pipelining)
//	sink    read and discard until EOF
//	source  write zeros until the client closes
//	http    minimal HTTP/1.1 keep-alive: read a request, write a fixed
//	        "HelloWorld" response. Drive this one with wrk, not the driver.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"net"
)

const bufSize = 64 * 1024

// Matches the other tcp_server http modes. Go sets TCP_NODELAY by default.
var httpResponse = []byte("HTTP/1.1 200 Ok\r\nContent-Length: 10\r\nContent-Type: text/plain; charset=utf8\r\n\r\nHelloWorld")
var crlf = []byte("\r\n\r\n")

var (
	mode = flag.String("mode", "echo", "echo|sink|source|http")
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
	case "http":
		// Minimal HTTP/1.1 framing: accumulate bytes and emit one response
		// per "\r\n\r\n" request terminator, shifting consumed bytes out.
		end := 0
		for {
			for {
				i := bytes.Index(buf[:end], crlf)
				if i < 0 {
					break
				}
				consumed := i + 4
				copy(buf, buf[consumed:end])
				end -= consumed
				if _, err := conn.Write(httpResponse); err != nil {
					return
				}
			}
			n, err := conn.Read(buf[end:])
			if err != nil {
				return
			}
			end += n
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
