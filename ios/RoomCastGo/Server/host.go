package roomcast

import (
	"net"
	"strings"
)

// SelectHost picks the IPv4 address listeners can open.
//
// table is one interface per line: "name address". Personal Hotspot wins,
// then Wi-Fi. Cellular, VPN, and link-local addresses are ignored. The
// result is "name address", or "" when the phone has nowhere to host.
func SelectHost(table string) string {
	rows := parseHostTable(table)
	if row, ok := firstHost(rows, func(name, ip string) bool {
		return ip == "172.20.10.1" && !hardSkippedIface(name) && privateIPv4(ip)
	}); ok {
		return row
	}
	if row, ok := firstHost(rows, func(name, ip string) bool {
		return strings.HasPrefix(name, "bridge") && !skippedIface(name) && privateIPv4(ip)
	}); ok {
		return row
	}
	if row, ok := firstHost(rows, func(name, ip string) bool {
		return name == "en0" && privateIPv4(ip)
	}); ok {
		return row
	}
	if row, ok := firstHost(rows, func(name, ip string) bool {
		return strings.HasPrefix(name, "en") && privateIPv4(ip)
	}); ok {
		return row
	}
	return ""
}

func parseHostTable(table string) [][2]string {
	var rows [][2]string
	for _, line := range strings.Split(table, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		rows = append(rows, [2]string{fields[0], fields[1]})
	}
	return rows
}

func firstHost(rows [][2]string, match func(name, ip string) bool) (string, bool) {
	for _, row := range rows {
		if match(row[0], row[1]) {
			return row[0] + " " + row[1], true
		}
	}
	return "", false
}

func skippedIface(name string) bool {
	return hardSkippedIface(name) || strings.HasPrefix(name, "ap")
}

func hardSkippedIface(name string) bool {
	switch {
	case name == "":
		return true
	case name == "lo" || strings.HasPrefix(name, "lo"):
		return true
	case strings.HasPrefix(name, "awdl"):
		return true
	case strings.HasPrefix(name, "llw"):
		return true
	case strings.HasPrefix(name, "utun"):
		return true
	case strings.HasPrefix(name, "ipsec"):
		return true
	case strings.HasPrefix(name, "pdp_ip"):
		return true
	case strings.HasPrefix(name, "rmnet"):
		return true
	default:
		return false
	}
}

func privateIPv4(address string) bool {
	ip := net.ParseIP(address).To4()
	if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsMulticast() || ip.IsUnspecified() {
		return false
	}
	switch {
	case ip[0] == 10:
		return true
	case ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31:
		return true
	case ip[0] == 192 && ip[1] == 168:
		return true
	default:
		return false
	}
}

func safeIfaceName(name string) string {
	if name == "" || len(name) > 32 {
		return ""
	}
	for _, r := range name {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-'
		if !ok {
			return ""
		}
	}
	return name
}
