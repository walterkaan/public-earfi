package roomcast

import "testing"

func TestSelectHost(t *testing.T) {
	cases := []struct {
		name  string
		table string
		want  string
	}{
		{
			name:  "hotspot beats wifi and cellular",
			table: "en0 192.168.1.20\npdp_ip0 10.2.3.4\nbridge100 172.20.10.1",
			want:  "bridge100 172.20.10.1",
		},
		{
			name:  "wifi beats cellular",
			table: "pdp_ip0 10.2.3.4\nen0 192.168.1.20",
			want:  "en0 192.168.1.20",
		},
		{
			name:  "cellular only",
			table: "pdp_ip0 10.2.3.4",
			want:  "",
		},
		{
			name:  "link local and loopback",
			table: "en0 169.254.1.1\nlo0 127.0.0.1",
			want:  "",
		},
		{
			name:  "vpn and awdl",
			table: "awdl0 192.168.1.5\nutun0 10.0.0.2\nipsec0 10.1.1.1",
			want:  "",
		},
		{
			name:  "hotspot address on ap",
			table: "ap1 172.20.10.1",
			want:  "ap1 172.20.10.1",
		},
		{
			name:  "en0 before other ethernet",
			table: "en1 10.0.0.8\nen0 192.168.0.2",
			want:  "en0 192.168.0.2",
		},
		{
			name:  "usb ethernet when wifi has no address",
			table: "en2 192.168.8.4",
			want:  "en2 192.168.8.4",
		},
		{
			name:  "public address is not a lan",
			table: "en0 8.8.8.8",
			want:  "",
		},
		{name: "empty", table: "", want: ""},
		{name: "garbage", table: "not an interface", want: ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := SelectHost(tc.table); got != tc.want {
				t.Fatalf("SelectHost() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestSanitizeTitle(t *testing.T) {
	if got := sanitizeTitle("  Room   Cast  "); got != "Room Cast" {
		t.Fatalf("collapsed title = %q", got)
	}
	if got := sanitizeTitle("\x00<script>"); got != "<script>" {
		t.Fatalf("control strip = %q", got)
	}
	if got := sanitizeTitle("   "); got != "RoomCast Broadcast" {
		t.Fatalf("blank title = %q", got)
	}
}
