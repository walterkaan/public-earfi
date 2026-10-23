package roomcast

import (
	"strings"
	"testing"
)

func TestListenerPageMatchesMacContract(t *testing.T) {
	html := listenerHTML(`Room <Cast> & "live"`)
	for _, needle := range []string{
		"Powered by RoomCast",
		"https://roomcast.channel",
		"/reader.js",
		"/whep",
		"/earfi.json",
		"Waiting for the host to start",
		"The listener page could not load.",
		"MediaMTXWebRTCReader",
		"Room &lt;Cast&gt; &amp; &#34;live&#34;",
	} {
		if !strings.Contains(html, needle) {
			t.Fatalf("page missing %q", needle)
		}
	}
	if strings.Contains(html, "<script>alert") || strings.Contains(html, `title">Room <Cast>`) {
		t.Fatalf("title was not escaped:\n%s", html)
	}
	if !strings.Contains(html, `"title":"Room \u003cCast\u003e \u0026 \"live\""`) &&
		!strings.Contains(html, `"title":"Room \u003cCast\u003e \u0026 \"live\""`) {
		// encoding/json escapes <, >, & only after our replacer. & becomes \u0026,
		// < and > become unicode escapes, quotes are JSON-escaped.
		if !strings.Contains(html, `\u003cCast\u003e`) || !strings.Contains(html, `\u0026`) {
			t.Fatalf("script title was not escaped:\n%s", html)
		}
	}
	if !strings.HasPrefix(string(readerJS), `"use strict";`) {
		t.Fatal("reader.js is not the MediaMTX file")
	}
	if !strings.Contains(string(readerJS), "class MediaMTXWebRTCReader") {
		t.Fatal("reader.js has no MediaMTXWebRTCReader")
	}
	if len(faviconPNG) < 8 {
		t.Fatal("favicon missing")
	}
}
