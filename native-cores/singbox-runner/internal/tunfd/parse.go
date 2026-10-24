// Package tunfd parses the optional Android VpnService descriptor inherited
// by the sing-box runner.
package tunfd

import (
	"fmt"
	"strconv"
)

// Parse deliberately permits an absent descriptor. The VPN service supplies
// one for normal TUN operation, while native health checks use a loopback
// SOCKS inbound and must not manufacture a fake TUN descriptor.
func Parse(raw string) (descriptor int, present bool, err error) {
	if raw == "" {
		return 0, false, nil
	}
	descriptor, err = strconv.Atoi(raw)
	if err != nil || descriptor < 3 {
		return 0, false, fmt.Errorf("expected an integer descriptor of at least 3")
	}
	return descriptor, true, nil
}
