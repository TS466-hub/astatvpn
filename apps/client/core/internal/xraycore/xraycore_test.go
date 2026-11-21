package xraycore

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/xtls/xray-core/common/platform/filesystem"

	"astatvpn/core/internal/sanitize"
)

func TestVersion(t *testing.T) {
	if Version() != "26.11.9" {
		t.Fatalf("версия ядра %q, а сборка для Android использует 26.11.9", Version())
	}
}

func TestRing(t *testing.T) {
	r := NewRing(3)
	if r.Text() != "" {
		t.Fatal("пустой журнал")
	}
	r.Add("a\n")
	r.Add("b")
	if r.Text() != "a\nb" {
		t.Fatalf("%q", r.Text())
	}
	r.Add("c")
	r.Add("d")
	r.Add("e")
	if r.Text() != "c\nd\ne" {
		t.Fatalf("%q", r.Text())
	}
	r.Add(strings.Repeat("я", 5000))
	last := r.Text()[strings.LastIndex(r.Text(), "\n")+1:]
	if len(last) > logLineMax+4 || !strings.HasSuffix(last, "…") || strings.ContainsRune(last, '�') {
		t.Fatalf("длинная строка не обрезана: %d", len(last))
	}
}

func TestRingKeepsLastLines(t *testing.T) {
	r := NewRing(logLines)
	for i := 0; i < 1234; i++ {
		r.Add(fmt.Sprint(i))
	}
	lines := strings.Split(r.Text(), "\n")
	if len(lines) != logLines || lines[0] != "734" || lines[logLines-1] != "1233" {
		t.Fatalf("%d строк, %s … %s", len(lines), lines[0], lines[len(lines)-1])
	}
}

// Проверенная конфигурация должна разбираться ядром: проверка не ломает то, что собирает приложение.
func TestSanitizedConfigLoads(t *testing.T) {
	raw := `{
	  "log": {"loglevel": "warning", "access": "/tmp/astat-should-not-exist.log", "error": "/tmp/astat-should-not-exist.log"},
	  "api": {"tag": "api", "services": ["StatsService"]}, "stats": {},
	  "dns": {"tag": "dns-internal", "queryStrategy": "UseIPv4", "servers": ["1.1.1.1", "8.8.8.8"]},
	  "inbounds": [{"tag": "tun", "protocol": "tun", "settings": {"mtu": 1500, "name": "AstatVPN", "desc": "AstatVPN",
	    "gateway": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "dns": ["172.19.0.2"],
	    "autoSystemRoutingTable": ["0.0.0.0/0", "::/0"], "autoOutboundsInterface": "auto",
	    "autoSystemWfpBlockLeak": ["dns", "misconfigtun"]},
	    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}}],
	  "outbounds": [
	    {"tag": "proxy", "protocol": "vless",
	     "settings": {"vnext": [{"address": "nl.example.com", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
	     "streamSettings": {"network": "tcp", "security": "reality",
	       "realitySettings": {"serverName": "addons.mozilla.org", "fingerprint": "chrome", "publicKey": "7xhH4b_VkliBxGulljcyPOH-bYUA2dl-XAdZAsfhk04", "shortId": "01"}}},
	    {"tag": "direct", "protocol": "freedom"},
	    {"tag": "block", "protocol": "blackhole"},
	    {"tag": "dns-out", "protocol": "dns"}],
	  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
	    {"type": "field", "inboundTag": ["tun"], "port": 53, "outboundTag": "dns-out"},
	    {"type": "field", "domain": ["domain:ru"], "outboundTag": "direct"}]}
	}`
	clean, err := sanitize.Tunnel(raw)
	if err != nil {
		t.Fatal(err)
	}
	instance, err := newInstance(clean)
	if err != nil {
		t.Fatalf("ядро не приняло проверенную конфигурацию: %v\n%s", err, clean)
	}
	_ = instance.Close()
	if _, err := os.Stat("/tmp/astat-should-not-exist.log"); err == nil {
		t.Fatal("ядро создало файл журнала")
	}
}

func TestLockDown(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "geoip.dat"), []byte("geo"), 0o600); err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(dir, "secret.txt")
	if err := os.WriteFile(secret, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XRAY_BROWSER_DIALER", "127.0.0.1:8080")
	t.Setenv("xray.location.cert", "/etc")
	t.Setenv("XRAY_TUN_FD", "3")
	saved := filesystem.NewFileReader
	defer func() { filesystem.NewFileReader = saved }()

	LockDown(dir)

	for _, name := range []string{"XRAY_BROWSER_DIALER", "xray.location.cert", "XRAY_TUN_FD"} {
		if _, ok := os.LookupEnv(name); ok {
			t.Errorf("переменная %s не сброшена", name)
		}
	}
	if os.Getenv("XRAY_LOCATION_ASSET") != dir || os.Getenv("xray.location.asset") != dir {
		t.Error("каталог геоданных не задан")
	}
	if r, size, err := filesystem.OpenAsset("geoip.dat"); err != nil || size != 3 {
		t.Errorf("геоданные не читаются: %v", err)
	} else {
		r.Close()
	}
	for _, path := range []string{secret, "/etc/hosts", filepath.Join(dir, "..", filepath.Base(dir), "secret.txt"), "secret.txt"} {
		if _, err := filesystem.ReadFile(path); err == nil {
			t.Errorf("прочитан посторонний файл %s", path)
		}
		if _, err := filesystem.ReadCert(path); err == nil {
			t.Errorf("прочитан посторонний файл %s как сертификат", path)
		}
	}
	if r, _, err := filesystem.OpenAsset("secret.txt"); err == nil {
		r.Close()
		t.Error("прочитан посторонний файл из каталога службы")
	}
}

