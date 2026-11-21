//go:build windows

package winsvc

import (
	"errors"
	"net"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"

	"astatvpn/core/internal/sanitize"
)

const (
	loadLibrarySearchApplicationDir = 0x00000200
	loadLibrarySearchSystem32       = 0x00000800
)

// HardenDLLSearch оставляет для загрузки библиотек только каталог службы и system32:
// текущий каталог и PATH в поиске не участвуют.
func HardenDLLSearch() {
	_ = windows.SetDefaultDllDirectories(loadLibrarySearchApplicationDir | loadLibrarySearchSystem32)
}

// ExeDir — каталог, в котором лежит служба.
func ExeDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(exe), nil
}

// Counters читает счётчики адаптера AstatVPN (GetIfEntry2). Для адаптера Wintun «принято» — это то,
// что ядро отдало системе (загрузка у человека), «отправлено» — то, что система отдала ядру (отдача).
// Портов и API статистики ядра для этого не нужно.
func Counters() (rx, tx uint64, ok bool) {
	iface, err := net.InterfaceByName(sanitize.TunName)
	if err != nil {
		return 0, 0, false
	}
	luid, err := winipcfg.LUIDFromIndex(uint32(iface.Index))
	if err != nil {
		return 0, 0, false
	}
	row, err := luid.Interface()
	if err != nil {
		return 0, 0, false
	}
	return row.InOctets, row.OutOctets, true
}

// PreStart проверяет перед запуском ядра, что драйвер адаптера лежит рядом со службой.
func PreStart(dir string) func() error {
	return func() error {
		info, err := os.Stat(filepath.Join(dir, "wintun.dll"))
		if err != nil || !info.Mode().IsRegular() {
			return errors.New("рядом со службой нет файла wintun.dll. Переустановите приложение")
		}
		return nil
	}
}

var (
	modDnsapi                 = windows.NewLazySystemDLL("dnsapi.dll")
	procDnsFlushResolverCache = modDnsapi.NewProc("DnsFlushResolverCache")
)

// CleanupAfterCrash убирает то, что могло остаться, если служба была завершена принудительно.
//
// Что система убирает сама, когда процесс службы исчезает: фильтры WFP (сеанс динамический), адаптер Wintun
// вместе с его адресами, маршрутами и серверами имён. Остаётся кэш имён, полученных через туннель, — сбрасываем его.
// Параметр weak host send на основном интерфейсе ядро при работе выключает, это же и значение Windows по умолчанию.
func CleanupAfterCrash() {
	if procDnsFlushResolverCache.Find() == nil {
		_, _, _ = procDnsFlushResolverCache.Call()
	}
}
