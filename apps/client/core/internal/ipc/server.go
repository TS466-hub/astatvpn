// Package ipc обслуживает подключения приложения к службе. Транспорт (именованный канал Windows) передаётся снаружи.
//
// Тот, кто подключился, считается посторонней программой без прав: любая строка может быть мусором,
// слишком длинной или оборваться, и ничто из этого не должно ронять службу или задерживать других.
package ipc

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"astatvpn/core/internal/engine"
	"astatvpn/core/internal/proto"
	"astatvpn/core/internal/sanitize"
)

const (
	// MaxClients — сколько подключений обслуживается одновременно.
	MaxClients = 16

	writeTimeout = 10 * time.Second
)

// Core — то, чем управляет приложение.
type Core interface {
	Status() proto.Status
	Start(config, name string) error
	Stop() error
	Ping(configs []string) ([]int, error)
	Subscribe() *engine.Subscription
}

// Server разбирает запросы и рассылает события.
type Server struct {
	Core          Core
	CoreVersion   string
	HelperVersion string
	Logs          func() string

	// Logf получает сообщения о сбоях самой службы; может быть nil.
	Logf func(string)

	once    sync.Once
	clients chan struct{}
	wg      sync.WaitGroup
}

func (s *Server) init() {
	s.once.Do(func() { s.clients = make(chan struct{}, MaxClients) })
}

// Serve принимает подключения, пока слушатель не закрыт.
func (s *Server) Serve(l net.Listener) error {
	s.init()
	for {
		conn, err := l.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.Handle(conn)
		}()
	}
}

// Wait ждёт, пока завершатся обработчики подключений.
func (s *Server) Wait() { s.wg.Wait() }

type client struct {
	conn net.Conn
	mu   sync.Mutex
}

func (c *client) send(v any) error {
	data, err := proto.Encode(v)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	// получатель, который перестал читать, не должен держать службу
	_ = c.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
	_, err = c.conn.Write(data)
	return err
}

// Handle обслуживает одно подключение до его закрытия. Запросы выполняются по одному.
func (s *Server) Handle(conn net.Conn) {
	s.init()
	defer conn.Close()
	c := &client{conn: conn}

	select {
	case s.clients <- struct{}{}:
		defer func() { <-s.clients }()
	default:
		_ = c.send(proto.Response{Error: "Слишком много подключений к службе"})
		return
	}

	done := make(chan struct{})
	defer close(done)
	sub := s.Core.Subscribe()
	defer sub.Close()
	go func() {
		for {
			select {
			case <-done:
				return
			case <-sub.C():
				st, ok := sub.Take()
				if !ok {
					continue
				}
				if c.send(proto.Event{Event: "status", Data: st}) != nil {
					// закрытие разбудит чтение, и подключение завершится
					conn.Close()
					return
				}
			}
		}
	}()

	reader := proto.NewLineReader(conn, proto.MaxRequestSize)
	for {
		line, err := reader.Next()
		if errors.Is(err, proto.ErrTooLarge) {
			// граница запроса потеряна: отвечаем и закрываем
			_ = c.send(proto.Response{Error: "Запрос слишком большой"})
			return
		}
		if err != nil {
			return
		}
		if c.send(s.respond(line)) != nil {
			return
		}
	}
}

func (s *Server) respond(line []byte) (resp proto.Response) {
	req, err := proto.ParseRequest(line)
	resp.ID = req.ID
	if err != nil {
		resp.Error = "Некорректный запрос"
		return resp
	}
	defer func() {
		if r := recover(); r != nil {
			if s.Logf != nil {
				s.Logf(fmt.Sprintf("сбой при выполнении %s: %v", req.Method, r))
			}
			resp = proto.Response{ID: req.ID, Error: "Внутренняя ошибка службы"}
		}
	}()
	result, err := s.dispatch(req)
	if err != nil {
		resp.Error = err.Error()
		return resp
	}
	resp.OK = true
	resp.Result = result
	return resp
}

var errParams = errors.New("Некорректные параметры запроса")

func (s *Server) dispatch(req proto.Request) (any, error) {
	switch req.Method {
	case "status":
		return s.Core.Status(), nil

	case "start":
		var p struct {
			Config *string `json:"config"`
			Name   string  `json:"name"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil || p.Config == nil {
			return nil, errParams
		}
		if err := s.Core.Start(*p.Config, p.Name); err != nil {
			return nil, err
		}
		return s.Core.Status(), nil

	case "stop":
		if err := s.Core.Stop(); err != nil {
			return nil, errors.New("Подключение остановлено с ошибкой: " + err.Error())
		}
		return s.Core.Status(), nil

	case "ping":
		var p proto.PingParams
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return nil, errParams
		}
		for _, config := range p.Configs {
			if len(config) > sanitize.MaxSize {
				return nil, errParams
			}
		}
		delays, err := s.Core.Ping(p.Configs)
		if err != nil {
			return nil, err
		}
		if delays == nil {
			delays = []int{}
		}
		return proto.PingResult{Delays: delays}, nil

	case "version":
		return proto.VersionResult{Core: s.CoreVersion, Helper: s.HelperVersion}, nil

	case "logs":
		text := ""
		if s.Logs != nil {
			text = s.Logs()
		}
		return proto.LogsResult{Text: text}, nil
	}
	return nil, errors.New("Неизвестный метод")
}
