//go:build darwin

package macsvc

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"astatvpn/core/internal/helper"
	"astatvpn/core/internal/proto"
	"astatvpn/core/internal/xraycore"
)

const (
	// Label — имя службы в launchd.
	Label = "shop.autohitech.astatvpn.helper"

	helperName = "astat-helper"
	plistPath  = "/Library/LaunchDaemons/" + Label + ".plist"
)

var payload = []string{helperName, "geoip.dat", "geosite.dat"}

func plist() string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + Label + `</string>
	<key>ProgramArguments</key>
	<array>
		<string>` + filepath.Join(InstallDir, helperName) + `</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
`
}

func needRoot() error {
	if os.Geteuid() != 0 {
		return errors.New("нужны права администратора")
	}
	return nil
}

// Install копирует службу в системный каталог и запускает её через launchd.
// Повторный вызов обновляет файлы и перезапускает службу.
//
// Служба работает из своего каталога, а не из приложения: каталог приложения человек может менять без
// пароля, и программа с его правами могла бы подменить файл, который система запускает от имени root.
func Install() error {
	if err := needRoot(); err != nil {
		return err
	}
	source, err := ExeDir()
	if err != nil {
		return err
	}
	for _, name := range payload {
		info, err := os.Lstat(filepath.Join(source, name))
		if err != nil || !info.Mode().IsRegular() {
			return errors.New("рядом со службой нет файла " + name + ". Установите приложение заново")
		}
	}

	stopDaemon()
	if err := os.MkdirAll(InstallDir, 0o755); err != nil {
		return err
	}
	// каталог мог существовать с другими правами
	if err := os.Chown(InstallDir, 0, 0); err != nil {
		return err
	}
	if err := os.Chmod(InstallDir, 0o755); err != nil {
		return err
	}
	if source != InstallDir {
		for _, name := range payload {
			mode := os.FileMode(0o644)
			if name == helperName {
				mode = 0o755
			}
			if err := copyFile(filepath.Join(source, name), filepath.Join(InstallDir, name), mode); err != nil {
				return fmt.Errorf("не удалось скопировать %s: %w", name, err)
			}
		}
	}
	if err := writeRootFile(plistPath, []byte(plist()), 0o644); err != nil {
		return fmt.Errorf("не удалось записать описание службы: %w", err)
	}
	if out, err := run("/bin/launchctl", "bootstrap", "system", plistPath); err != nil {
		return fmt.Errorf("система не запустила службу: %s", strings.TrimSpace(out))
	}
	_, _ = run("/bin/launchctl", "enable", "system/"+Label)

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if conn, err := net.Dial("unix", proto.SocketPath); err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("служба установлена, но не отвечает")
}

// Uninstall останавливает службу и удаляет её файлы. Если её нет, это не ошибка.
func Uninstall() error {
	if err := needRoot(); err != nil {
		return err
	}
	stopDaemon()
	// служба при остановке сама возвращает DNS; это страховка на случай, если её завершили принудительно
	CleanupAfterCrash()
	_ = os.Remove(plistPath)
	_ = os.Remove(proto.SocketPath)
	return os.RemoveAll(InstallDir)
}

// stopDaemon выгружает службу и ждёт, пока она завершится (при остановке она убирает туннель и возвращает DNS).
func stopDaemon() {
	if _, err := run("/bin/launchctl", "print", "system/"+Label); err != nil {
		return
	}
	_, _ = run("/bin/launchctl", "bootout", "system/"+Label)
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := run("/bin/launchctl", "print", "system/"+Label); err != nil {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// copyFile пишет во временный файл и переименовывает: служба не увидит наполовину записанный файл.
func copyFile(from, to string, mode os.FileMode) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	return writeRootFile(to, data, mode)
}

func writeRootFile(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".new"
	_ = os.Remove(tmp)
	// O_EXCL и O_NOFOLLOW: не пишем по подложенной ссылке
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, mode)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Chown(0, 0)
	}
	if err == nil {
		err = f.Chmod(mode)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// start поднимает службу и возвращает функцию остановки.
func start() (stop func(), err error) {
	dir, err := ExeDir()
	if err != nil {
		return nil, err
	}
	CleanupAfterCrash()
	server, engine := helper.New(helper.Options{Dir: dir, Counters: Counters, PreStart: PreStart(dir), PostStop: PostStop})
	l, err := Listen()
	if err != nil {
		return nil, fmt.Errorf("не удалось создать сокет %s: %w", proto.SocketPath, err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := server.Serve(l); err != nil {
			xraycore.Logf("приём подключений остановлен: " + err.Error())
		}
	}()
	return func() {
		// сначала убираем туннель и возвращаем DNS: это важнее, чем аккуратно попрощаться с приложением
		engine.Shutdown()
		l.Close()
		_ = os.Remove(proto.SocketPath)
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
	}, nil
}

// Run запускает службу: под launchd или в терминале через sudo для отладки.
func Run() error {
	if err := needRoot(); err != nil {
		return err
	}
	stop, err := start()
	if err != nil {
		return err
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	<-signals
	stop()
	return nil
}
