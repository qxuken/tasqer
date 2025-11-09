package main

import (
	"bufio"
	"context"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	BindAddr          string        = "127.0.0.1:47912"
	KeepAliveTimeout  time.Duration = 5 * time.Second
	KeepAliveInterval time.Duration = KeepAliveTimeout / 2
)

type PeerEventType uint8

const (
	PeerConnected PeerEventType = iota
	PeerDisconnected
)

var latestId atomic.Uint32

func main() {
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan bool, 1)

	go func(ctx context.Context, done chan<- bool) {
		for {
			if err := leader(ctx, done); err != nil {
				log.Println(err)
			}
			time.Sleep(time.Millisecond * 150)
			if err := folower(ctx, done); err != nil {
				log.Println(err)
			}
			time.Sleep(time.Millisecond * 150)
		}
	}(ctx, done)

	select {
	case <-sigs:
		cancel()
	case <-done:
		return
	}

	select {
	case <-time.Tick(150 * time.Microsecond):
		os.Exit(1)
	case <-done:
		return
	}
}

type Peer struct {
	Id   uint32
	Conn net.Conn
}

type PeerEvent struct {
	peer   *Peer
	action PeerEventType
}

func newPeer(conn net.Conn) Peer {
	id := latestId.Add(1)
	return Peer{
		Id:   id,
		Conn: conn,
	}
}

func (p *Peer) ConnectedEvent() PeerEvent {
	log.Printf("Peer(%v) connected", p.Id)
	return PeerEvent{
		peer:   p,
		action: PeerConnected,
	}
}

func (p *Peer) DisconnectEvent() PeerEvent {
	log.Printf("Peer(%v) disconnected", p.Id)
	return PeerEvent{
		peer:   p,
		action: PeerDisconnected,
	}
}

func leader(ctx context.Context, done chan<- bool) error {
	log.Println("Trying to become leader")
	listener, err := net.Listen("tcp4", BindAddr)
	if err != nil {
		return err
	}
	log.Println("Accepting connections", listener.Addr().String())
	peerEvents := make(chan PeerEvent)
	go func(peerEvents <-chan PeerEvent) {
		tick := time.Tick(KeepAliveInterval)
		var peers []*Peer
	el:
		for {
			select {
			case evt := <-peerEvents:
				switch evt.action {
				case PeerConnected:
					peers = append(peers, evt.peer)
				case PeerDisconnected:
					for i, conn := range peers {
						if conn.Id != evt.peer.Id {
							peers = remove_unordered(peers, i)
							continue el
						}
					}
				}
			case <-tick:
				for _, peer := range peers {
					go peer.Conn.Write([]byte("ping\n"))
				}
			}
		}
	}(peerEvents)
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Fatalln(err)
		}
		peer := newPeer(conn)
		peerEvents <- peer.ConnectedEvent()
		go func(peer Peer, peerEvents chan<- PeerEvent) {
			defer peer.Conn.Close()
			reader := bufio.NewReader(peer.Conn)
			for {
				peer.Conn.SetDeadline(time.Now().Add(KeepAliveTimeout))
				line, err := reader.ReadString('\n')
				if err != nil {
					var ne net.Error
					switch {
					case errors.Is(err, io.EOF): // Clean disconnect
					case errors.As(err, &ne) && ne.Timeout():
						log.Printf("Peer(%v) idle timeout", peer.Id)
					default:
						log.Printf("Peer(%v) read error: %v", peer.Id, err)
					}
					peerEvents <- peer.DisconnectEvent()
					return
				}
				log.Printf("Peer(%v) msg -> %v", peer.Id, line)
			}
		}(peer, peerEvents)
	}
	done <- true
	return nil
}

func folower(ctx context.Context, done chan<- bool) error {
	log.Println("Trying to become follower")

	conn, err := net.Dial("tcp4", BindAddr)
	if err != nil {
		return err
	}
	defer conn.Close()
	ctx, cancel := context.WithCancel(ctx)
	go func(ctx context.Context, conn net.Conn) {
		tick := time.Tick(KeepAliveInterval)
		for {
			select {
			case <-ctx.Done():
				conn.Close()
				done <- true
				return
			case <-tick:
				conn.Write([]byte("ping\n"))
			}
		}
	}(ctx, conn)

	reader := bufio.NewReader(conn)
	for {
		conn.SetDeadline(time.Now().Add(KeepAliveTimeout))
		line, err := reader.ReadString('\n')
		if err != nil {
			log.Println(err)
			cancel()
			return nil
		}
		log.Printf("Leader: %v", line)
	}
}

func remove_unordered[T any](s []T, i int) []T {
	s[i] = s[len(s)-1]
	return s[:len(s)-1]
}
