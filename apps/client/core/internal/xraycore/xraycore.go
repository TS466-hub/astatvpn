// Package xraycore запускает ядро Xray внутри службы, без отдельного xray.exe.
package xraycore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/common/platform/filesystem"
	xsession "github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"

	"astatvpn/core/internal/engine"
)

const (
	// HelperVersion — версия службы.
	HelperVersion = "0.1.1"

	// как в сборке для Android
	pingURL = "https://www.gstatic.com/generate_204"
	// первый запрос включает установку соединения с сервером и с сайтом проверки, поэтому ему дано больше времени
	pingTimeout = 4 * time.Second
	// повторный запрос идёт по готовому соединению: это и есть задержка
	pingRepeatTimeout = 2 * time.Second
	pingWorkers       = 16
)

// Version — версия ядра, например "26.11.9".
func Version() string { return core.Version() }

// LockDown привязывает ядро к каталогу службы. Вызывается один раз при старте, до запуска ядра.
//
// Ядро читает часть настроек из переменных окружения (каталог геоданных, адрес «браузерного» канала,
// дескриптор TUN и другие). Все они сбрасываются, а геоданные читаются только из каталога рядом с exe.
// Любые другие файлы ядру через его общий загрузчик недоступны.
func LockDown(dir string) {
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		lower := strings.ToLower(name)
		if strings.HasPrefix(lower, "xray.") || strings.HasPrefix(lower, "xray_") || strings.HasPrefix(lower, "v2ray.") || strings.HasPrefix(lower, "v2ray_") {
			os.Unsetenv(name)
		}
	}
	os.Setenv(platform.AssetLocation, dir)
	os.Setenv(platform.NormalizeEnvName(platform.AssetLocation), dir)

	allowed := map[string]bool{
		strings.ToLower(filepath.Join(dir, "geoip.dat")):   true,
		strings.ToLower(filepath.Join(dir, "geosite.dat")): true,
	}
	filesystem.NewFileReader = func(path string) (io.ReadCloser, error) {
		abs, err := filepath.Abs(path)
		if err != nil || !allowed[strings.ToLower(filepath.Clean(abs))] {
			return nil, errors.New("служба не читает посторонние файлы: " + filepath.Base(path))
		}
		return os.Open(abs)
	}
}

// Backend запускает ядро по проверенной конфигурации.
type Backend struct {
	// Counters читает счётчики сетевого адаптера. Зависит от системы.
	Counters func() (rx, tx uint64, ok bool)
	// PreStart проверяет, что всё нужное для запуска на месте, и убирает следы прошлого сбоя.
	PreStart func() error
	// PostStop вызывается после остановки ядра и при неудачном запуске: возвращает системе то, что менял PreStart.
	PostStop func()

	// для тестов
	pingURL string
}

type session struct {
	instance *core.Instance
	counters func() (rx, tx uint64, ok bool)
	postStop func()
	once     sync.Once
	err      error
}

func (s *session) Close() error {
	s.once.Do(func() {
		defer func() {
			if r := recover(); r != nil {
				s.err = fmt.Errorf("сбой при остановке ядра: %v", r)
			}
		}()
		s.err = s.instance.Close()
		if s.postStop != nil {
			s.postStop()
		}
	})
	return s.err
}

func (s *session) Counters() (uint64, uint64, bool) {
	if s.counters == nil {
		return 0, 0, false
	}
	return s.counters()
}

func newInstance(config string) (*core.Instance, error) {
	parsed, err := core.LoadConfig("json", strings.NewReader(config))
	if err != nil {
		return nil, err
	}
	return core.New(parsed)
}

