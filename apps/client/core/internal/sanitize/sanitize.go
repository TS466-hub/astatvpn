// Package sanitize проверяет конфигурацию Xray, полученную от приложения.
//
// Служба работает с правами системы, а прислать конфигурацию может любая программа вошедшего в систему человека.
// Поэтому из конфигурации убирается всё, чем ядро могло бы читать и писать файлы, открывать порты,
// менять переменные окружения или обращаться к локальным сокетам от имени системы.
package sanitize

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	// MaxSize — предел размера одной конфигурации.
	MaxSize = 4 << 20

	maxDepth     = 64
	maxOutbounds = 256
)

// Error — отказ с текстом для человека.
type Error struct{ msg string }

func (e *Error) Error() string { return e.msg }

func reject(format string, args ...any) error {
	return &Error{msg: "Конфигурация отклонена: " + fmt.Sprintf(format, args...)}
}

// Ядро сопоставляет имена полей без учёта регистра (encoding/json), в новых версиях ещё и без учёта «_» и «-»,
// а буквы вроде «ſ» и «K» (знак кельвина) считает равными «s» и «k». Сравниваем так же, иначе запрет
// обходился бы написанием "MasterKeyLog" или "certificate_file".
func fold(name string) string {
	out := make([]byte, 0, len(name))
	for i := 0; i < len(name); {
		if c := name[i]; c < utf8.RuneSelf {
			if c != '_' && c != '-' {
				if 'a' <= c && c <= 'z' {
					c -= 'a' - 'A'
				}
				out = append(out, c)
			}
			i++
			continue
		}
		r, n := utf8.DecodeRuneInString(name[i:])
		for {
			r2 := unicode.SimpleFold(r)
			if r2 <= r {
				r = r2
				break
			}
			r = r2
		}
		out = utf8.AppendRune(out, r)
		i += n
	}
	return string(out)
}

// Разделы верхнего уровня, которые остаются. Остального (api, stats, metrics, reverse, env, geodata,
// transport и любых неизвестных) в итоговой конфигурации не будет.
var topLevel = map[string]string{
	"DNS":              "dns",
	"ROUTING":          "routing",
	"OUTBOUNDS":        "outbounds",
	"POLICY":           "policy",
	"FAKEDNS":          "fakeDns",
	"OBSERVATORY":      "observatory",
	"BURSTOBSERVATORY": "burstObservatory",
}

// Поля, из-за которых ядро обращается к файлам, локальным сокетам или сторонним адресам.
var deniedKeys = map[string]string{
	"CERTIFICATEFILE": "файл сертификата (certificateFile)",
	"KEYFILE":         "файл ключа (keyFile)",
	"MASTERKEYLOG":    "запись ключей TLS в файл (masterKeyLog)",
	"SCRIPT":          "сценарий Lua из файла (script)",
	"WEBHOOK":         "уведомления на сторонний адрес (webhook)",
	"MASQUERADE":      "раздача файлов (masquerade)",
	"XDRIVESETTINGS":  "транспорт xdrive, работающий с папкой на диске",
}

// Поля, которые молча убираются: с ними подключение работает так же.
var strippedKeys = map[string]bool{
	// произвольные параметры сокетов службы
	"CUSTOMSOCKOPT": true,
}

var outboundProtocols = map[string]bool{
	"block": true, "blackhole": true, "loopback": true, "direct": true, "freedom": true,
	"http": true, "shadowsocks": true, "socks": true, "vless": true, "vmess": true, "trojan": true,
	"hysteria": true, "masque": true, "dns": true, "wireguard": true,
}

var geoFiles = map[string]bool{"geoip.dat": true, "geosite.dat": true}

func parse(raw string) (map[string]any, error) {
	if len(raw) > MaxSize {
		return nil, reject("слишком большой размер")
	}
	if !utf8.ValidString(raw) {
		return nil, reject("это не JSON")
	}
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, reject("это не JSON")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, reject("после JSON идут лишние данные")
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, reject("ожидался объект JSON")
	}
	return obj, nil
}

// split раскладывает верхний уровень по каноническим именам и ловит повторы вроде "dns" и "DNS".
func split(obj map[string]any) (map[string]any, error) {
	out := make(map[string]any, len(obj))
	for key, value := range obj {
		f := fold(key)
		if _, dup := out[f]; dup {
			return nil, reject("раздел «%s» указан дважды", key)
		}
		out[f] = value
	}
	return out, nil
}

// Tunnel готовит конфигурацию для подключения: единственный вход tun, журнал только в память.
func Tunnel(raw string) (string, error) {
	obj, err := parse(raw)
	if err != nil {
		return "", err
	}
	top, err := split(obj)
	if err != nil {
		return "", err
	}

	out := map[string]any{"log": logSection(top["LOG"])}

	inbound, err := tunInbound(top["INBOUNDS"])
	if err != nil {
		return "", err
	}
	out["inbounds"] = []any{inbound}

	if err := copySections(top, out); err != nil {
		return "", err
	}
	return encode(out)
}

