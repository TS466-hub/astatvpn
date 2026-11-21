package ipc

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"astatvpn/core/internal/engine"
	"astatvpn/core/internal/proto"
	"astatvpn/core/internal/sanitize"
)

type session struct {
	closed bool
	calls  atomic.Uint64
}

func (s *session) Close() error { s.closed = true; return nil }

// первый вызов задаёт точку отсчёта, дальше счётчики растут
func (s *session) Counters() (uint64, uint64, bool) {
	n := s.calls.Add(1)
	return 5000 + n*1500, 700 + n*300, true
}

type backend struct {
	mu      sync.Mutex
	configs []string
	fail    error
	panicky bool
}

func (b *backend) Start(config string) (engine.Session, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.panicky {
		panic("сбой")
	}
	if b.fail != nil {
		return nil, b.fail
	}
	b.configs = append(b.configs, config)
	return &session{}, nil
}

func (b *backend) Ping(configs []string) []int {
	out := make([]int, len(configs))
	for i := range out {
		out[i] = 42
	}
	return out
}

type realSanitizer struct{}

func (realSanitizer) Tunnel(raw string) (string, error) { return sanitize.Tunnel(raw) }
func (realSanitizer) Probe(raw string) (string, error)  { return sanitize.Probe(raw) }

const tunConfig = `{"inbounds":[{"protocol":"tun","settings":{"gateway":["172.19.0.1/30"]}}],"outbounds":[{"protocol":"freedom"}]}`

type testClient struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
}

func setup(t *testing.T) (*Server, *backend, *testClient) {
	t.Helper()
	b := &backend{}
	s := &Server{
		Core:          engine.New(b, realSanitizer{}),
		CoreVersion:   "26.11.9",
		HelperVersion: "0.1.0",
		Logs:          func() string { return "строка журнала" },
	}
	return s, b, connect(t, s)
}

func connect(t *testing.T, s *Server) *testClient {
	t.Helper()
	server, client := net.Pipe()
	go s.Handle(server)
	t.Cleanup(func() { client.Close() })
	return &testClient{t: t, conn: client, r: bufio.NewReaderSize(client, 1<<20)}
}