// Start запускает ядро. Ошибка в конфигурации не должна ронять службу, поэтому сбои перехватываются.
func (b *Backend) Start(config string) (sess engine.Session, err error) {
	var instance *core.Instance
	defer func() {
		if r := recover(); r != nil {
			if instance != nil {
				func() {
					defer func() { _ = recover() }()
					_ = instance.Close()
				}()
			}
			sess, err = nil, fmt.Errorf("сбой ядра: %v", r)
		}
		if err != nil {
			Logf("запуск не удался: " + err.Error())
		}
	}()
	if b.PreStart != nil {
		if err := b.PreStart(); err != nil {
			return nil, err
		}
	}
	// всё, что изменил PreStart, возвращается и при неудачном запуске
	started := false
	defer func() {
		// срабатывает и при сбое ядра: сам сбой перехватывает обработчик выше
		if !started && b.PostStop != nil {
			b.PostStop()
		}
	}()
	instance, err = newInstance(config)
	if err != nil {
		return nil, err
	}
	if err = instance.Start(); err != nil {
		_ = instance.Close()
		return nil, err
	}
	started = true
	Logf("ядро запущено")
	return &session{instance: instance, counters: b.Counters, postStop: b.PostStop}, nil
}

// Ping замеряет задержку через каждую конфигурацию: время запроса HEAD по уже установленному соединению.
// Установка соединения (рукопожатия с сервером и с сайтом проверки, три-четыре обмена) в число не входит:
// иначе выходит в несколько раз больше настоящей задержки.
//
// Все серверы замеряются одним ядром без входов (локальные порты не открываются): исходящие каналы
// каждой конфигурации получают свои метки, а запрос направляется в нужный канал по метке.
// Несколько ядер одновременно запускать нельзя: часть состояния Xray (резолвер и цепочки dialerProxy)
// общая на процесс и досталась бы последнему запущенному.
func (b *Backend) Ping(configs []string) []int {
	delays := make([]int, len(configs))
	var targets []pingTarget
	for i, config := range configs {
		delays[i] = -1
		outbounds, tag, err := namespaceOutbounds(config, i)
		if err != nil {
			continue
		}
		target := pingTarget{index: i, tag: tag, outbounds: outbounds}
		// по отдельности, чтобы одна негодная конфигурация не испортила замер остальных
		if !loads(target.config()) {
			continue
		}
		targets = append(targets, target)
	}
	if len(targets) == 0 {
		return delays
	}
	if !b.pingGroup(targets, delays) {
		// общее ядро не запустилось: замеряем по одному
		for _, target := range targets {
			b.pingGroup([]pingTarget{target}, delays)
		}
	}
	return delays
}

type pingTarget struct {
	index     int
	tag       string
	outbounds []any
}

func (t pingTarget) config() string { return probeConfig(t.outbounds) }

func probeConfig(outbounds []any) string {
	data, _ := json.Marshal(map[string]any{
		"log":       map[string]any{"loglevel": "none"},
		"outbounds": outbounds,
	})
	return string(data)
}

func loads(config string) (ok bool) {
	defer func() {
		if r := recover(); r != nil {
			ok = false
		}
	}()
	_, err := core.LoadConfig("json", strings.NewReader(config))
	return err == nil
}

// key находит поле без учёта регистра, как это делает ядро.
func key(m map[string]any, name string) (string, bool) {
	if _, ok := m[name]; ok {
		return name, true
	}
	for k := range m {
		if strings.EqualFold(k, name) {
			return k, true
		}
	}
	return "", false
}

