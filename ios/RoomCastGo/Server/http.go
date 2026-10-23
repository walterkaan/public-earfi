package roomcast

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
)

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	allowWHEP(w)
	path := r.URL.Path
	if path != "/" && strings.HasSuffix(path, "/") {
		path = strings.TrimSuffix(path, "/")
	}
	switch {
	case r.Method == http.MethodOptions:
		w.WriteHeader(http.StatusNoContent)
	case (r.Method == http.MethodGet || r.Method == http.MethodHead) && path == "/":
		s.writeBytes(w, http.StatusOK, "text/html; charset=utf-8", []byte(listenerHTML(s.currentTitle())), r.Method == http.MethodHead)
	case (r.Method == http.MethodGet || r.Method == http.MethodHead) && path == "/earfi.json":
		body, _ := json.Marshal(map[string]string{"title": s.currentTitle()})
		s.writeBytes(w, http.StatusOK, "application/json; charset=utf-8", body, r.Method == http.MethodHead)
	case (r.Method == http.MethodGet || r.Method == http.MethodHead) && path == "/reader.js":
		s.writeBytes(w, http.StatusOK, "text/javascript; charset=utf-8", readerJS, r.Method == http.MethodHead)
	case (r.Method == http.MethodGet || r.Method == http.MethodHead) && path == "/live":
		http.Redirect(w, r, "/", http.StatusFound)
	case (path == "/whep" || path == "/live/whep") && r.Method == http.MethodPost:
		s.handleOffer(w, r)
	case r.Method == http.MethodPatch && isSessionPath(path):
		s.handleTrickle(w, r, path)
	case r.Method == http.MethodDelete && isSessionPath(path):
		if id, ok := sessionID(path); ok {
			s.drop(id)
		}
		w.WriteHeader(http.StatusOK)
	default:
		http.NotFound(w, r)
	}
}

func (s *server) handleOffer(w http.ResponseWriter, r *http.Request) {
	if !strings.Contains(strings.ToLower(r.Header.Get("Content-Type")), "application/sdp") {
		writeError(w, http.StatusBadRequest, "expected application/sdp")
		return
	}
	body, err := readBody(w, r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read the offer")
		return
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		writeError(w, http.StatusBadRequest, "empty offer")
		return
	}
	id, answer, err := s.acceptOffer(string(body))
	if err != nil {
		if errors.Is(err, errFull) {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/sdp")
	w.Header().Set("Location", "/whep/"+id)
	w.Header().Set("ETag", `"roomcast"`)
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusCreated)
	_, _ = w.Write([]byte(answer))
}

func (s *server) handleTrickle(w http.ResponseWriter, r *http.Request, path string) {
	id, ok := sessionID(path)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if !strings.Contains(strings.ToLower(r.Header.Get("Content-Type")), "application/trickle-ice-sdpfrag") {
		writeError(w, http.StatusBadRequest, "expected application/trickle-ice-sdpfrag")
		return
	}
	body, err := readBody(w, r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read candidates")
		return
	}
	if err := s.addCandidates(id, string(body)); err != nil {
		if errors.Is(err, errNoSession) {
			http.NotFound(w, r)
			return
		}
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) currentTitle() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.title == "" {
		return "RoomCast Broadcast"
	}
	return s.title
}

func (s *server) writeBytes(w http.ResponseWriter, status int, contentType string, body []byte, head bool) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Length", itoa(len(body)))
	w.WriteHeader(status)
	if !head {
		_, _ = w.Write(body)
	}
}

func allowWHEP(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Expose-Headers", "Location, ETag, Link")
	w.Header().Set("Access-Control-Allow-Methods", "OPTIONS, GET, HEAD, POST, PATCH, DELETE")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, If-Match, Authorization")
}

func writeError(w http.ResponseWriter, status int, message string) {
	body, _ := json.Marshal(map[string]string{"error": message})
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	defer r.Body.Close()
	return io.ReadAll(r.Body)
}

func isSessionPath(path string) bool {
	_, ok := sessionID(path)
	return ok
}

func sessionID(path string) (string, bool) {
	for _, prefix := range []string{"/whep/", "/live/whep/"} {
		if strings.HasPrefix(path, prefix) {
			id := strings.TrimPrefix(path, prefix)
			if validID(id) {
				return id, true
			}
		}
	}
	return "", false
}

func validID(id string) bool {
	if len(id) < 16 || len(id) > 64 {
		return false
	}
	for _, r := range id {
		switch {
		case r >= '0' && r <= '9':
		case r >= 'a' && r <= 'f':
		default:
			return false
		}
	}
	return true
}

func itoa(n int) string {
	return fmtInt(n)
}

func fmtInt(n int) string {
	if n == 0 {
		return "0"
	}
	var b [16]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

func isAddrInUse(err error) bool {
	var op *net.OpError
	if errors.As(err, &op) {
		return strings.Contains(strings.ToLower(op.Err.Error()), "address already in use")
	}
	return strings.Contains(strings.ToLower(err.Error()), "address already in use")
}
