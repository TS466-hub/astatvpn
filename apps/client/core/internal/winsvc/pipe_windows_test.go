//go:build windows

package winsvc

import (
	"bufio"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"

	"astatvpn/core/internal/helper"
	"astatvpn/core/internal/proto"
)

// Эти проверки идут только в Windows (например, в GitHub Actions на windows-latest):
// канал создаётся по-настоящему, с теми же правами, что и в службе.

const clientAccess = windows.GENERIC_READ | windows.FILE_WRITE_DATA

func listen(t *testing.T) (stop func()) {
	t.Helper()
	l, err := Listen()
	if err != nil {
		t.Skipf("канал не создан (служба уже запущена или нет прав): %v", err)
	}
	server, engine := helper.New(helper.Options{Dir: t.TempDir()})
	done := make(chan struct{})
	go func() { defer close(done); _ = server.Serve(l) }()
	return func() {
		engine.Shutdown()
		l.Close()
		<-done
	}
}

func TestPipeFirstInstanceOnly(t *testing.T) {
	stop := listen(t)
	defer stop()
	if l, err := Listen(); err == nil {
		l.Close()
		t.Fatal("второй канал с тем же именем создан: имя можно занять")
	}
}

func TestPipeRequest(t *testing.T) {
	stop := listen(t)
	defer stop()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// так же открывает канал приложение: чтение и FILE_WRITE_DATA, без GENERIC_WRITE
	conn, err := winio.DialPipeAccess(ctx, proto.PipeName, clientAccess)
	if err != nil {
		t.Fatalf("канал не открылся: %v", err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(`{"id":1,"method":"version"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(conn)
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("не JSON: %q", line)
		}
		if _, event := m["event"]; event {
			continue
		}
		if m["ok"] != true || m["result"].(map[string]any)["core"] != "26.11.9" {
			t.Fatalf("%v", m)
		}
		return
	}
}

func openPipe(name *uint16, access uint32) (windows.Handle, error) {
	deadline := time.Now().Add(5 * time.Second)
	for {
		handle, err := windows.CreateFile(name, access, 0, nil, windows.OPEN_EXISTING, 0, 0)
		if err != windows.ERROR_PIPE_BUSY || time.Now().After(deadline) {
			return handle, err
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestPipeSecurity(t *testing.T) {
	stop := listen(t)
	defer stop()
	name, _ := windows.UTF16PtrFromString(proto.PipeName)
	handle, err := openPipe(name, clientAccess)
	if err != nil {
		t.Fatalf("канал не открылся: %v", err)
	}
	defer windows.CloseHandle(handle)

	sd, err := windows.GetSecurityInfo(handle, windows.SE_KERNEL_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	// Служба работает от SYSTEM, а этот тест создаёт канал от имени пользователя Windows.
	owner, _, err := sd.Owner()
	if err != nil {
		t.Fatal(err)
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	if !owner.IsWellKnown(windows.WinLocalSystemSid) && !owner.IsWellKnown(windows.WinBuiltinAdministratorsSid) && owner.String() != user.User.Sid.String() {
		t.Errorf("неожиданный владелец тестового канала: %s", owner)
	}

	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil {
		t.Fatalf("нет списка прав: %v", err)
	}
	const createPipeInstance = 0x4 // FILE_CREATE_PIPE_INSTANCE
	want := map[string]bool{"S-1-5-18": true, "S-1-5-32-544": true, "S-1-5-4": true}
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			t.Fatal(err)
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		if !want[sid] {
			t.Errorf("лишняя запись в правах канала: %s", sid)
		}
		delete(want, sid)
		if sid == "S-1-5-4" && ace.Mask&createPipeInstance != 0 {
			t.Error("обычные программы могут создавать экземпляры канала")
		}
	}
	if len(want) != 0 {
		t.Errorf("в правах канала нет записей: %v", want)
	}
	if !strings.Contains(sd.String(), "D:P") {
		t.Errorf("права канала наследуются: %s", sd.String())
	}

	// с GENERIC_WRITE обычной программе канал не откроется; у администратора (как в CI) откроется
	if h, err := openPipe(name, windows.GENERIC_READ|windows.GENERIC_WRITE); err == nil {
		windows.CloseHandle(h)
		if !windows.GetCurrentProcessToken().IsElevated() {
			t.Error("канал открылся с GENERIC_WRITE без прав администратора")
		}
	} else if err != windows.ERROR_ACCESS_DENIED {
		t.Fatalf("не удалось проверить GENERIC_WRITE: %v", err)
	}
}
