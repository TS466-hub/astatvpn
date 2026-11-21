//go:build windows

// astat-helper — служба AstatVPN: единственная часть приложения с правами системы.
package main

import (
	"fmt"
	"os"

	"astatvpn/core/internal/winsvc"
	"astatvpn/core/internal/xraycore"
)

const usage = `astat-helper — служба AstatVPN

  astat-helper install     зарегистрировать и запустить службу (нужны права администратора)
  astat-helper uninstall   остановить и удалить службу
  astat-helper run         запуск службы (вызывает система; в консоли администратора — для отладки)
  astat-helper version     версии службы и ядра`

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "install":
		err = winsvc.Install()
	case "uninstall":
		err = winsvc.Uninstall()
	case "run":
		err = winsvc.Run()
	case "version":
		fmt.Printf("служба %s, ядро Xray %s\n", xraycore.HelperVersion, xraycore.Version())
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "Ошибка:", err)
		os.Exit(1)
	}
}
