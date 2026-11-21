package sanitize

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// то, что собирает lib/core/xray_config.dart для Windows
const good = `{
  "log": {"loglevel": "warning"},
  "dns": {"tag": "dns-internal", "queryStrategy": "UseIPv4", "servers": [
    {"address": "77.88.8.8", "domains": ["domain:ru", "geosite:category-ru"], "skipFallback": true}, "1.1.1.1", "8.8.8.8"]},
  "inbounds": [{
    "tag": "tun", "protocol": "tun",
    "settings": {"mtu": 1500, "name": "AstatVPN", "desc": "AstatVPN",
      "gateway": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "dns": ["172.19.0.2"],
      "autoSystemRoutingTable": ["0.0.0.0/0", "::/0"], "autoOutboundsInterface": "auto",
      "autoSystemWfpBlockLeak": ["dns", "misconfigtun"]},
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}}],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless",
     "settings": {"vnext": [{"address": "nl.example.com", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
     "streamSettings": {"network": "tcp", "security": "reality",
       "realitySettings": {"serverName": "addons.mozilla.org", "fingerprint": "chrome", "publicKey": "abc", "shortId": "01"},
       "sockopt": {"domainStrategy": "UseIP"}}},
    {"tag": "ws", "protocol": "vless", "settings": {}, "streamSettings": {"network": "ws", "wsSettings": {"path": "/ws?ed=2048", "headers": {"Host": "example.com"}}}},
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"},
    {"tag": "dns-out", "protocol": "dns"}],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
    {"type": "field", "inboundTag": ["tun"], "port": 53, "outboundTag": "dns-out"},
    {"type": "field", "ip": ["geoip:private", "ext:geoip.dat:ru", "!geoip:cn"], "outboundTag": "direct"},
    {"type": "field", "domain": ["domain:ru", "ext:geosite.dat:category-ru"], "outboundTag": "direct"}]}
}`

