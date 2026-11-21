//go:build windows

package winsvc

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"astatvpn/core/internal/helper"
	"astatvpn/core/internal/proto"
	"astatvpn/core/internal/xraycore"
)

const (
	// ServiceName — имя службы в системе.
	ServiceName = "AstatVPNHelper"

	displayName = "AstatVPN"
	description = "Создаёт VPN-подключение для приложения AstatVPN. Без этой службы приложение не сможет подключаться."
)

// Install регистрирует службу и запускает её. Повторный вызов обновляет путь и перезапускает.
func Install() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("нет доступа к диспетчеру служб (нужны права администратора): %w", err)
	}
	defer m.Disconnect()

	config := mgr.Config{
		ServiceType:      windows.SERVICE_WIN32_OWN_PROCESS,
		StartType:        mgr.StartAutomatic,
		ErrorControl:     mgr.ErrorNormal,
		DisplayName:      displayName,
		Description:      description,
		ServiceStartName: "LocalSystem",
	}

	s, err := m.OpenService(ServiceName)
	if err == nil {
		// служба уже есть: останавливаем и ставим заново, чтобы путь и параметры были текущими
		if err := stopAndWait(s); err != nil {
			s.Close()
			return err
		}
		err = s.Delete()
		s.Close()
		if err != nil {
			return fmt.Errorf("не удалось удалить прежнюю службу: %w", err)
		}
		if err := waitDeleted(m); err != nil {
			return err
		}
	}

	// CreateService сам берёт путь в кавычки: путь с пробелами нельзя подменить
	s, err = m.CreateService(ServiceName, exe, config, "run")
	if err != nil {
		return fmt.Errorf("не удалось создать службу: %w", err)
	}
	defer s.Close()

	// при сбое служба перезапускается, счётчик сбоев сбрасывается через сутки
	actions := []mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 2 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
	}
	if err := s.SetRecoveryActions(actions, 24*60*60); err != nil {
		return fmt.Errorf("не удалось задать перезапуск при сбое: %w", err)
	}
	_ = s.SetRecoveryActionsOnNonCrashFailures(true)

	if err := s.Start(); err != nil {
		return fmt.Errorf("служба создана, но не запустилась: %w", err)
	}
	return nil
}

// Uninstall останавливает и удаляет службу. Если её нет, это не ошибка.
func Uninstall() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("нет доступа к диспетчеру служб (нужны права администратора): %w", err)
	}
	defer m.Disconnect()
	s, err := m.OpenService(ServiceName)
	if err != nil {
		if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
			return nil
		}
		return err
	}
	defer s.Close()
	if err := stopAndWait(s); err != nil {
		return err
	}
	if err := s.Delete(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE) {
		return fmt.Errorf("не удалось удалить службу: %w", err)
	}
	return nil
}

// stopAndWait просит службу остановиться и ждёт: при остановке она убирает адаптер, маршруты и фильтры.
func stopAndWait(s *mgr.Service) error {
	status, err := s.Query()
	if err != nil {
		return err
	}
	if status.State == svc.Stopped {
		return nil
	}
	if status.State != svc.StopPending {
		if _, err := s.Control(svc.Stop); err != nil && !errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE) {
			return fmt.Errorf("не удалось остановить службу: %w", err)
		}
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		status, err = s.Query()
		if err != nil {
			return err
		}
		if status.State == svc.Stopped {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("служба не остановилась за 30 секунд")
}

func waitDeleted(m *mgr.Mgr) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		s, err := m.OpenService(ServiceName)
		if err != nil {
			return nil
		}
		s.Close()
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("прежняя служба не удалилась: закройте оснастку «Службы» и повторите")
}

type handler struct{}

// Execute — жизнь службы: поднять канал, обслуживать приложение, при остановке убрать туннель.
func (handler) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	stop, err := start()
	if err != nil {
		// код ошибки службы: диспетчер увидит сбой и перезапустит её по правилам восстановления
		xraycore.Logf("служба не запустилась: " + err.Error())
		return true, 1
	}
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for req := range requests {
		switch req.Cmd {
		case svc.Interrogate:
			status <- req.CurrentStatus
		case svc.Stop, svc.Shutdown:
			status <- svc.Status{State: svc.StopPending, WaitHint: 20000}
			stop()
			return false, 0
		}
	}
	stop()
	return false, 0
}

// start поднимает службу и возвращает функцию остановки.
func start() (stop func(), err error) {
	HardenDLLSearch()
	dir, err := ExeDir()
	if err != nil {
		return nil, err
	}
	CleanupAfterCrash()
	server, engine := helper.New(helper.Options{Dir: dir, Counters: Counters, PreStart: PreStart(dir)})
	listener, err := Listen()
	if err != nil {
		return nil, fmt.Errorf("не удалось создать канал %s (возможно, служба уже запущена): %w", proto.PipeName, err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := server.Serve(listener); err != nil {
			xraycore.Logf("приём подключений остановлен: " + err.Error())
		}
	}()
	return func() {
		// сначала убираем туннель: это важнее, чем аккуратно попрощаться с приложением
		engine.Shutdown()
		listener.Close()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
	}, nil
}

// Run запускает службу: под диспетчером служб или в консоли администратора для отладки.
func Run() error {
	isService, err := svc.IsWindowsService()
	if err != nil {
		return err
	}
	if isService {
		return svc.Run(ServiceName, handler{})
	}
	if !windows.GetCurrentProcessToken().IsElevated() {
		return errors.New("для запуска в консоли нужны права администратора")
	}
	stop, err := start()
	if err != nil {
		return err
	}
	fmt.Println("Служба AstatVPN работает в консоли. Ctrl+C — остановить.")
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt)
	<-interrupt
	stop()
	return nil
}