// Probe готовит конфигурацию для замера задержки: только исходящие каналы, без входов, правил и DNS.
func Probe(raw string) (string, error) {
	obj, err := parse(raw)
	if err != nil {
		return "", err
	}
	top, err := split(obj)
	if err != nil {
		return "", err
	}
	if in, present := top["INBOUNDS"]; present && in != nil {
		list, ok := in.([]any)
		if !ok || len(list) > 0 {
			return "", reject("для замера задержки входы не допускаются")
		}
	}
	outbounds, err := outboundList(top["OUTBOUNDS"])
	if err != nil {
		return "", err
	}
	return encode(map[string]any{
		"log":       map[string]any{"loglevel": "none"},
		"inbounds":  []any{},
		"outbounds": outbounds,
	})
}

func encode(v any) (string, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "", reject("не удалось собрать JSON")
	}
	return strings.TrimSpace(buf.String()), nil
}

func copySections(top, out map[string]any) error {
	outbounds, err := outboundList(top["OUTBOUNDS"])
	if err != nil {
		return err
	}
	out["outbounds"] = outbounds
	for folded, name := range topLevel {
		if folded == "OUTBOUNDS" {
			continue
		}
		value, present := top[folded]
		if !present || value == nil {
			continue
		}
		if _, ok := value.(map[string]any); !ok {
			return reject("раздел «%s» должен быть объектом", name)
		}
		clean, err := scrub(value, name, 0)
		if err != nil {
			return err
		}
		out[name] = clean
	}
	return nil
}

// logSection: уровень берётся из запроса, пути к файлам — никогда. Журнал подключений выключен:
// в нём были бы адреса, которые открывает человек, а читать журнал службы может любая программа.
func logSection(v any) map[string]any {
	level := "warning"
	if obj, ok := v.(map[string]any); ok {
		for key, value := range obj {
			if fold(key) != "LOGLEVEL" {
				continue
			}
			if s, ok := value.(string); ok {
				switch strings.ToLower(s) {
				case "info", "none":
					level = strings.ToLower(s)
				}
			}
		}
	}
	return map[string]any{"loglevel": level, "access": "none"}
}

func tunInbound(v any) (map[string]any, error) {
	list, ok := v.([]any)
	if !ok || len(list) == 0 {
		return nil, reject("нет входа tun")
	}
	if len(list) != 1 {
		return nil, reject("допускается только один вход, и только tun")
	}
	raw, ok := list[0].(map[string]any)
	if !ok {
		return nil, reject("вход должен быть объектом")
	}
	in, err := split(raw)
	if err != nil {
		return nil, err
	}
	protocol, _ := in["PROTOCOL"].(string)
	if strings.ToLower(protocol) != "tun" {
		return nil, reject("допускается только вход tun, а не «%s»", clip(protocol))
	}

	// Собираем вход заново из известных полей: listen, port, streamSettings и прочее сюда не попадает.
	out := map[string]any{"protocol": "tun", "tag": "tun"}
	if tag, ok := in["TAG"].(string); ok && tag != "" {
		if len(tag) > 64 {
			return nil, reject("слишком длинная метка входа")
		}
		out["tag"] = tag
	}
	if sniffing, ok := in["SNIFFING"].(map[string]any); ok {
		clean, err := scrub(sniffing, "sniffing", 0)
		if err != nil {
			return nil, err
		}
		out["sniffing"] = clean
	}

	settings := map[string]any{"name": TunName, "desc": TunName, "mtu": 1500}
	if rawSettings, present := in["SETTINGS"]; present && rawSettings != nil {
		obj, ok := rawSettings.(map[string]any)
		if !ok {
			return nil, reject("настройки входа tun должны быть объектом")
		}
		s, err := split(obj)
		if err != nil {
			return nil, err
		}
		if mtu, present := s["MTU"]; present {
			n, ok := mtu.(json.Number)
			i, err := n.Int64()
			if !ok || err != nil || i < 576 || i > 9000 {
				return nil, reject("недопустимый MTU")
			}
			settings["mtu"] = i
		}
		// Ядро разбирает эти адреса без проверки и падает на неверных, поэтому проверяем здесь.
		if list, err := stringList(s["GATEWAY"], "gateway", isPrefix); err != nil {
			return nil, err
		} else if list != nil {
			settings["gateway"] = list
		}
		if list, err := stringList(s["DNS"], "dns", isAddr); err != nil {
			return nil, err
		} else if list != nil {
			settings["dns"] = list
		}
		if list, err := stringList(s["AUTOSYSTEMROUTINGTABLE"], "autoSystemRoutingTable", isPrefix); err != nil {
			return nil, err
		} else if list != nil {
			settings["autoSystemRoutingTable"] = list
		}
		if list, err := stringList(s["AUTOSYSTEMWFPBLOCKLEAK"], "autoSystemWfpBlockLeak", isShort); err != nil {
			return nil, err
		} else if list != nil {
			settings["autoSystemWfpBlockLeak"] = list
		}
		if iface, present := s["AUTOOUTBOUNDSINTERFACE"]; present && iface != nil {
			name, ok := iface.(string)
			if !ok || !isShort(name) {
				return nil, reject("недопустимое значение autoOutboundsInterface")
			}
			settings["autoOutboundsInterface"] = name
		}
	}
	out["settings"] = settings
	return out, nil
}