func mustTunnel(t *testing.T, raw string) map[string]any {
	t.Helper()
	out, err := Tunnel(raw)
	if err != nil {
		t.Fatalf("неожиданный отказ: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("на выходе не JSON: %v", err)
	}
	return m
}

func wantReject(t *testing.T, name, raw string) {
	t.Helper()
	out, err := Tunnel(raw)
	var e *Error
	if !errors.As(err, &e) {
		t.Errorf("%s: ожидался отказ, получено: %s", name, out)
		return
	}
	if !strings.HasPrefix(e.Error(), "Конфигурация отклонена: ") {
		t.Errorf("%s: текст отказа: %q", name, e.Error())
	}
}

// with подменяет кусок исправной конфигурации
func with(t *testing.T, old, new string) string {
	t.Helper()
	if !strings.Contains(good, old) {
		t.Fatalf("в образце нет %q", old)
	}
	return strings.Replace(good, old, new, 1)
}

func TestGoodConfigPasses(t *testing.T) {
	m := mustTunnel(t, good)
	if len(m) != 5 {
		t.Errorf("лишние разделы: %v", keys(m))
	}
	log := m["log"].(map[string]any)
	if log["loglevel"] != "warning" || log["access"] != "none" || len(log) != 2 {
		t.Errorf("log: %v", log)
	}
	in := m["inbounds"].([]any)
	if len(in) != 1 {
		t.Fatalf("inbounds: %v", in)
	}
	tun := in[0].(map[string]any)
	s := tun["settings"].(map[string]any)
	if tun["protocol"] != "tun" || s["name"] != TunName || s["autoOutboundsInterface"] != "auto" {
		t.Errorf("tun: %v", tun)
	}
	if got := s["autoSystemWfpBlockLeak"].([]any); len(got) != 2 || got[0] != "dns" {
		t.Errorf("wfp: %v", got)
	}
	if got := s["gateway"].([]any); len(got) != 2 {
		t.Errorf("gateway: %v", got)
	}
	if len(m["outbounds"].([]any)) != 5 {
		t.Errorf("outbounds: %v", m["outbounds"])
	}
	// содержимое исходящих не должно меняться
	out, _ := Tunnel(good)
	for _, must := range []string{`"id":"11111111-2222-3333-4444-555555555555"`, `"port":443`, `"path":"/ws?ed=2048"`, `"publicKey":"abc"`, `"ext:geosite.dat:category-ru"`, `"port":53`} {
		if !strings.Contains(out, must) {
			t.Errorf("потеряно %s", must)
		}
	}
}

func keys(m map[string]any) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

func TestLogIsForced(t *testing.T) {
	for _, tc := range []struct{ log, level string }{
		{`{"loglevel": "debug", "access": "C:\\Windows\\System32\\drivers\\etc\\hosts", "error": "C:\\x.log"}`, "warning"},
		{`{"logLevel": "INFO", "error": "\\\\evil\\share\\x"}`, "info"},
		{`{"LOGLEVEL": "none"}`, "none"},
		{`{"loglevel": 5, "dnsLog": true, "maskAddress": "full"}`, "warning"},
		{`"C:\\x.log"`, "warning"},
		{`null`, "warning"},
	} {
		m := mustTunnel(t, with(t, `{"loglevel": "warning"}`, tc.log))
		log := m["log"].(map[string]any)
		if len(log) != 2 || log["loglevel"] != tc.level || log["access"] != "none" {
			t.Errorf("%s -> %v", tc.log, log)
		}
	}
}

func TestDropsDangerousSections(t *testing.T) {
	raw := with(t, `"log": {"loglevel": "warning"},`, `"log": {"loglevel": "warning"},
	  "api": {"tag": "api", "listen": "127.0.0.1:10085", "services": ["HandlerService", "StatsService"]},
	  "stats": {}, "metrics": {"listen": "127.0.0.1:11111"},
	  "reverse": {"bridges": [{"tag": "b", "domain": "x.example"}]},
	  "env": {"XRAY_LOCATION_ASSET": "C:\\evil", "xray.browser.dialer": "127.0.0.1:8080"},
	  "geodata": {"cron": "* * * * *", "assets": [{"url": "http://evil/x", "file": "geoip.dat"}]},
	  "transport": {}, "version": {"min": "1.0.0"}, "remarks": "x", "unknownThing": {"a": 1},`)
	m := mustTunnel(t, raw)
	for _, k := range []string{"api", "stats", "metrics", "reverse", "env", "geodata", "transport", "version", "remarks", "unknownThing"} {
		if _, ok := m[k]; ok {
			t.Errorf("раздел %s остался", k)
		}
	}
	if len(m) != 5 {
		t.Errorf("разделы: %v", keys(m))
	}
	// написание в другом регистре не помогает
	for _, k := range []string{"API", "Api", "Stats", "METRICS", "Env", "GeoData", "geo_data", "re-verse"} {
		m := mustTunnel(t, with(t, `"log": {"loglevel": "warning"},`, `"`+k+`": {"listen": "127.0.0.1:1"},`))
		if len(m) != 5 {
			t.Errorf("%s: разделы: %v", k, keys(m))
		}
	}
}

func TestInbounds(t *testing.T) {
	socks := `{"tag": "socks", "protocol": "socks", "listen": "127.0.0.1", "port": 10808, "settings": {"udp": true}}`
	tun := `{"tag": "tun", "protocol": "tun", "settings": {"mtu": 1500}}`
	bad := map[string]string{
		"нет входов":        `[]`,
		"входы не список":   `{"protocol": "tun"}`,
		"входы null":        `null`,
		"socks":             `[` + socks + `]`,
		"tun и socks":       `[` + tun + `, ` + socks + `]`,
		"socks и tun":       `[` + socks + `, ` + tun + `]`,
		"два tun":           `[` + tun + `, ` + tun + `]`,
		"dokodemo":          `[{"protocol": "dokodemo-door", "port": 53, "settings": {"address": "1.1.1.1"}}]`,
		"http":              `[{"protocol": "http", "listen": "0.0.0.0", "port": 8080}]`,
		"без протокола":     `[{"tag": "tun", "settings": {}}]`,
		"протокол числом":   `[{"protocol": 1}]`,
		"вход строкой":      `["tun"]`,
		"два протокола":     `[{"protocol": "tun", "Protocol": "socks", "port": 1080}]`,
		"настройки строкой": `[{"protocol": "tun", "settings": "x"}]`,
		"плохой шлюз":       `[{"protocol": "tun", "settings": {"gateway": ["not-a-prefix"]}}]`,
		"шлюз без маски":    `[{"protocol": "tun", "settings": {"gateway": ["172.19.0.1"]}}]`,
		"шлюз не список":    `[{"protocol": "tun", "settings": {"gateway": "172.19.0.1/30"}}]`,
		"плохой dns":        `[{"protocol": "tun", "settings": {"dns": ["dns.google"]}}]`,
		"плохой маршрут":    `[{"protocol": "tun", "settings": {"autoSystemRoutingTable": ["0.0.0.0/99"]}}]`,
		"маршрут числом":    `[{"protocol": "tun", "settings": {"autoSystemRoutingTable": [0]}}]`,
		"mtu строкой":       `[{"protocol": "tun", "settings": {"mtu": "1500"}}]`,
		"mtu огромный":      `[{"protocol": "tun", "settings": {"mtu": 99999999999999999999}}]`,
		"mtu дробный":       `[{"protocol": "tun", "settings": {"mtu": 1500.5}}]`,
		"интерфейс числом":  `[{"protocol": "tun", "settings": {"autoOutboundsInterface": 5}}]`,
		"интерфейс из env":  `[{"protocol": "tun", "settings": {"autoOutboundsInterface": "env:SECRET"}}]`,
		"файл в sniffing":   `[{"protocol": "tun", "sniffing": {"domainsExcluded": ["ext:../../secret.dat:x"]}}]`,
		"длинная метка":     `[{"protocol": "tun", "tag": "` + strings.Repeat("a", 100) + `"}]`,
	}
	for name, inbounds := range bad {
		raw := `{"inbounds": ` + inbounds + `, "outbounds": [{"protocol": "freedom"}]}`
		wantReject(t, name, raw)
	}
	wantReject(t, "нет раздела inbounds", `{"outbounds": [{"protocol": "freedom"}]}`)
	wantReject(t, "inbounds дважды", `{"inbounds": [`+tun+`], "INBOUNDS": [`+socks+`], "outbounds": [{"protocol": "freedom"}]}`)
}

func TestTunInboundIsRebuilt(t *testing.T) {
	raw := `{"inbounds": [{"protocol": "TUN", "tag": "t", "listen": "/run/x.sock", "port": 1080,
	  "streamSettings": {"security": "tls", "tlsSettings": {"certificates": [{"certificateFile": "C:\\cert.pem", "keyFile": "C:\\key.pem"}]}},
	  "allocate": {"strategy": "random"},
	  "settings": {"name": "wg0", "desc": "WireGuard Tunnel", "userLevel": 7, "autoSystemDnsToGateway": true, "mtu": 1400, "unknown": "C:\\x"}}],
	  "outbounds": [{"protocol": "freedom"}]}`
	m := mustTunnel(t, raw)
	tun := m["inbounds"].([]any)[0].(map[string]any)
	if len(tun) != 3 || tun["protocol"] != "tun" || tun["tag"] != "t" {
		t.Errorf("вход: %v", tun)
	}
	s := tun["settings"].(map[string]any)
	if len(s) != 3 || s["name"] != TunName || s["desc"] != TunName || s["mtu"] != float64(1400) {
		t.Errorf("настройки: %v", s)
	}
}

func TestRejectsFilesAndSockets(t *testing.T) {
	cert := `"realitySettings": {"serverName": "addons.mozilla.org", "fingerprint": "chrome", "publicKey": "abc", "shortId": "01"}`
	bad := map[string]string{
		"certificateFile":      with(t, cert, `"tlsSettings": {"certificates": [{"certificateFile": "C:\\Users\\victim\\secret.txt", "keyFile": "x"}]}`),
		"keyFile":              with(t, cert, `"tlsSettings": {"certificates": [{"certificate": ["x"], "keyFile": "secret.pem"}]}`),
		"относительный файл":   with(t, cert, `"tlsSettings": {"certificates": [{"certificateFile": "..\\..\\x.pem"}]}`),
		"CertificateFile":      with(t, cert, `"tlsSettings": {"certificates": [{"CERTIFICATEFILE": "x.pem"}]}`),
		"certificate_file":     with(t, cert, `"tlsSettings": {"certificates": [{"certificate_file": "x.pem"}]}`),
		"keyFile через K":      with(t, cert, `"tlsSettings": {"certificates": [{"\u212aeyFile": "x.pem"}]}`),
		"masterKeyLog tls":     with(t, cert, `"tlsSettings": {"masterKeyLog": "C:\\Windows\\System32\\x.dll"}`),
		"masterKeyLog через ſ": with(t, cert, `"tlsSettings": {"ma\u017fterKeyLog": "x.log"}`),
		"masterKeyLog reality": with(t, cert, `"realitySettings": {"masterKeyLog": "x.log"}`),
		"вложенный xhttp":      with(t, cert, `"xhttpSettings": {"extra": {"downloadSettings": {"tlsSettings": {"certificates": [{"keyFile": "x"}]}}}}`),
		"xdrive":               with(t, `"network": "ws"`, `"network": "xdrive"`),
		"xdrive method":        with(t, `"network": "ws"`, `"method": "XDrive"`),
		"xdriveSettings":       with(t, cert, `"xdriveSettings": {"service": "local", "remoteFolder": "C:\\Windows"}`),
		"masquerade":           with(t, cert, `"hysteriaSettings": {"version": 2, "masquerade": {"type": "file", "dir": "C:\\"}}`),
		"сценарий dns":         with(t, `"queryStrategy": "UseIPv4"`, `"script": "evil.lua"`),
		"сценарий маршрутов":   with(t, `"domainStrategy": "IPIfNonMatch"`, `"script": "C:\\evil.lua"`),
		"сценарий finalmask":   with(t, cert, `"finalmask": {"tcp": [{"type": "lua", "settings": {"script": "x.lua"}}]}`),
		"webhook":              with(t, `"port": 53, "outboundTag": "dns-out"`, `"port": 53, "outboundTag": "dns-out", "webhook": {"url": "http://127.0.0.1:2375/containers/json"}`),
		"адрес из env":         with(t, `"address": "nl.example.com"`, `"address": "env:COMPUTERNAME"`),
		"порт из env":          with(t, `"port": 443`, `"port": "env:SECRET_PORT"`),
		"ENV: в регистре":      with(t, `"address": "nl.example.com"`, `"address": "ENV:PATH"`),
		"unix redirect":        with(t, `{"tag": "direct", "protocol": "freedom"}`, `{"tag": "direct", "protocol": "freedom", "settings": {"redirect": "unix:/run/docker.sock"}}`),
		"unix url":             with(t, `"1.1.1.1", "8.8.8.8"`, `"http+unix:///run/x.sock/dns-query"`),
		"UNC":                  with(t, `"address": "nl.example.com"`, `"address": "\\\\evil.example\\share\\x"`),
		"устройство":           with(t, `"address": "nl.example.com"`, `"address": "\\\\.\\pipe\\docker_engine"`),
		"путь с диском":        with(t, `"serverName": "addons.mozilla.org"`, `"serverName": "c:/windows/win.ini"`),
		"file url":             with(t, `"serverName": "addons.mozilla.org"`, `"serverName": "file:///etc/passwd"`),
		"чужие геоданные":      with(t, `"ext:geoip.dat:ru"`, `"ext:secrets.dat:ru"`),
		"геоданные с путём":    with(t, `"ext:geoip.dat:ru"`, `"ext:../../Users/x/geoip.dat:ru"`),
		"ext-ip":               with(t, `"ext:geoip.dat:ru"`, `"ext-ip:C:\\x.dat:ru"`),
		"ext-domain":           with(t, `"ext:geosite.dat:category-ru"`, `"ext-domain:other.dat:ru"`),
		"!ext":                 with(t, `"!geoip:cn"`, `"!ext:other.dat:cn"`),
		"EXT в регистре":       with(t, `"ext:geoip.dat:ru"`, `"EXT:Other.dat:ru"`),
		"геоданные в dns":      with(t, `"geosite:category-ru"`, `"ext:other.dat:ru"`),
		"путь в ключе":         with(t, `"headers": {"Host": "example.com"}`, `"headers": {"C:\\x": "example.com"}`),
		"протокол":             with(t, `{"tag": "block", "protocol": "blackhole"}`, `{"tag": "block", "protocol": "exec"}`),
		"протокол числом":      with(t, `{"tag": "block", "protocol": "blackhole"}`, `{"tag": "block", "protocol": 1}`),
		"исходящий строкой":    with(t, `{"tag": "block", "protocol": "blackhole"}`, `"blackhole"`),
		"dns не объект":        with(t, `"routing": {`, `"policy": "C:\\x", "routing": {`),
	}
	for name, raw := range bad {
		wantReject(t, name, raw)
	}
	wantReject(t, "нет исходящих", `{"inbounds": [{"protocol": "tun"}]}`)
	wantReject(t, "пустые исходящие", `{"inbounds": [{"protocol": "tun"}], "outbounds": []}`)
	many := strings.Repeat(`{"protocol": "freedom"},`, 300)
	wantReject(t, "много исходящих", `{"inbounds": [{"protocol": "tun"}], "outbounds": [`+strings.TrimSuffix(many, ",")+`]}`)
}

func TestStripsCustomSockopt(t *testing.T) {
	raw := with(t, `"sockopt": {"domainStrategy": "UseIP"}`, `"sockopt": {"domainStrategy": "UseIP", "interface": "Ethernet", "customSockopt": [{"level": "6", "opt": "13", "value": "bbr"}]}`)
	out, err := Tunnel(raw)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ToLower(out), "customsockopt") {
		t.Error("customSockopt остался")
	}
	if !strings.Contains(out, `"interface":"Ethernet"`) || !strings.Contains(out, `"domainStrategy":"UseIP"`) {
		t.Error("пропали разрешённые поля sockopt")
	}
}

