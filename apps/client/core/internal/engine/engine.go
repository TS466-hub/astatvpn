// Package engine хранит состояние подключения и следит за тем, чтобы ядро запускалось и останавливалось по очереди.
package engine

import (
	"errors"
	"sync"
	"time"

	"astatvpn/core/internal/proto"
)

// Session — запущенное ядро.
type Session interface {
	// Close останавливает ядро и убирает адаптер, маршруты и фильтры.
	Close() error
	// Counters возвращает байты, прошедшие через адаптер: принятые и отправленные человеком.
	Counters() (rx, tx uint64, ok bool)
}

// Backend запускает ядро. Конфигурации сюда приходят уже проверенными.
type Backend interface {
	Start(config string) (Session, error)
	Ping(configs []string) []int
}

// Sanitizer проверяет конфигурацию от приложения.
type Sanitizer interface {
	Tunnel(raw string) (string, error)
	Probe(raw string) (string, error)
}

// ErrBusy — замер задержки запрошен при работающем подключении.
var ErrBusy = errors.New("Замер задержки работает только при выключенном VPN")

// Engine — состояние службы. Все методы можно вызывать из разных потоков.
type Engine struct {
	backend   Backend
	sanitizer Sanitizer
	now       func() time.Time
	tick      time.Duration

	// op пропускает по одному действию, меняющему состояние: запуск, остановку, замер
	op sync.Mutex

	mu       sync.Mutex
	status   proto.Status
	session  Session
	baseRx   uint64
	baseTx   uint64
	stopTick chan struct{}
	subs     map[*Subscription]struct{}
}

// New создаёт службу в состоянии «отключено».
func New(backend Backend, sanitizer Sanitizer) *Engine {
	return &Engine{
		backend:   backend,
		sanitizer: sanitizer,
		now:       time.Now,
		tick:      time.Second,
		status:    proto.Status{State: proto.StateDisconnected},
		subs:      make(map[*Subscription]struct{}),
	}
}

// Subscription — подписка на изменения состояния. Хранит только последнее состояние:
// медленный получатель не задерживает службу и не копит очередь.
type Subscription struct {
	engine *Engine
	notify chan struct{}
	mu     sync.Mutex
	latest *proto.Status
}

// C сообщает, что появилось новое состояние.
func (s *Subscription) C() <-chan struct{} { return s.notify }

// Take забирает последнее состояние, если оно ещё не было забрано.
func (s *Subscription) Take() (proto.Status, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.latest == nil {
		return proto.Status{}, false
	}
	st := *s.latest
	s.latest = nil
	return st, true
}

// Close отменяет подписку.
func (s *Subscription) Close() {
	s.engine.mu.Lock()
	delete(s.engine.subs, s)
	s.engine.mu.Unlock()
}

func (s *Subscription) push(st proto.Status) {
	s.mu.Lock()
	s.latest = &st
	s.mu.Unlock()
	select {
	case s.notify <- struct{}{}:
	default:
	}
}

// Subscribe подписывает на изменения. Текущее состояние приходит сразу.
func (e *Engine) Subscribe() *Subscription {
	s := &Subscription{engine: e, notify: make(chan struct{}, 1)}
	e.mu.Lock()
	e.subs[s] = struct{}{}
	st := e.status
	e.mu.Unlock()
	s.push(st)
	return s
}

// Status возвращает текущее состояние.
func (e *Engine) Status() proto.Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.status
}

// set меняет состояние и рассылает его подписчикам. Вызывать с захваченным e.mu.
func (e *Engine) setLocked(change func(st *proto.Status)) {
	change(&e.status)
	st := e.status
	for s := range e.subs {
		s.push(st)
	}
}