// read возвращает следующую строку: событие или ответ
func (c *testClient) read() map[string]any {
	c.t.Helper()
	_ = c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := c.r.ReadString('\n')
	if err != nil {
		c.t.Fatalf("чтение: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		c.t.Fatalf("не JSON: %q", line)
	}
	return m
}

// call отправляет запрос и ждёт ответ на него, пропуская события
func (c *testClient) call(line string) map[string]any {
	c.t.Helper()
	c.write(line + "\n")
	return c.response()
}

func (c *testClient) write(data string) {
	c.t.Helper()
	// net.Pipe не буферизует: пишем отдельно, чтобы не мешать чтению событий
	go func() { _, _ = c.conn.Write([]byte(data)) }()
}

func (c *testClient) response() map[string]any {
	c.t.Helper()
	for {
		m := c.read()
		if _, isEvent := m["event"]; !isEvent {
			return m
		}
	}
}

func (c *testClient) event(want func(data map[string]any) bool) map[string]any {
	c.t.Helper()
	for i := 0; i < 50; i++ {
		m := c.read()
		if m["event"] == "status" {
			data := m["data"].(map[string]any)
			if want(data) {
				return data
			}
		}
	}
	c.t.Fatal("нужное событие не пришло")
	return nil
}

func quote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func TestStatusOnConnect(t *testing.T) {
	_, _, c := setup(t)
	m := c.read()
	data := m["data"].(map[string]any)
	if m["event"] != "status" || data["state"] != "disconnected" || data["error"] != nil || data["name"] != nil ||
		data["since"] != float64(0) || data["rx"] != float64(0) || data["tx"] != float64(0) || len(data) != 6 {
		t.Fatalf("%v", m)
	}
}

func TestMethods(t *testing.T) {
	_, b, c := setup(t)

	r := c.call(`{"id":1,"method":"version"}`)
	if r["id"] != float64(1) || r["ok"] != true || r["result"].(map[string]any)["core"] != "26.11.9" || r["result"].(map[string]any)["helper"] != "0.1.0" {
		t.Fatalf("%v", r)
	}
	r = c.call(`{"id":2,"method":"logs","params":{}}`)
	if r["ok"] != true || r["result"].(map[string]any)["text"] != "строка журнала" {
		t.Fatalf("%v", r)
	}
	r = c.call(`{"id":3,"method":"status"}`)
	if r["ok"] != true || r["result"].(map[string]any)["state"] != "disconnected" {
		t.Fatalf("%v", r)
	}
	r = c.call(`{"id":4,"method":"ping","params":{"configs":[` + quote(`{"outbounds":[{"protocol":"freedom"}]}`) + `,"мусор"]}}`)
	delays := r["result"].(map[string]any)["delays"].([]any)
	if r["ok"] != true || len(delays) != 2 || delays[0] != float64(42) || delays[1] != float64(-1) {
		t.Fatalf("%v", r)
	}
	r = c.call(`{"id":5,"method":"ping","params":{"configs":[]}}`)
	if r["ok"] != true || len(r["result"].(map[string]any)["delays"].([]any)) != 0 {
		t.Fatalf("%v", r)
	}

	r = c.call(`{"id":6,"method":"start","params":{"config":` + quote(tunConfig) + `,"name":"🇳🇱 Netherlands"}}`)
	res := r["result"].(map[string]any)
	if r["ok"] != true || res["state"] != "connected" || res["name"] != "🇳🇱 Netherlands" || res["since"].(float64) <= 0 {
		t.Fatalf("%v", r)
	}
	if len(b.configs) != 1 || !strings.Contains(b.configs[0], `"name":"`+sanitize.TunName+`"`) || !strings.Contains(b.configs[0], `"access":"none"`) {
		t.Fatalf("ядро получило непроверенную конфигурацию: %v", b.configs)
	}
	// раз в секунду приходят счётчики
	data := c.event(func(d map[string]any) bool { return d["state"] == "connected" && d["rx"] != float64(0) })
	if data["rx"].(float64) < 1500 || data["tx"].(float64) < 300 || data["name"] != "🇳🇱 Netherlands" {
		t.Fatalf("%v", data)
	}

	r = c.call(`{"id":7,"method":"ping","params":{"configs":["{}"]}}`)
	if r["ok"] != false || !strings.Contains(r["error"].(string), "выключенном VPN") {
		t.Fatalf("%v", r)
	}
	r = c.call(`{"id":8,"method":"stop"}`)
	if r["ok"] != true || r["result"].(map[string]any)["state"] != "disconnected" {
		t.Fatalf("%v", r)
	}
}

func TestEventsDuringStart(t *testing.T) {
	_, _, c := setup(t)
	c.write(`{"id":1,"method":"start","params":{"config":` + quote(tunConfig) + `,"name":"NL"}}` + "\n")
	var states []string
	for {
		m := c.read()
		if m["event"] == "status" {
			states = append(states, m["data"].(map[string]any)["state"].(string))
			continue
		}
		break
	}
	joined := strings.Join(states, ",")
	// состояния сжимаются до последнего, но disconnected приходит первым
	if !strings.HasPrefix(joined, "disconnected") {
		t.Fatalf("события: %s", joined)
	}
	c.event(func(d map[string]any) bool { return d["state"] == "connected" })
}

func TestMaliciousStart(t *testing.T) {
	_, b, c := setup(t)
	bad := []string{
		`{"inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":1080}],"outbounds":[{"protocol":"freedom"}]}`,
		`{"inbounds":[{"protocol":"tun"},{"protocol":"http","port":8080}],"outbounds":[{"protocol":"freedom"}]}`,
		`{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"vless","streamSettings":{"tlsSettings":{"certificates":[{"certificateFile":"C:\\Windows\\win.ini","keyFile":"C:\\x"}]}}}]}`,
		`{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"vless","streamSettings":{"tlsSettings":{"masterKeyLog":"C:\\Windows\\System32\\evil.dll"}}}]}`,
		`not json`,
		``,
	}
	for i, config := range bad {
		r := c.call(fmt.Sprintf(`{"id":%d,"method":"start","params":{"config":%s,"name":"x"}}`, i+1, quote(config)))
		if r["ok"] != false || !strings.HasPrefix(r["error"].(string), "Конфигурация отклонена") || r["id"] != float64(i+1) {
			t.Errorf("конфигурация %d: %v", i, r)
		}
	}
	if len(b.configs) != 0 {
		t.Fatalf("ядро запускалось: %v", b.configs)
	}
	r := c.call(`{"id":9,"method":"status"}`)
	if r["result"].(map[string]any)["state"] != "disconnected" {
		t.Fatalf("%v", r)
	}
}

func TestMalformedRequests(t *testing.T) {
	_, _, c := setup(t)
	for _, line := range []string{
		`мусор`, `{`, `[]`, `null`, `1`, `"start"`, `{"id":"x","method":"status"}`, `{"id":1}`, `{"id":1,"method":""}`,
		`{"id":1,"method":"exec","params":{"cmd":"calc.exe"}}`, `{"id":1,"method":"start"}`, `{"id":1,"method":"start","params":null}`,
		`{"id":1,"method":"start","params":[]}`, `{"id":1,"method":"start","params":{"config":5}}`, `{"id":1,"method":"start","params":{"name":"x"}}`,
		`{"id":1,"method":"ping","params":{"configs":"x"}}`, `{"id":1,"method":"ping","params":{"configs":[1,2]}}`, `{"id":1,"method":"ping","params":"x"}`,
		`{"id":1e400,"method":"status"}`, `{"id":1,"method":"status","params":` + strings.Repeat("[", 20000) + strings.Repeat("]", 20000) + `}`,
		"\x00\x01\x02", `{"id":1,"method":"start","params":{"config":"\ud800","name":"\u0000"}}`,
	} {
		r := c.call(line)
		if r["ok"] != false || r["error"] == "" {
			if strings.Contains(line, `"method":"status"`) && r["ok"] == true {
				continue // лишние params у status не мешают
			}
			t.Errorf("%.60q -> %v", line, r)
		}
	}
	// после всего этого служба отвечает как обычно
	r := c.call(`{"id":77,"method":"status"}`)
	if r["ok"] != true || r["id"] != float64(77) {
		t.Fatalf("%v", r)
	}
}

func TestPanicInHandlerDoesNotKillService(t *testing.T) {
	s, b, c := setup(t)
	var logged string
	s.Logf = func(m string) { logged = m }
	b.panicky = true
	r := c.call(`{"id":1,"method":"start","params":{"config":` + quote(tunConfig) + `,"name":"x"}}`)
	if r["ok"] != false || r["error"] != "Внутренняя ошибка службы" || logged == "" {
		t.Fatalf("%v, журнал %q", r, logged)
	}
	if r := c.call(`{"id":2,"method":"version"}`); r["ok"] != true {
		t.Fatalf("%v", r)
	}
}

func TestStartFailureIsReported(t *testing.T) {
	_, b, c := setup(t)
	b.fail = errors.New("unable to create adapter")
	r := c.call(`{"id":1,"method":"start","params":{"config":` + quote(tunConfig) + `,"name":"x"}}`)
	if r["ok"] != false || !strings.Contains(r["error"].(string), "Не удалось подключиться: unable to create adapter") {
		t.Fatalf("%v", r)
	}
	r = c.call(`{"id":2,"method":"status"}`)
	res := r["result"].(map[string]any)
	if res["state"] != "disconnected" || !strings.Contains(res["error"].(string), "unable to create adapter") {
		t.Fatalf("%v", r)
	}
}

func TestOversizedRequestClosesConnection(t *testing.T) {
	s, _, c := setup(t)
	c.read() // начальное событие
	go func() {
		chunk := []byte(strings.Repeat("a", 1<<20))
		for i := 0; i < 6; i++ {
			if _, err := c.conn.Write(chunk); err != nil {
				return
			}
		}
	}()
	r := c.response()
	if r["ok"] != false || r["error"] != "Запрос слишком большой" {
		t.Fatalf("%v", r)
	}
	_ = c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.r.ReadString('\n'); err == nil {
		t.Fatal("подключение должно быть закрыто")
	}
	// другие подключения работают
	c2 := connect(t, s)
	if r := c2.call(`{"id":1,"method":"status"}`); r["ok"] != true {
		t.Fatalf("%v", r)
	}
}

func TestLargeRequestWithinLimit(t *testing.T) {
	_, _, c := setup(t)
	pad := strings.Repeat("a", 3<<20)
	config := `{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"freedom","tag":"` + pad + `"}]}`
	r := c.call(`{"id":1,"method":"start","params":{"config":` + quote(config) + `,"name":"x"}}`)
	if r["ok"] != true {
		t.Fatalf("%.200v", r)
	}
}

func TestVpnSurvivesDisconnect(t *testing.T) {
	s, _, c := setup(t)
	r := c.call(`{"id":1,"method":"start","params":{"config":` + quote(tunConfig) + `,"name":"NL"}}`)
	if r["ok"] != true {
		t.Fatalf("%v", r)
	}
	c.conn.Close()
	time.Sleep(50 * time.Millisecond)
	// приложение закрыли, подключение продолжает работать
	if st := s.Core.Status(); st.State != proto.StateConnected {
		t.Fatalf("%+v", st)
	}
	c2 := connect(t, s)
	data := c2.event(func(d map[string]any) bool { return true })
	if data["state"] != "connected" || data["name"] != "NL" {
		t.Fatalf("%v", data)
	}
	if r := c2.call(`{"id":1,"method":"stop"}`); r["ok"] != true {
		t.Fatalf("%v", r)
	}
}

func TestUnfinishedRequestIsNotExecuted(t *testing.T) {
	s, b, c := setup(t)
	c.read()
	_, _ = c.conn.Write([]byte(`{"id":1,"method":"start","params":{"config":` + quote(tunConfig) + `,"name":"NL"}}`))
	c.conn.Close()
	time.Sleep(50 * time.Millisecond)
	if len(b.configs) != 0 || s.Core.Status().State != proto.StateDisconnected {
		t.Fatal("выполнен запрос без конца строки")
	}
}

func TestClientLimit(t *testing.T) {
	s, _, _ := setup(t) // одно подключение уже есть
	var clients []*testClient
	for i := 0; i < MaxClients-1; i++ {
		c := connect(t, s)
		c.read()
		clients = append(clients, c)
	}
	extra := connect(t, s)
	m := extra.read()
	if m["ok"] != false || !strings.Contains(m["error"].(string), "Слишком много") {
		t.Fatalf("%v", m)
	}
	// место освобождается после отключения
	clients[0].conn.Close()
	time.Sleep(50 * time.Millisecond)
	again := connect(t, s)
	if r := again.call(`{"id":1,"method":"status"}`); r["ok"] != true {
		t.Fatalf("%v", r)
	}
}

func TestStuckClientDoesNotBlockOthers(t *testing.T) {
	s, _, stuck := setup(t)
	_ = stuck // подключился и ничего не читает
	c := connect(t, s)
	for i := 0; i < 5; i++ {
		if r := c.call(`{"id":1,"method":"start","params":{"config":` + quote(tunConfig) + `,"name":"x"}}`); r["ok"] != true {
			t.Fatalf("%v", r)
		}
		if r := c.call(`{"id":2,"method":"stop"}`); r["ok"] != true {
			t.Fatalf("%v", r)
		}
	}
}

func TestServe(t *testing.T) {
	s, _, _ := setup(t)
	// сокет в файле только в тесте: в службе слушается именованный канал
	l, err := net.Listen("unix", filepath.Join(t.TempDir(), "s"))
	if err != nil {
		t.Skip(err)
	}
	done := make(chan error, 1)
	go func() { done <- s.Serve(l) }()
	conn, err := net.Dial("unix", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c := &testClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	if r := c.call(`{"id":1,"method":"version"}`); r["ok"] != true {
		t.Fatalf("%v", r)
	}
	conn.Close()
	l.Close()
	if err := <-done; err != nil {
		t.Fatalf("Serve: %v", err)
	}
	s.Wait()
}
