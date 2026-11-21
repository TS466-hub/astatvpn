//go:build darwin

package macsvc

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"

	"astatvpn/core/internal/sanitize"
	"astatvpn/core/internal/xraycore"
)

const (
	// InstallDir — каталог службы. Принадлежит системе: обычная программа не может подменить в нём файлы.
	InstallDir = "/Library/Application Support/AstatVPN"

	// TunnelDNS — адрес внутри туннеля. Запросы к нему перехватывает ядро и отправляет по своим правилам.
	TunnelDNS = "172.19.0.1"

	networksetup = "/usr/sbin/networksetup"
	rtmIfinfo2   = 0x12
)

// ExeDir — каталог, в котором лежит служба.
func ExeDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return filepath.Dir(exe), nil
}

// Counters читает счётчики интерфейса туннеля. Для utun «принято» — это то, что ядро отдало системе
// (загрузка у человека), «отправлено» — то, что система отдала ядру (отдача).
func Counters() (rx, tx uint64, ok bool) { return countersFor(sanitize.TunName) }

func countersFor(name string) (rx, tx uint64, ok bool) {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return 0, 0, false
	}
	// таблица интерфейсов ядра с 64-битными счётчиками
	buf, err := syscall.RouteRIB(unix.NET_RT_IFLIST2, iface.Index)
	if err != nil {
		return 0, 0, false
	}
	return parseCounters(buf, iface.Index)
}

func parseCounters(buf []byte, index int) (rx, tx uint64, ok bool) {
	size := int(unsafe.Sizeof(unix.IfMsghdr2{}))
	for len(buf) >= 4 {
		length := int(*(*uint16)(unsafe.Pointer(&buf[0])))
		if length < 4 || length > len(buf) {
			return 0, 0, false
		}
		if buf[3] == rtmIfinfo2 && length >= size {
			msg := (*unix.IfMsghdr2)(unsafe.Pointer(&buf[0]))
			if int(msg.Index) == index {
				return msg.Data.Ibytes, msg.Data.Obytes, true
			}
		}
		buf = buf[length:]
	}
	return 0, 0, false
}

// PreStart проверяет перед запуском ядра, что геобазы на месте, и направляет системный DNS в туннель.
func PreStart(dir string) func() error {
	return func() error {
		for _, name := range []string{"geoip.dat", "geosite.dat"} {
			info, err := os.Stat(filepath.Join(dir, name))
			if err != nil || !info.Mode().IsRegular() {
				return errors.New("рядом со службой нет файла " + name + ". Установите службу заново")
			}
		}
		return dns.redirect()
	}
}

// PostStop возвращает системный DNS после остановки ядра.
func PostStop() { dns.restore() }

// CleanupAfterCrash возвращает системный DNS, если служба была завершена принудительно при включённом VPN.
func CleanupAfterCrash() { dns.restore() }

// dnsState — что было в настройках DNS до подключения. Хранится на диске, чтобы пережить сбой службы:
// иначе после него в системе остался бы адрес из выключенного туннеля и интернет бы не работал.
type dnsState struct {
	mu sync.Mutex
}

var dns dnsState

func stateFile() string { return filepath.Join(InstallDir, "dns-state.json") }

// macOS сама не меняет DNS при появлении туннеля: запросы шли бы провайдеру мимо VPN.
// Поэтому на время подключения у всех сетевых служб ставится адрес внутри туннеля.
func (d *dnsState) redirect() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.restoreLocked()
	services, err := networkServices()
	if err != nil || len(services) == 0 {
		return errors.New("не удалось прочитать сетевые настройки системы")
	}
	saved := map[string][]string{}
	for _, service := range services {
		saved[service] = currentDNS(service)
	}
	data, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	if err := os.WriteFile(stateFile(), data, 0o600); err != nil {
		return errors.New("не удалось сохранить прежние настройки DNS: " + err.Error())
	}
	for _, service := range services {
		if err := setDNS(service, []string{TunnelDNS}); err != nil {
			xraycore.Logf("не удалось направить DNS в туннель для «" + service + "»: " + err.Error())
		}
	}
	flushDNS()
	return nil
}

func (d *dnsState) restore() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.restoreLocked()
}

func (d *dnsState) restoreLocked() {
	data, err := os.ReadFile(stateFile())
	if err != nil {
		return
	}
	saved := map[string][]string{}
	if json.Unmarshal(data, &saved) == nil {
		for service, servers := range saved {
			// возвращаем только то, что сами поставили: если человек успел поменять DNS, его выбор остаётся
			if current := currentDNS(service); len(current) == 1 && current[0] == TunnelDNS {
				if err := setDNS(service, servers); err != nil {
					xraycore.Logf("не удалось вернуть DNS для «" + service + "»: " + err.Error())
				}
			}
		}
	}
	_ = os.Remove(stateFile())
	flushDNS()
}

func run(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// networkServices — включённые сетевые службы (Wi-Fi, Ethernet и другие).
func networkServices() ([]string, error) {
	out, err := run(networksetup, "-listallnetworkservices")
	if err != nil {
		return nil, err
	}
	var services []string
	for i, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		// первая строка — пояснение, звёздочкой отмечены выключенные службы
		if i == 0 || line == "" || strings.HasPrefix(line, "*") {
			continue
		}
		services = append(services, line)
	}
	return services, nil
}

// currentDNS — серверы, заданные вручную; пустой список означает «брать у сети».
func currentDNS(service string) []string {
	out, err := run(networksetup, "-getdnsservers", service)
	if err != nil {
		return nil
	}
	var servers []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if net.ParseIP(line) != nil {
			servers = append(servers, line)
		}
	}
	return servers
}

func setDNS(service string, servers []string) error {
	args := []string{"-setdnsservers", service}
	if len(servers) == 0 {
		args = append(args, "Empty")
	} else {
		args = append(args, servers...)
	}
	out, err := run(networksetup, args...)
	if err != nil {
		return errors.New(strings.TrimSpace(out))
	}
	return nil
}

func flushDNS() {
	_, _ = run("/usr/bin/dscacheutil", "-flushcache")
	_, _ = run("/usr/bin/killall", "-HUP", "mDNSResponder")
}
