//go:build !windows && !darwin

// astat-helper собирается под Windows и macOS. Эта заглушка нужна, чтобы проверки и тесты шли на любой системе.
package main

import (
	"fmt"
	"os"

	_ "astatvpn/core/internal/helper"
)

func main() {
	fmt.Fprintln(os.Stderr, "astat-helper работает только в Windows и macOS")
	os.Exit(1)
}