func isPrefix(s string) bool { _, err := netip.ParsePrefix(s); return err == nil }
func isAddr(s string) bool   { _, err := netip.ParseAddr(s); return err == nil }
func isShort(s string) bool  { return len(s) <= 256 && checkString(s) == nil }

func stringList(v any, name string, valid func(string) bool) ([]any, error) {
	if v == nil {
		return nil, nil
	}
	list, ok := v.([]any)
	if !ok || len(list) > 256 {
		return nil, reject("поле %s должно быть списком строк", name)
	}
	out := make([]any, 0, len(list))
	for _, item := range list {
		s, ok := item.(string)
		if !ok || !valid(s) {
			return nil, reject("недопустимое значение в %s", name)
		}
		out = append(out, s)
	}
	return out, nil
}

func outboundList(v any) ([]any, error) {
	list, ok := v.([]any)
	if !ok || len(list) == 0 {
		return nil, reject("нет исходящих подключений")
	}
	if len(list) > maxOutbounds {
		return nil, reject("слишком много исходящих подключений")
	}
	out := make([]any, 0, len(list))
	for _, item := range list {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, reject("исходящее подключение должно быть объектом")
		}
		for key, value := range obj {
			if fold(key) != "PROTOCOL" {
				continue
			}
			protocol, _ := value.(string)
			if !outboundProtocols[strings.ToLower(protocol)] {
				return nil, reject("протокол «%s» не поддерживается", clip(protocol))
			}
		}
		clean, err := scrub(obj, "outbounds", 0)
		if err != nil {
			return nil, err
		}
		out = append(out, clean)
	}
	return out, nil
}

// scrub обходит раздел целиком: запрещённые поля и значения — отказ, лишние — убираются.
func scrub(v any, where string, depth int) (any, error) {
	if depth > maxDepth {
		return nil, reject("слишком глубокая вложенность в разделе «%s»", where)
	}
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for key, value := range t {
			f := fold(key)
			if what, denied := deniedKeys[f]; denied {
				return nil, reject("в разделе «%s» не допускается %s", where, what)
			}
			if strippedKeys[f] {
				continue
			}
			if err := checkString(key); err != nil {
				return nil, err
			}
			if f == "NETWORK" || f == "METHOD" {
				if s, ok := value.(string); ok && strings.EqualFold(strings.TrimSpace(s), "xdrive") {
					return nil, reject("в разделе «%s» не допускается %s", where, deniedKeys["XDRIVESETTINGS"])
				}
			}
			clean, err := scrub(value, where, depth+1)
			if err != nil {
				return nil, err
			}
			out[key] = clean
		}
		return out, nil
	case []any:
		out := make([]any, 0, len(t))
		for _, item := range t {
			clean, err := scrub(item, where, depth+1)
			if err != nil {
				return nil, err
			}
			out = append(out, clean)
		}
		return out, nil
	case string:
		if err := checkString(t); err != nil {
			return nil, err
		}
		return t, nil
	default:
		return v, nil
	}
}

// checkString отклоняет значения, которые ядро понимает как путь, локальный сокет или переменную окружения.
func checkString(s string) error {
	lower := strings.ToLower(strings.TrimLeft(s, " \t!"))
	switch {
	case strings.HasPrefix(lower, "env:"):
		// "env:ИМЯ" в адресе или порте подставляет значение переменной окружения службы
		return reject("не допускаются значения из переменных окружения (env:)")
	case strings.HasPrefix(lower, "unix:"), strings.Contains(lower, "unix://"):
		return reject("не допускаются локальные сокеты (unix:)")
	case strings.HasPrefix(lower, `\\`), strings.HasPrefix(lower, "//./"), strings.HasPrefix(lower, "//?/"):
		return reject("не допускаются сетевые и системные пути")
	case len(lower) >= 3 && lower[0] >= 'a' && lower[0] <= 'z' && lower[1] == ':' && (lower[2] == '\\' || lower[2] == '/'):
		return reject("не допускаются пути к файлам")
	case strings.HasPrefix(lower, "file:"):
		return reject("не допускаются пути к файлам")
	}
	for _, prefix := range []string{"ext:", "ext-ip:", "ext-domain:", "ext-site:"} {
		if !strings.HasPrefix(lower, prefix) {
			continue
		}
		// "ext:файл:список" читает файл из каталога службы: там лежат только эти два
		file, _, _ := strings.Cut(lower[len(prefix):], ":")
		if !geoFiles[file] {
			return reject("не допускаются сторонние файлы геоданных")
		}
	}
	return nil
}

func clip(s string) string {
	const max = 40
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	return string([]rune(s)[:max]) + "…"
}
