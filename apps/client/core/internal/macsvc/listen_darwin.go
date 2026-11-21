//go:build darwin

// Package macsvc — всё, что относится к macOS: сокет службы, установка через launchd, системный DNS, счётчики.
package macsvc

import (
	"errors"
	"net"
	"os"
	"syscall"

	"golang.org/x/sys/unix"

	"astatvpn/core/internal/proto"
	"astatvpn/core/internal/xraycore"
)

// Listen создаёт сокет службы.
//
//   - Сокет лежит в /var/run: создать файл с таким именем может только система.
//   - Подключиться может только человек, который сейчас сидит за этим Mac (владелец консоли), и root.
//     Другие учётные записи и фоновые службы отклоняются по данным ядра о подключившемся процессе.
//   - Сетевые порты не открываются.
func Listen() (net.Listener, error) {
	return listenAt(proto.SocketPath, consoleUser)
}

func listenAt(path string, allowed func() (uint32, bool)) (net.Listener, error) {
	// старый файл сокета остаётся после принудительного завершения; если служба уже работает, подключение пройдёт
	if conn, err := net.Dial("unix", path); err == nil {
		conn.Close()
		return nil, errors.New("служба уже запущена")
	}
	_ = os.Remove(path)
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	// права 0666: сам сокет открыт всем, а кто именно подключился, проверяется при каждом подключении
	if err := os.Chmod(path, 0o666); err != nil {
		l.Close()
		return nil, err
	}
	return &listener{Listener: l, allowed: allowed}, nil
}

type listener struct {
	net.Listener
	allowed func() (uint32, bool)
}

func (l *listener) Accept() (net.Conn, error) {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		uid, ok := peerUID(conn)
		if ok && l.permits(uid) {
			return conn, nil
		}
		xraycore.Logf("подключение отклонено: его открыл не тот, кто работает за этим компьютером")
		conn.Close()
	}
}

func (l *listener) permits(uid uint32) bool {
	if uid == 0 {
		return true
	}
	user, ok := l.allowed()
	return ok && user == uid
}

// peerUID — учётная запись процесса на другом конце сокета (сообщает ядро, подделать нельзя).
func peerUID(conn net.Conn) (uint32, bool) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, false
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0, false
	}
	var cred *unix.Xucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	}); err != nil || credErr != nil || cred == nil {
		return 0, false
	}
	return cred.Uid, true
}

// consoleUser — кто сейчас вошёл в систему за этим Mac: ему принадлежит /dev/console.
func consoleUser() (uint32, bool) {
	info, err := os.Stat("/dev/console")
	if err != nil {
		return 0, false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid == 0 {
		// за компьютером никого нет (окно входа): подключаться некому
		return 0, false
	}
	return stat.Uid, true
}