func TestInvalidInput(t *testing.T) {
	bad := map[string]string{
		"пусто":           ``,
		"пробелы":         `   `,
		"не JSON":         `hello`,
		"обрыв":           `{"inbounds": [`,
		"список":          `[]`,
		"строка":          `"x"`,
		"число":           `1`,
		"null":            `null`,
		"два значения":    `{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"freedom"}]} {"api":{}}`,
		"мусор в конце":   `{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"freedom"}]} x`,
		"комментарий":     `{"inbounds":[{"protocol":"tun"}], // x` + "\n" + `"outbounds":[{"protocol":"freedom"}]}`,
		"неверный UTF-8":  "{\"inbounds\":[{\"protocol\":\"tun\"}],\"outbounds\":[{\"protocol\":\"freedom\",\"tag\":\"\xff\xfe\"}]}",
		"нулевой байт":    "{\"inbounds\":[{\"protocol\":\"tun\"}],\x00\"outbounds\":[{\"protocol\":\"freedom\"}]}",
		"глубина":         `{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"freedom","settings":` + strings.Repeat(`{"a":`, 200) + `1` + strings.Repeat(`}`, 200) + `}]}`,
		"глубина списков": `{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"freedom","settings":` + strings.Repeat(`[`, 100000) + strings.Repeat(`]`, 100000) + `}]}`,
	}
	for name, raw := range bad {
		wantReject(t, name, raw)
	}
}

