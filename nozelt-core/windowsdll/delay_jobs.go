//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"strconv"
	"sync"
	"time"

	"github.com/nozelt/nozelt-core/core"
)

const maxDesktopDelayJobs = 8

type desktopDelayUpdate struct {
	Name  string `json:"name"`
	Delay int    `json:"delay"`
}

type desktopDelayJob struct {
	sync.Mutex
	created  time.Time
	updates  []desktopDelayUpdate
	response string
	done     bool
}

var desktopDelayJobs = struct {
	sync.Mutex
	next uint64
	jobs map[uint64]*desktopDelayJob
}{jobs: make(map[uint64]*desktopDelayJob)}

func beginDesktopDelayJob(
	kind, config, names, targets, testURL string,
	timeoutMs int,
	offline bool,
) string {
	if kind != runtimeMihomo && kind != runtimeXray && kind != runtimeSingBox {
		return resultJSON(errors.New("unsupported core"))
	}
	desktopDelayJobs.Lock()
	for id, job := range desktopDelayJobs.jobs {
		job.Lock()
		stale := time.Since(job.created) > 2*time.Minute
		job.Unlock()
		if stale {
			delete(desktopDelayJobs.jobs, id)
		}
	}
	if len(desktopDelayJobs.jobs) >= maxDesktopDelayJobs {
		desktopDelayJobs.Unlock()
		return resultJSON(errors.New("too many delay jobs"))
	}
	desktopDelayJobs.next++
	id := desktopDelayJobs.next
	job := &desktopDelayJob{
		created: time.Now(),
		updates: make([]desktopDelayUpdate, 0, 32),
	}
	desktopDelayJobs.jobs[id] = job
	desktopDelayJobs.Unlock()

	publish := func(name string, delay int) {
		job.Lock()
		job.updates = append(job.updates, desktopDelayUpdate{
			Name: name, Delay: delay,
		})
		job.Unlock()
	}
	go func() {
		var response string
		switch kind {
		case runtimeMihomo:
			if offline {
				response = core.TestProxyDelaysOfflineStream(
					config, names, testURL, timeoutMs, publish,
				)
			} else {
				response = core.TestProxyDelaysStream(
					config, names, testURL, timeoutMs, publish,
				)
			}
		case runtimeXray, runtimeSingBox:
			response = testExternalProxyDelaysStream(
				kind, targets, timeoutMs, publish,
			)
		}
		job.Lock()
		job.response = response
		job.done = true
		job.Unlock()
	}()

	encoded, _ := json.Marshal(map[string]any{
		"ok": true, "jobId": strconv.FormatUint(id, 10),
	})
	return string(encoded)
}

func pollDesktopDelayJob(rawID string) string {
	id, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil {
		return resultJSON(errors.New("invalid delay job"))
	}
	desktopDelayJobs.Lock()
	job := desktopDelayJobs.jobs[id]
	desktopDelayJobs.Unlock()
	if job == nil {
		return resultJSON(errors.New("delay job unavailable"))
	}

	job.Lock()
	updates := append([]desktopDelayUpdate(nil), job.updates...)
	job.updates = job.updates[:0]
	done := job.done
	response := job.response
	job.Unlock()
	if done {
		desktopDelayJobs.Lock()
		delete(desktopDelayJobs.jobs, id)
		desktopDelayJobs.Unlock()
	}
	encoded, _ := json.Marshal(map[string]any{
		"ok":       true,
		"done":     done,
		"updates":  updates,
		"response": response,
	})
	return string(encoded)
}

func cancelDesktopDelayJobs() {
	core.CancelDelayTests()
	cancelExternalDelayTests()
}
