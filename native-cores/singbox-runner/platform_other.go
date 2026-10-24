//go:build !android

package main

import "context"

func registerPlatform(context.Context) error { return nil }