func TestOversized(t *testing.T) {
	pad := strings.Repeat("a", MaxSize)
	raw := `{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"freedom","tag":"` + pad + `"}]}`
	wantReject(t, "больше предела", raw)
	if _, err := Probe(raw); err == nil {
		t.Error("Probe: ожидался отказ")
	}
	// чуть меньше предела проходит
	pad = strings.Repeat("a", MaxSize-200)
	raw = `{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"freedom","tag":"` + pad + `"}]}`
	if _, err := Tunnel(raw); err != nil {
		t.Errorf("под пределом: %v", err)
	}
}

func TestProbe(t *testing.T) {
	// то, что собирает buildProbeConfig
	raw := `{"dns": {"servers": ["1.1.1.1"]}, "api": {"tag": "api"}, "inbounds": [], "log": {"loglevel": "none", "access": "C:\\x"},
	  "outbounds": [{"tag": "proxy", "protocol": "trojan", "settings": {"servers": [{"address": "1.2.3.4", "port": 443, "password": "p"}]}}],
	  "routing": {"rules": [], "script": "x.lua"}}`
	out, err := Probe(raw)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatal(err)
	}
	if len(m) != 3 || len(m["inbounds"].([]any)) != 0 || len(m["outbounds"].([]any)) != 1 {
		t.Errorf("probe: %s", out)
	}
	if log := m["log"].(map[string]any); len(log) != 1 || log["loglevel"] != "none" {
		t.Errorf("log: %v", log)
	}
	if _, err := Probe(`{"outbounds": [{"protocol": "freedom"}]}`); err != nil {
		t.Errorf("без inbounds: %v", err)
	}
	for name, bad := range map[string]string{
		"вход socks":    `{"inbounds": [{"protocol": "socks", "port": 1080}], "outbounds": [{"protocol": "freedom"}]}`,
		"вход tun":      `{"inbounds": [{"protocol": "tun"}], "outbounds": [{"protocol": "freedom"}]}`,
		"входы строкой": `{"inbounds": "x", "outbounds": [{"protocol": "freedom"}]}`,
		"файл":          `{"outbounds": [{"protocol": "vless", "streamSettings": {"tlsSettings": {"masterKeyLog": "x"}}}]}`,
		"нет исходящих": `{"inbounds": []}`,
		"не JSON":       `{`,
	} {
		if out, err := Probe(bad); err == nil {
			t.Errorf("%s: ожидался отказ, получено %s", name, out)
		}
	}
}

