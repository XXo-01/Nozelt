package core

import (
	mlog "github.com/metacubex/mihomo/log"

	"github.com/nozelt/nozelt-core/logger"
)

// init wires mihomo's internal log stream into our host-supplied Logger
// callback. mihomo publishes log events via an observable channel returned by
// log.Subscribe(); we spin up exactly one goroutine for the lifetime of the
// process to forward those events.
//
// Why init() and not lazily on Start():
//
//   - The subscription must be live before executor.ApplyConfig runs,
//     otherwise the early "Listening at..." / config-parse messages are lost.
//   - There is no per-process resource to release: log.UnSubscribe only
//     matters if you intend to detach. Keeping one long-lived forwarder
//     mirrors mihomo's own assumption that logs flow for the whole process.
//   - The subscription channel is unbounded but mihomo throttles publish
//     volume, so memory growth is bounded by the host Logger's drain rate.
func init() {
	sub := mlog.Subscribe()
	go func() {
		for event := range sub {
			level := mihomoLevelToString(event.LogLevel)
			if level == "" {
				// SILENT or unknown — drop without forwarding.
				continue
			}
			logger.Emit(level, event.Payload)
		}
	}()
}

// mihomoLevelToString maps mihomo's log.LogLevel enum to the string levels
// our logger.Logger interface expects. SILENT returns "" so the caller can
// short-circuit; any future unknown level falls through to info to avoid
// silently dropping a real message.
func mihomoLevelToString(l mlog.LogLevel) string {
	switch l {
	case mlog.DEBUG:
		return logger.LevelDebug
	case mlog.INFO:
		return logger.LevelInfo
	case mlog.WARNING:
		return logger.LevelWarning
	case mlog.ERROR:
		return logger.LevelError
	case mlog.SILENT:
		return ""
	default:
		return logger.LevelInfo
	}
}