// Start запускает подключение. Если оно уже работает, сначала останавливает прежнее.
func (e *Engine) Start(rawConfig, name string) error {
	config, err := e.sanitizer.Tunnel(rawConfig)
	if err != nil {
		return err
	}
	if len(name) > 256 {
		name = name[:256]
	}

	e.op.Lock()
	defer e.op.Unlock()

	e.stopSession()

	e.mu.Lock()
	e.setLocked(func(st *proto.Status) {
		*st = proto.Status{State: proto.StateConnecting, Name: &name}
	})
	e.mu.Unlock()

	session, err := e.backend.Start(config)
	if err != nil {
		text := "Не удалось подключиться: " + err.Error()
		e.mu.Lock()
		e.setLocked(func(st *proto.Status) {
			*st = proto.Status{State: proto.StateDisconnected, Error: &text}
		})
		e.mu.Unlock()
		return errors.New(text)
	}

	e.mu.Lock()
	e.session = session
	// адаптер мог остаться от прошлого запуска со старыми счётчиками
	e.baseRx, e.baseTx, _ = session.Counters()
	e.stopTick = make(chan struct{})
	stop := e.stopTick
	e.setLocked(func(st *proto.Status) {
		*st = proto.Status{State: proto.StateConnected, Since: e.now().UnixMilli(), Name: &name}
	})
	e.mu.Unlock()

	go e.ticker(session, stop)
	return nil
}

// ticker раз в секунду обновляет счётчики трафика, пока подключение работает.
func (e *Engine) ticker(session Session, stop <-chan struct{}) {
	t := time.NewTicker(e.tick)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
		}
		rx, tx, ok := session.Counters()
		e.mu.Lock()
		if e.session != session || e.status.State != proto.StateConnected {
			e.mu.Unlock()
			return
		}
		e.setLocked(func(st *proto.Status) {
			if !ok {
				return
			}
			// счётчики адаптера обнулились: считаем заново
			if rx < e.baseRx {
				e.baseRx = 0
			}
			if tx < e.baseTx {
				e.baseTx = 0
			}
			st.Rx, st.Tx = rx-e.baseRx, tx-e.baseTx
		})
		e.mu.Unlock()
	}
}

// Stop останавливает подключение. Если оно не работает, только сбрасывает прошлую ошибку.
func (e *Engine) Stop() error {
	e.op.Lock()
	defer e.op.Unlock()
	err := e.stopSession()
	e.mu.Lock()
	e.setLocked(func(st *proto.Status) {
		*st = proto.Status{State: proto.StateDisconnected}
	})
	e.mu.Unlock()
	return err
}

// stopSession останавливает ядро, если оно запущено. Вызывать с захваченным e.op.
func (e *Engine) stopSession() error {
	e.mu.Lock()
	session := e.session
	if session == nil {
		e.mu.Unlock()
		return nil
	}
	close(e.stopTick)
	e.setLocked(func(st *proto.Status) { st.State = proto.StateStopping })
	e.mu.Unlock()

	err := session.Close()

	e.mu.Lock()
	e.session = nil
	e.mu.Unlock()
	return err
}

// Ping замеряет задержку через каждый сервер. Работает только при выключенном подключении:
// второе ядро в том же процессе делило бы с первым журнал и привязку сокетов к сетевому интерфейсу.
func (e *Engine) Ping(rawConfigs []string) ([]int, error) {
	if len(rawConfigs) > proto.MaxPingConfigs {
		return nil, errors.New("Слишком много серверов в одном замере")
	}
	if !e.op.TryLock() {
		return nil, ErrBusy
	}
	defer e.op.Unlock()
	if e.Status().State != proto.StateDisconnected {
		return nil, ErrBusy
	}

	delays := make([]int, len(rawConfigs))
	var configs []string
	var index []int
	for i, raw := range rawConfigs {
		delays[i] = -1
		config, err := e.sanitizer.Probe(raw)
		if err != nil {
			continue
		}
		configs = append(configs, config)
		index = append(index, i)
	}
	if len(configs) > 0 {
		for i, delay := range e.backend.Ping(configs) {
			if i < len(index) {
				delays[index[i]] = delay
			}
		}
	}
	return delays, nil
}

// Shutdown останавливает подключение перед выходом службы.
func (e *Engine) Shutdown() {
	_ = e.Stop()
}
