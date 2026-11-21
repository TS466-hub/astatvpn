package engine

import (
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"astatvpn/core/internal/proto"
)

type fakeSession struct {
	closed atomic.Int32
	rx, tx atomic.Uint64
	noStat atomic.Bool
}

func (s *fakeSession) Close() error { s.closed.Add(1); return nil }
func (s *fakeSession) Counters() (uint64, uint64, bool) {
	return s.rx.Load(), s.tx.Load(), !s.noStat.Load()
}

type fakeBackend struct {
	mu       sync.Mutex
	started  []string
	sessions []*fakeSession
	fail     error
	gate     chan struct{} // если задан, Start ждёт
	running  atomic.Int32
	maxRun   atomic.Int32
	pings    [][]string
	initRx   uint64
}

func (b *fakeBackend) Start(config string) (Session, error) {
	n := b.running.Add(1)
	defer b.running.Add(-1)
	if n > b.maxRun.Load() {
		b.maxRun.Store(n)
	}
	if b.gate != nil {
		<-b.gate
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.started = append(b.started, config)
	if b.fail != nil {
		return nil, b.fail
	}
	s := &fakeSession{}
	s.rx.Store(b.initRx)
	b.sessions = append(b.sessions, s)
	return s, nil
}

func (b *fakeBackend) Ping(configs []string) []int {
	b.mu.Lock()
	b.pings = append(b.pings, configs)
	b.mu.Unlock()
	out := make([]int, len(configs))
	for i := range out {
		out[i] = 100 + i
	}
	return out
}

type fakeSanitizer struct{}

func (fakeSanitizer) Tunnel(raw string) (string, error) {
	if strings.Contains(raw, "bad") {
		return "", errors.New("Конфигурация отклонена: тест")
	}
	return "clean:" + raw, nil
}
func (fakeSanitizer) Probe(raw string) (string, error) {
	if strings.Contains(raw, "bad") {
		return "", errors.New("отказ")
	}
	return "probe:" + raw, nil
}

func newEngine(b *fakeBackend) *Engine {
	e := New(b, fakeSanitizer{})
	e.tick = 10 * time.Millisecond
	return e
}

// states собирает состояния, которые видит подписчик
func collect(sub *Subscription, until func(proto.Status) bool) []proto.Status {
	var out []proto.Status
	deadline := time.After(3 * time.Second)
	for {
		select {
		case <-sub.C():
			if st, ok := sub.Take(); ok {
				out = append(out, st)
				if until(st) {
					return out
				}
			}
		case <-deadline:
			return out
		}
	}
}

func TestStartStop(t *testing.T) {
	b := &fakeBackend{}
	e := newEngine(b)
	if st := e.Status(); st.State != proto.StateDisconnected || st.Error != nil || st.Name != nil || st.Since != 0 {
		t.Fatalf("начальное состояние: %+v", st)
	}
	if err := e.Start("cfg", "NL"); err != nil {
		t.Fatal(err)
	}
	st := e.Status()
	if st.State != proto.StateConnected || st.Name == nil || *st.Name != "NL" || st.Since == 0 || st.Error != nil {
		t.Fatalf("после запуска: %+v", st)
	}
	if len(b.started) != 1 || b.started[0] != "clean:cfg" {
		t.Fatalf("ядро получило непроверенную конфигурацию: %v", b.started)
	}
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	if st := e.Status(); st.State != proto.StateDisconnected || st.Name != nil || st.Since != 0 || st.Rx != 0 {
		t.Fatalf("после остановки: %+v", st)
	}
	if b.sessions[0].closed.Load() != 1 {
		t.Fatal("ядро не остановлено")
	}
	// повторная остановка безвредна
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	if b.sessions[0].closed.Load() != 1 {
		t.Fatal("ядро остановлено дважды")
	}
}

func TestRejectedConfigDoesNotTouchRunningSession(t *testing.T) {
	b := &fakeBackend{}
	e := newEngine(b)
	if err := e.Start("cfg", "NL"); err != nil {
		t.Fatal(err)
	}
	if err := e.Start("bad", "X"); err == nil {
		t.Fatal("ожидался отказ")
	}
	if st := e.Status(); st.State != proto.StateConnected || *st.Name != "NL" {
		t.Fatalf("подключение пострадало: %+v", st)
	}
	if len(b.started) != 1 || b.sessions[0].closed.Load() != 0 {
		t.Fatal("ядро перезапускалось")
	}
}

func TestStartFailure(t *testing.T) {
	b := &fakeBackend{fail: errors.New("нет wintun.dll")}
	e := newEngine(b)
	sub := e.Subscribe()
	defer sub.Close()
	err := e.Start("cfg", "NL")
	if err == nil || !strings.Contains(err.Error(), "нет wintun.dll") {
		t.Fatalf("err = %v", err)
	}
	st := e.Status()
	if st.State != proto.StateDisconnected || st.Error == nil || !strings.Contains(*st.Error, "нет wintun.dll") || st.Name != nil {
		t.Fatalf("%+v", st)
	}
	// остановка сбрасывает ошибку
	_ = e.Stop()
	if e.Status().Error != nil {
		t.Fatal("ошибка не сброшена")
	}
}

func TestRestartReplacesSession(t *testing.T) {
	b := &fakeBackend{}
	e := newEngine(b)
	_ = e.Start("a", "A")
	sub := e.Subscribe()
	defer sub.Close()
	if err := e.Start("b", "B"); err != nil {
		t.Fatal(err)
	}
	if b.sessions[0].closed.Load() != 1 || b.sessions[1].closed.Load() != 0 {
		t.Fatal("прежнее ядро не остановлено")
	}
	if st := e.Status(); st.State != proto.StateConnected || *st.Name != "B" {
		t.Fatalf("%+v", st)
	}
}

func TestEvents(t *testing.T) {
	b := &fakeBackend{gate: make(chan struct{})}
	e := newEngine(b)
	sub := e.Subscribe()
	defer sub.Close()
	// текущее состояние приходит сразу после подписки
	first := collect(sub, func(proto.Status) bool { return true })
	if len(first) != 1 || first[0].State != proto.StateDisconnected {
		t.Fatalf("%+v", first)
	}

	done := make(chan error, 1)
	go func() { done <- e.Start("cfg", "NL") }()
	got := collect(sub, func(st proto.Status) bool { return st.State == proto.StateConnecting })
	if len(got) == 0 || got[len(got)-1].State != proto.StateConnecting || *got[len(got)-1].Name != "NL" {
		t.Fatalf("нет события connecting: %+v", got)
	}
	close(b.gate)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	got = collect(sub, func(st proto.Status) bool { return st.State == proto.StateConnected })
	if len(got) == 0 || got[len(got)-1].State != proto.StateConnected {
		t.Fatalf("нет события connected: %+v", got)
	}

	// счётчики приходят раз в такт
	b.sessions[0].rx.Store(1000)
	b.sessions[0].tx.Store(200)
	got = collect(sub, func(st proto.Status) bool { return st.Rx == 1000 && st.Tx == 200 })
	if len(got) == 0 || got[len(got)-1].Rx != 1000 {
		t.Fatalf("нет счётчиков: %+v", got)
	}

	go e.Stop()
	got = collect(sub, func(st proto.Status) bool { return st.State == proto.StateDisconnected })
	if len(got) == 0 || got[len(got)-1].State != proto.StateDisconnected {
		t.Fatalf("нет события disconnected: %+v", got)
	}
}

func TestCountersBaseline(t *testing.T) {
	b := &fakeBackend{initRx: 5000}
	e := newEngine(b)
	_ = e.Start("cfg", "NL")
	s := b.sessions[0]
	wait := func(want uint64) {
		t.Helper()
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			if e.Status().Rx == want {
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatalf("rx = %d, want %d", e.Status().Rx, want)
	}
	s.rx.Store(5700)
	wait(700)
	// счётчики недоступны: остаётся прежнее значение
	s.noStat.Store(true)
	s.rx.Store(9999)
	time.Sleep(40 * time.Millisecond)
	wait(700)
	// адаптер пересоздан, счётчик начался с нуля
	s.noStat.Store(false)
	s.rx.Store(30)
	wait(30)
	_ = e.Stop()
}

func TestOneOperationAtATime(t *testing.T) {
	b := &fakeBackend{gate: make(chan struct{})}
	e := newEngine(b)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _ = e.Start("cfg", "NL") }()
	}
	time.Sleep(50 * time.Millisecond)
	// пока идёт запуск, замер не ждёт, а сразу отказывает; состояние читается без ожидания
	if _, err := e.Ping([]string{"x"}); !errors.Is(err, ErrBusy) {
		t.Fatalf("err = %v", err)
	}
	if st := e.Status(); st.State != proto.StateConnecting {
		t.Fatalf("%+v", st)
	}
	close(b.gate)
	wg.Wait()
	if b.maxRun.Load() != 1 {
		t.Fatalf("одновременных запусков ядра: %d", b.maxRun.Load())
	}
	open := 0
	for _, s := range b.sessions {
		if s.closed.Load() == 0 {
			open++
		}
	}
	if open != 1 {
		t.Fatalf("работающих ядер: %d", open)
	}
}

