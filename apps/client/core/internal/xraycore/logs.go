package xraycore

import (
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	applog "github.com/xtls/xray-core/app/log"
	"github.com/xtls/xray-core/common"
	clog "github.com/xtls/xray-core/common/log"
)

const (
	logLines   = 500
	logLineMax = 2000
)

// Ring — последние строки журнала в памяти. На диск журнал не пишется.
type Ring struct {
	mu    sync.Mutex
	lines []string
	next  int
	full  bool
}

// NewRing создаёт журнал на size строк.
func NewRing(size int) *Ring {
	return &Ring{lines: make([]string, size)}
}

// Add добавляет строку, вытесняя самую старую.
func (r *Ring) Add(line string) {
	line = strings.TrimRight(line, "\r\n")
	if len(line) > logLineMax {
		cut := logLineMax
		for cut > 0 && !utf8.RuneStart(line[cut]) {
			cut--
		}
		line = line[:cut] + "…"
	}
	r.mu.Lock()
	r.lines[r.next] = line
	r.next++
	if r.next == len(r.lines) {
		r.next, r.full = 0, true
	}
	r.mu.Unlock()
}

// Text возвращает строки от старых к новым.
func (r *Ring) Text() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var parts []string
	if r.full {
		parts = append(parts, r.lines[r.next:]...)
	}
	parts = append(parts, r.lines[:r.next]...)
	return strings.Join(parts, "\n")
}

// Logs — журнал ядра и службы.
var Logs = NewRing(logLines)

// Logf пишет в журнал строку от имени службы.
func Logf(text string) {
	Logs.Add(time.Now().Format("2006/01/02 15:04:05") + " [служба] " + text)
}

type ringHandler struct{}

func (ringHandler) Handle(msg clog.Message) {
	Logs.Add(time.Now().Format("2006/01/02 15:04:05") + " " + msg.String())
}

func init() {
	// Куда бы конфигурация ни направляла журнал, ядро пишет его только в память:
	// обработчик для файлов заменён тем же, что и для консоли.
	toRing := func(applog.LogType, applog.HandlerCreatorOptions) (clog.Handler, error) {
		return ringHandler{}, nil
	}
	common.Must(applog.RegisterHandlerCreator(applog.LogType_Console, toRing))
	common.Must(applog.RegisterHandlerCreator(applog.LogType_File, toRing))
}
