//go:build darwin

// astat-helper — служба AstatVPN: единственная часть приложения с правами системы.
package main

import (
	"fmt"
	"os"

	"astatvpn/core/internal/macsvc"
	"astatvpn/core/internal/xraycore"
)

const usage = `astat-helper — служба AstatVPN

  sudo astat-helper install     скопировать службу в систему и запустить
  sudo astat-helper uninstall   остановить и удалить службу
  sudo astat-helper run         запуск службы (вызывает система; в терминале — для отладки)
  astat-helper version          версии службы и ядра`

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "install":
		err = macsvc.Install()
	case "uninstall":
		err = macsvc.Uninstall()
	case "run":
		err = macsvc.Run()
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
