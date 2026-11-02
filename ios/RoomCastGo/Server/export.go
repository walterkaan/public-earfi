package roomcast

import (
	"errors"
	"sync"
)

// Exported functions are the gomobile surface the Swift app calls.
// One broadcast at a time. Stop is safe to call twice.

var (
	globalMu sync.Mutex
	global   *server

	errAlreadyRunning = errors.New("the broadcast is already running")
)

// Start opens the listener page on httpPort and WebRTC media on icePort.
// ip and iface come from SelectHost. title is the session name on the
// listener page. host is the device name in "from <host>".
func Start(httpPort int, icePort int, ip string, iface string, title string, host string) error {
	next, err := newServer(httpPort, icePort, ip, iface, title, host)
	if err != nil {
		return err
	}
	globalMu.Lock()
	defer globalMu.Unlock()
	if global != nil {
		next.stop()
		return errAlreadyRunning
	}
	global = next
	return nil
}

// SetTitle changes the name on the listener page of a running broadcast.
func SetTitle(title string) {
	title = sanitizeTitle(title)
	globalMu.Lock()
	current := global
	globalMu.Unlock()
	if current != nil {
		current.setTitle(title)
	}
}

// Stop closes the page, the listeners, and the sockets.
func Stop() {
	globalMu.Lock()
	current := global
	global = nil
	globalMu.Unlock()
	if current != nil {
		current.stop()
	}
}

// PublishOpus sends one 20 ms Opus packet to every connected listener.
func PublishOpus(packet []byte) {
	globalMu.Lock()
	current := global
	globalMu.Unlock()
	if current != nil {
		current.publish(packet)
	}
}

// ListenerCount is how many phones have a connected WebRTC session.
func ListenerCount() int {
	globalMu.Lock()
	current := global
	globalMu.Unlock()
	if current == nil {
		return 0
	}
	return current.listenerCount()
}
