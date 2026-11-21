//go:build darwin

package macsvc

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func socketPath(t *testing.T) string {
	t.Helper()
	// путь к сокету в macOS ограничен 104 байтами: каталог теста для него слишком длинный
	dir, err := os.MkdirTemp("/tmp", "astat")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "s")
}

func echo(t *testing.T, l net.Listener) {
	t.Helper()
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				line, _ := bufio.NewReader(conn).ReadString('\n')
				conn.Write([]byte(line))
			}()
		}
	}()
}

func roundTrip(path string) (string, error) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte("привет\n")); err != nil {
		return "", err
	}
	return bufio.NewReader(conn).ReadString('\n')
}

func TestListenerAcceptsConsoleUser(t *testing.T) {
	path := socketPath(t)
	me := uint32(os.Getuid())
	l, err := listenAt(path, func() (uint32, bool) { return me, true })
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	echo(t, l)
	got, err := roundTrip(path)
	if err != nil || strings.TrimSpace(got) != "привет" {
		t.Fatalf("ответ %q, ошибка %v", got, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o666 {
		t.Fatalf("права сокета %v, ошибка %v", info.Mode().Perm(), err)
	}
}

func TestListenerRejectsOtherUsers(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root допускается всегда")
	}
	for name, allowed := range map[string]func() (uint32, bool){
		"за компьютером другой человек": func() (uint32, bool) { return uint32(os.Getuid()) + 1, true },
		"за компьютером никого нет":     func() (uint32, bool) { return 0, false },
	} {
		t.Run(name, func(t *testing.T) {
			path := socketPath(t)
			l, err := listenAt(path, allowed)
			if err != nil {
				t.Fatal(err)
			}
			defer l.Close()
			echo(t, l)
			if got, err := roundTrip(path); err == nil && got != "" {
				t.Fatalf("служба ответила постороннему: %q", got)
			}
		})
	}
}

func TestListenRefusesSecondInstance(t *testing.T) {
	path := socketPath(t)
	me := func() (uint32, bool) { return uint32(os.Getuid()), true }
	first, err := listenAt(path, me)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	echo(t, first)
	if second, err := listenAt(path, me); err == nil {
		second.Close()
		t.Fatal("вторая служба заняла тот же сокет")
	}
}

func TestListenReplacesStaleSocket(t *testing.T) {
	path := socketPath(t)
	// файл остался от службы, завершённой принудительно
	stale, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	stale.(*net.UnixListener).SetUnlinkOnClose(false)
	stale.Close()
	l, err := listenAt(path, func() (uint32, bool) { return uint32(os.Getuid()), true })
	if err != nil {
		t.Fatalf("старый файл сокета помешал запуску: %v", err)
	}
	l.Close()
}

func TestCountersReadRealInterface(t *testing.T) {
	// lo0 есть всегда, и через него уже что-то прошло: сокеты тестов выше не в счёт, но система им пользуется
	if _, _, ok := countersFor("lo0"); !ok {
		t.Fatal("счётчики lo0 не прочитаны")
	}
	if _, _, ok := countersFor("utun-нет-такого"); ok {
		t.Fatal("счётчики несуществующего интерфейса")
	}
}

func TestParseCountersIgnoresGarbage(t *testing.T) {
	for _, buf := range [][]byte{nil, {1}, {0, 0, 0, 0}, {255, 255, 5, 0x12}, {4, 0, 5, 0x12, 4, 0}} {
		if _, _, ok := parseCounters(buf, 1); ok {
			t.Fatalf("мусор принят за счётчики: %v", buf)
		}
	}
}

func TestNetworkServicesAreReadable(t *testing.T) {
	services, err := networkServices()
	if err != nil || len(services) == 0 {
		t.Fatalf("сетевые службы не прочитаны: %v, %v", services, err)
	}
	for _, s := range services {
		if strings.HasPrefix(s, "*") || strings.Contains(s, "asterisk") {
			t.Fatalf("в список попала лишняя строка: %q", s)
		}
		// чтение не меняет настройки
		for _, ip := range currentDNS(s) {
			if net.ParseIP(ip) == nil {
				t.Fatalf("не адрес: %q", ip)
			}
		}
	}
}

func TestPlistPointsToInstallDir(t *testing.T) {
	p := plist()
	for _, want := range []string{Label, InstallDir + "/astat-helper", "<string>run</string>", "KeepAlive"} {
		if !strings.Contains(p, want) {
			t.Fatalf("в описании службы нет %q", want)
		}
	}
}
