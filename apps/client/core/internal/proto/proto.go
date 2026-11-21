// Package proto описывает обмен между приложением и службой: строки JSON, разделённые переводом строки.
//
// Запрос:  {"id":1,"method":"start","params":{...}}
// Ответ:   {"id":1,"ok":true,"result":{...}} или {"id":1,"ok":false,"error":"текст"}
// Событие: {"event":"status","data":{...}} — без запроса, при смене состояния и раз в секунду при подключении.
package proto

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

const (
	// PipeName — имя канала службы.
	PipeName = `\\.\pipe\AstatVPN`

	// PipeSDDL — кто может открыть канал: SYSTEM и администраторы полностью, вошедшие в систему люди — только
	// читать и писать. В правах для IU нет FILE_CREATE_PIPE_INSTANCE (0x4), которое входит в GENERIC_WRITE:
	// с ним любая программа могла бы создать свой экземпляр канала и принимать чужие подключения.
	// Поэтому клиент открывает канал с правами GENERIC_READ | FILE_WRITE_DATA, а не GENERIC_WRITE.
	PipeSDDL = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x12019b;;;IU)"

	// SocketPath — сокет службы в macOS. Каталог /var/run доступен на запись только системе,
	// поэтому сокет с этим именем может создать только служба.
	SocketPath = "/var/run/astatvpn.sock"

	// MaxRequestSize — предел длины одной строки запроса.
	MaxRequestSize = 4 << 20

	// MaxPingConfigs — сколько серверов можно замерить одним запросом.
	MaxPingConfigs = 256
)

// Состояния подключения. Совпадают с VpnState в приложении.
const (
	StateDisconnected = "disconnected"
	StateConnecting   = "connecting"
	StateConnected    = "connected"
	StateStopping     = "stopping"
)

// Status — то, что видит приложение. Имена полей менять нельзя: их читает VpnStatus.fromMap.
type Status struct {
	State string  `json:"state"`
	Since int64   `json:"since"`
	Error *string `json:"error"`
	Rx    uint64  `json:"rx"`
	Tx    uint64  `json:"tx"`
	Name  *string `json:"name"`
}

// Request — запрос приложения.
type Request struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// Response — ответ службы.
type Response struct {
	ID     int64  `json:"id"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

// Event — сообщение без запроса.
type Event struct {
	Event string `json:"event"`
	Data  any    `json:"data"`
}

// StartParams — параметры запуска.
type StartParams struct {
	Config string `json:"config"`
	Name   string `json:"name"`
}

// PingParams — параметры замера задержки.
type PingParams struct {
	Configs []string `json:"configs"`
}

// PingResult — задержки в мс, -1 — сервер не ответил.
type PingResult struct {
	Delays []int `json:"delays"`
}

// VersionResult — версии ядра и службы.
type VersionResult struct {
	Core   string `json:"core"`
	Helper string `json:"helper"`
}

// LogsResult — последние строки журнала ядра.
type LogsResult struct {
	Text string `json:"text"`
}

// ErrTooLarge — строка длиннее MaxRequestSize.
var ErrTooLarge = errors.New("запрос слишком большой")

// LineReader читает строки с ограничением длины. Слишком длинная строка не накапливается в памяти.
type LineReader struct {
	r   *bufio.Reader
	max int
}

// NewLineReader создаёт читателя с пределом max байт на строку.
func NewLineReader(r io.Reader, max int) *LineReader {
	return &LineReader{r: bufio.NewReaderSize(r, 64<<10), max: max}
}

// Next возвращает следующую непустую строку без перевода строки.
// ErrTooLarge означает, что поток дальше читать нельзя: граница запроса потеряна.
func (l *LineReader) Next() ([]byte, error) {
	for {
		var line []byte
		for {
			chunk, err := l.r.ReadSlice('\n')
			if len(line)+len(chunk) > l.max {
				return nil, ErrTooLarge
			}
			line = append(line, chunk...)
			if err == nil {
				break
			}
			if err != bufio.ErrBufferFull {
				// обрыв посреди строки: незаконченный запрос не выполняем
				return nil, err
			}
		}
		line = bytes.TrimSpace(line)
		if len(line) > 0 {
			return line, nil
		}
	}
}

// ParseRequest разбирает строку запроса.
func ParseRequest(line []byte) (Request, error) {
	var req Request
	if err := json.Unmarshal(line, &req); err != nil {
		return Request{}, errors.New("некорректный запрос")
	}
	if req.Method == "" {
		return Request{ID: req.ID}, errors.New("в запросе не указан метод")
	}
	return req, nil
}

// Encode превращает ответ или событие в строку с переводом строки на конце.
func Encode(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