// namespaceOutbounds даёт исходящим каналам конфигурации метки, не пересекающиеся с другими конфигурациями,
// и возвращает метку канала, через который идёт замер: с меткой "proxy", а если такого нет — первого.
func namespaceOutbounds(config string, n int) ([]any, string, error) {
	dec := json.NewDecoder(strings.NewReader(config))
	dec.UseNumber()
	var root map[string]any
	if err := dec.Decode(&root); err != nil {
		return nil, "", err
	}
	k, ok := key(root, "outbounds")
	list, _ := root[k].([]any)
	if !ok || len(list) == 0 {
		return nil, "", errors.New("нет исходящих подключений")
	}
	renamed := make(map[string]string, len(list))
	target := ""
	for i, item := range list {
		outbound, ok := item.(map[string]any)
		if !ok {
			return nil, "", errors.New("исходящее подключение должно быть объектом")
		}
		tag := fmt.Sprintf("ping-%d-%d", n, i)
		if k, ok := key(outbound, "tag"); ok {
			if old, _ := outbound[k].(string); old != "" {
				if _, dup := renamed[old]; !dup {
					renamed[old] = tag
				}
				if old == "proxy" && target == "" {
					target = tag
				}
			}
			delete(outbound, k)
		}
		outbound["tag"] = tag
	}
	if target == "" {
		target = fmt.Sprintf("ping-%d-0", n)
	}
	// ссылки на соседние каналы: sockopt.dialerProxy (в том числе во вложенных настройках) и proxySettings.tag
	var relink func(v any)
	relink = func(v any) {
		switch t := v.(type) {
		case map[string]any:
			for k, value := range t {
				if s, ok := value.(string); ok && strings.EqualFold(k, "dialerProxy") {
					if tag, ok := renamed[s]; ok {
						t[k] = tag
					}
					continue
				}
				relink(value)
			}
		case []any:
			for _, item := range t {
				relink(item)
			}
		}
	}
	for _, item := range list {
		outbound := item.(map[string]any)
		for k, value := range outbound {
			if strings.EqualFold(k, "tag") {
				continue
			}
			if proxy, ok := value.(map[string]any); ok && strings.EqualFold(k, "proxySettings") {
				if tk, ok := key(proxy, "tag"); ok {
					if s, _ := proxy[tk].(string); renamed[s] != "" {
						proxy[tk] = renamed[s]
					}
				}
				continue
			}
			relink(value)
		}
	}
	return list, target, nil
}

// pingGroup запускает одно ядро с каналами всех целей и замеряет их параллельно.
// false — ядро не запустилось, задержки не тронуты.
func (b *Backend) pingGroup(targets []pingTarget, delays []int) (started bool) {
	var instance *core.Instance
	defer func() {
		if r := recover(); r != nil {
			started = false
		}
		if instance != nil {
			func() {
				defer func() { _ = recover() }()
				_ = instance.Close()
			}()
		}
	}()
	var outbounds []any
	for _, target := range targets {
		outbounds = append(outbounds, target.outbounds...)
	}
	instance, err := newInstance(probeConfig(outbounds))
	if err != nil {
		return false
	}
	if err := instance.Start(); err != nil {
		return false
	}

	jobs := make(chan pingTarget)
	var wg sync.WaitGroup
	for range min(pingWorkers, len(targets)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for target := range jobs {
				delays[target.index] = b.probe(instance, target.tag)
			}
		}()
	}
	for _, target := range targets {
		jobs <- target
	}
	close(jobs)
	wg.Wait()
	return true
}

func (b *Backend) probe(instance *core.Instance, tag string) (delay int) {
	defer func() {
		if r := recover(); r != nil {
			delay = -1
		}
	}()
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			dest, err := xnet.ParseDestination("tcp:" + address)
			if err != nil {
				return nil, err
			}
			return core.Dial(xsession.SetForcedOutboundTagToContext(ctx, tag), instance, dest)
		},
	}
	defer transport.CloseIdleConnections()

	url := b.pingURL
	if url == "" {
		url = pingURL
	}
	request := func(timeout time.Duration) (time.Duration, bool) {
		req, err := http.NewRequest(http.MethodHead, url, nil)
		if err != nil {
			return 0, false
		}
		client := &http.Client{Transport: transport, Timeout: timeout}
		start := time.Now()
		resp, err := client.Do(req)
		elapsed := time.Since(start)
		if err != nil {
			return 0, false
		}
		// тело нужно дочитать, иначе соединение не вернётся для повторного запроса
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		return elapsed, true
	}

	first, ok := request(pingTimeout)
	if !ok {
		return -1
	}
	best := first
	// два повторных запроса, берём лучший: случайная задержка одного пакета не искажает число
	for range 2 {
		if again, ok := request(pingRepeatTimeout); ok && again < best {
			best = again
		}
	}
	return max(1, int(best.Milliseconds()))
}