func TestFold(t *testing.T) {
	for in, want := range map[string]string{
		"masterKeyLog": "MASTERKEYLOG", "MASTER_KEY-LOG": "MASTERKEYLOG", "ma\u017fterKeyLog": "MASTERKEYLOG",
		"\u212aeyFile": "KEYFILE", "api": "API", "fakeDns": "FAKEDNS", "fakedns": "FAKEDNS",
	} {
		if got := fold(in); got != want {
			t.Errorf("fold(%q) = %q, want %q", in, got, want)
		}
	}
}

func FuzzTunnel(f *testing.F) {
	f.Add(good)
	f.Add(`{"inbounds":[{"protocol":"tun"}],"outbounds":[{"protocol":"freedom"}]}`)
	f.Add(`{"inbounds":[{"protocol":"socks"}]}`)
	f.Fuzz(func(t *testing.T, raw string) {
		out, err := Tunnel(raw)
		if err != nil {
			return
		}
		// что бы ни пришло, на выходе один вход tun, журнал без файлов и ни одного запрещённого раздела
		var m map[string]any
		if err := json.Unmarshal([]byte(out), &m); err != nil {
			t.Fatalf("на выходе не JSON: %v", err)
		}
		for k := range m {
			switch k {
			case "log", "inbounds", "outbounds", "dns", "routing", "policy", "fakeDns", "observatory", "burstObservatory":
			default:
				t.Fatalf("лишний раздел %q", k)
			}
		}
		in := m["inbounds"].([]any)
		if len(in) != 1 || in[0].(map[string]any)["protocol"] != "tun" {
			t.Fatalf("входы: %v", in)
		}
		var walk func(v any)
		walk = func(v any) {
			switch x := v.(type) {
			case map[string]any:
				for k, item := range x {
					if _, denied := deniedKeys[fold(k)]; denied || strippedKeys[fold(k)] {
						t.Fatalf("осталось поле %q", k)
					}
					walk(item)
				}
			case []any:
				for _, item := range x {
					walk(item)
				}
			}
		}
		walk(m["outbounds"])
		walk(m["dns"])
		walk(m["routing"])
	})
}
