//go:build windows

// Package winsvc — всё, что относится к Windows: именованный канал, служба, счётчики адаптера.
package winsvc

import (
	"net"

	"github.com/Microsoft/go-winio"

	"astatvpn/core/internal/proto"
)

// Listen создаёт именованный канал службы.
//
//   - Права задаёт proto.PipeSDDL: SYSTEM, администраторы и вошедшие в систему люди. Сетевых и анонимных входов
//     в списке нет, а go-winio дополнительно создаёт канал с FILE_PIPE_REJECT_REMOTE_CLIENTS.
//   - Первый экземпляр создаётся с FILE_CREATE: если канал с таким именем уже есть (его занял кто-то другой),
//     вызов завершается ошибкой, и служба не подключается к чужому каналу.
//   - Сетевые порты не открываются.
func Listen() (net.Listener, error) {
	return winio.ListenPipe(proto.PipeName, &winio.PipeConfig{
		SecurityDescriptor: proto.PipeSDDL,
		MessageMode:        false,
		InputBufferSize:    64 << 10,
		OutputBufferSize:   64 << 10,
	})
}