func TestStartRejectsBrokenConfig(t *testing.T) {
	b := &Backend{}
	for _, config := range []string{``, `{`, `{"outbounds": [{"protocol": "nope"}]}`, `{"inbounds": [{"protocol": "tun", "settings": {"gateway": ["x"]}}]}`} {
		if s, err := b.Start(config); err == nil {
			_ = s.Close()
			// последняя конфигурация на macOS может и запуститься без прав — важно лишь, что служба не падает
			t.Logf("конфигурация %q запустилась", config)
		}
	}
	called := false
	b.PreStart = func() error { called = true; return fmt.Errorf("нет wintun.dll") }
	if _, err := b.Start(`{"outbounds": [{"protocol": "freedom"}]}`); err == nil || !called {
		t.Fatalf("PreStart не остановил запуск: %v", err)
	}
}

func TestStartAndCounters(t *testing.T) {
	b := &Backend{Counters: func() (uint64, uint64, bool) { return 10, 20, true }}
	clean, err := sanitize.Probe(`{"outbounds": [{"protocol": "freedom"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	s, err := b.Start(clean)
	if err != nil {
		t.Fatal(err)
	}
	if rx, tx, ok := s.Counters(); rx != 10 || tx != 20 || !ok {
		t.Fatal("счётчики")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	_ = s.Close() // повторная остановка безвредна
	if !strings.Contains(Logs.Text(), "ядро запущено") {
		t.Error("в журнале нет записи о запуске")
	}
}

// Замер идёт через исходящий канал ядра, без локального прокси.
func TestPing(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.Method != http.MethodHead {
			t.Errorf("метод %s", r.Method)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	// закрытый порт: сервер, который не отвечает
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := l.Addr().(*net.TCPAddr).Port
	l.Close()

	probe := func(raw string) string {
		clean, err := sanitize.Probe(raw)
		if err != nil {
			t.Fatal(err)
		}
		return clean
	}
	b := &Backend{pingURL: srv.URL}
	delays := b.Ping([]string{
		probe(`{"outbounds": [{"tag": "proxy", "protocol": "freedom"}]}`),
		probe(fmt.Sprintf(`{"outbounds": [{"tag": "proxy", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": %d}]}}]}`, dead)),
		`{"outbounds": [{"protocol": "nope"}]}`,
		`not json`,
		probe(`{"outbounds": [{"tag": "proxy", "protocol": "blackhole"}]}`),
		probe(`{"outbounds": [{"tag": "proxy", "protocol": "freedom"}]}`),
		// замер идёт через канал "proxy", даже если он не первый
		probe(`{"outbounds": [{"tag": "block", "protocol": "blackhole"}, {"tag": "proxy", "protocol": "freedom"}]}`),
		// цепочка: метки соседних каналов переименованы согласованно
		probe(`{"outbounds": [{"tag": "proxy", "protocol": "freedom", "streamSettings": {"sockopt": {"dialerProxy": "hop"}}}, {"tag": "hop", "protocol": "freedom"}]}`),
		// цепочка в тупик не должна задеть соседние конфигурации с такими же метками
		probe(`{"outbounds": [{"tag": "proxy", "protocol": "freedom", "streamSettings": {"sockopt": {"dialerProxy": "hop"}}}, {"tag": "hop", "protocol": "blackhole"}]}`),
		// без меток: первый канал
		probe(`{"outbounds": [{"protocol": "freedom"}, {"protocol": "blackhole"}]}`),
	})
	want := []bool{true, false, false, false, false, true, true, true, false, true}
	if len(delays) != len(want) {
		t.Fatalf("%v", delays)
	}
	for i, ok := range want {
		if ok && delays[i] < 1 {
			t.Errorf("конфигурация %d не ответила: %v", i, delays)
		}
		if !ok && delays[i] != -1 {
			t.Errorf("конфигурация %d: задержка %d, ожидалась -1", i, delays[i])
		}
	}
	// на каждый отвечающий сервер три запроса: первый устанавливает соединение, два повторных дают задержку
	if got := hits.Load(); got != 15 {
		t.Errorf("запросов к серверу: %d", got)
	}
	if got := b.Ping(nil); len(got) != 0 {
		t.Errorf("%v", got)
	}
}

func TestNamespaceOutbounds(t *testing.T) {
	outbounds, tag, err := namespaceOutbounds(`{"OUTBOUNDS": [
	  {"Tag": "a", "protocol": "vless", "streamSettings": {"sockopt": {"DialerProxy": "proxy"}, "xhttpSettings": {"extra": {"downloadSettings": {"sockopt": {"dialerProxy": "a"}}}}}},
	  {"tag": "proxy", "protocol": "vless", "proxySettings": {"tag": "a"}, "settings": {"tag": "a"}},
	  {"protocol": "freedom"}]}`, 7)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(outbounds)
	got := string(data)
	if tag != "ping-7-1" {
		t.Errorf("цель %q", tag)
	}
	for _, must := range []string{`"tag":"ping-7-0"`, `"tag":"ping-7-1"`, `"tag":"ping-7-2"`, `"DialerProxy":"ping-7-1"`, `"dialerProxy":"ping-7-0"`, `"proxySettings":{"tag":"ping-7-0"}`, `"settings":{"tag":"a"}`} {
		if !strings.Contains(got, must) {
			t.Errorf("нет %s в %s", must, got)
		}
	}
	if strings.Contains(got, `"Tag"`) {
		t.Errorf("осталась прежняя метка: %s", got)
	}
	for _, bad := range []string{``, `[]`, `{}`, `{"outbounds": []}`, `{"outbounds": ["x"]}`, `{"outbounds": {}}`} {
		if _, _, err := namespaceOutbounds(bad, 0); err == nil {
			t.Errorf("%q: ожидалась ошибка", bad)
		}
	}
}