func TestPing(t *testing.T) {
	b := &fakeBackend{}
	e := newEngine(b)
	delays, err := e.Ping([]string{"a", "bad", "c"})
	if err != nil {
		t.Fatal(err)
	}
	if len(delays) != 3 || delays[0] != 100 || delays[1] != -1 || delays[2] != 101 {
		t.Fatalf("%v", delays)
	}
	if len(b.pings) != 1 || len(b.pings[0]) != 2 || b.pings[0][0] != "probe:a" {
		t.Fatalf("ядро получило: %v", b.pings)
	}
	if delays, err := e.Ping(nil); err != nil || len(delays) != 0 {
		t.Fatalf("%v %v", delays, err)
	}
	if _, err := e.Ping(make([]string, proto.MaxPingConfigs+1)); err == nil {
		t.Fatal("ожидался отказ")
	}
	_ = e.Start("cfg", "NL")
	if _, err := e.Ping([]string{"a"}); !errors.Is(err, ErrBusy) {
		t.Fatalf("err = %v", err)
	}
}

func TestSlowSubscriberDoesNotBlock(t *testing.T) {
	b := &fakeBackend{}
	e := newEngine(b)
	sub := e.Subscribe() // никто не читает
	defer sub.Close()
	done := make(chan struct{})
	go func() {
		for i := 0; i < 200; i++ {
			_ = e.Start("cfg", "NL")
			_ = e.Stop()
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("служба ждёт медленного получателя")
	}
	// получатель видит только последнее состояние
	<-sub.C()
	if st, ok := sub.Take(); !ok || st.State != proto.StateDisconnected {
		t.Fatalf("%+v %v", st, ok)
	}
	if _, ok := sub.Take(); ok {
		t.Fatal("очередь не должна копиться")
	}
}
