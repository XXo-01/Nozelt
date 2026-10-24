//go:build windows

package main

import (
	"net/url"
	"regexp"
	"strings"
)

var credentialLogField = regexp.MustCompile(`(?i)(?:["']?(?:password|passwd|pass|uuid|private[_-]?key|secret|token|authorization)["']?)\s*[:=]\s*`)
var logURL = regexp.MustCompile(`(?i)(?:https?|socks5?|vless|vmess|trojan|ssr?)://[^\s"'<>]+`)

func privateLogMessage(message string) string {
	// A malformed configuration can dump whole credential-bearing objects.
	// Omit such diagnostics before either the GUI or its export sees them.
	if credentialLogField.MatchString(message) {
		return "Sensitive diagnostic omitted (credentials/configuration)."
	}
	return logURL.ReplaceAllStringFunc(message, func(text string) string {
		value, err := url.Parse(text)
		if err != nil || (value.Scheme != "http" && value.Scheme != "https") {
			return "<private URL>"
		}
		return strings.ToLower(value.Scheme) + "://" + value.Host + "/<private path>"
	})
}
