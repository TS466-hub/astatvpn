// Package helper собирает службу из частей: проверка конфигурации, состояние, ядро, обмен с приложением.
package helper

import (
	"astatvpn/core/internal/engine"
	"astatvpn/core/internal/ipc"
	"astatvpn/core/internal/sanitize"
	"astatvpn/core/internal/xraycore"
)

type sanitizer struct{}

func (sanitizer) Tunnel(raw string) (string, error) { return sanitize.Tunnel(raw) }
func (sanitizer) Probe(raw string) (string, error)  { return sanitize.Probe(raw) }

// Options — то, что зависит от системы.
type Options struct {
	// Dir — каталог службы: только оттуда читаются geoip.dat, geosite.dat и (в Windows) wintun.dll.
	Dir string
	// Counters читает счётчики сетевого адаптера.
	Counters func() (rx, tx uint64, ok bool)
	// PreStart вызывается перед каждым запуском ядра.
	PreStart func() error
	// PostStop вызывается после остановки ядра и при неудачном запуске.
	PostStop func()
}

// New готовит службу к работе. Вызывается один раз.
func New(o Options) (*ipc.Server, *engine.Engine) {
	xraycore.LockDown(o.Dir)
	backend := &xraycore.Backend{Counters: o.Counters, PreStart: o.PreStart, PostStop: o.PostStop}
	eng := engine.New(backend, sanitizer{})
	return &ipc.Server{
		Core:          eng,
		CoreVersion:   xraycore.Version(),
		HelperVersion: xraycore.HelperVersion,
		Logs:          xraycore.Logs.Text,
		Logf:          xraycore.Logf,
	}, eng
}
