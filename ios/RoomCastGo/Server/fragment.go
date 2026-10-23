package roomcast

import (
	"log"
	"strconv"
	"strings"

	"github.com/pion/webrtc/v4"
)

// applyICEFragment reads the trickle body MediaMTX reader.js sends:
//
//	a=ice-ufrag:…
//	a=ice-pwd:…
//	m=audio …
//	a=mid:1
//	a=candidate:…
func applyICEFragment(pc *webrtc.PeerConnection, fragment string) error {
	var mid string
	var haveMid bool
	for _, line := range splitLines(fragment) {
		switch {
		case strings.HasPrefix(line, "a=mid:"):
			mid = strings.TrimPrefix(line, "a=mid:")
			haveMid = true
		case strings.HasPrefix(line, "a=candidate:"), strings.HasPrefix(line, "candidate:"):
			cand := strings.TrimPrefix(line, "a=")
			init := webrtc.ICECandidateInit{Candidate: cand}
			if haveMid {
				m := mid
				init.SDPMid = &m
				if n, err := strconv.Atoi(mid); err == nil && n >= 0 && n <= 65535 {
					index := uint16(n)
					init.SDPMLineIndex = &index
				}
			}
			if err := pc.AddICECandidate(init); err != nil {
				log.Printf("ignored an ICE candidate: %v", err)
			}
		}
	}
	return nil
}

func splitLines(text string) []string {
	raw := strings.Split(text, "\n")
	lines := make([]string, 0, len(raw))
	for _, line := range raw {
		line = strings.TrimRight(line, "\r")
		line = strings.TrimSpace(line)
		if line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}
