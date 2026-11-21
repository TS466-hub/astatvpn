package proto

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestLineReader(t *testing.T) {
	r := NewLineReader(strings.NewReader("{\"id\":1}\n\n  \r\n{\"id\":2}\r\n"), 100)
	for _, want := range []string{`{"id":1}`, `{"id":2}`} {
		got, err := r.Next()
		if err != nil || string(got) != want {
			t.Fatalf("got %q, %v; want %q", got, err, want)
		}
	}
	if _, err := r.Next(); err != io.EOF {
		t.Fatalf("want EOF, got %v", err)
	}
}

func TestLineReaderLimit(t *testing.T) {
	// ровно предел проходит, на байт больше — нет
	ok := strings.Repeat("a", 99) + "\n"
	if got, err := NewLineReader(strings.NewReader(ok), 100).Next(); err != nil || len(got) != 99 {
		t.Fatalf("len %d, err %v", len(got), err)
	}
	big := strings.Repeat("a", 200<<10) + "\n"
	if _, err := NewLineReader(strings.NewReader(big), 100<<10).Next(); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("want ErrTooLarge, got %v", err)
	}
	// без перевода строки и без конца потока память не растёт дальше предела
	endless := io.MultiReader(strings.NewReader(strings.Repeat("a", 300<<10)), neverEnds{})
	if _, err := NewLineReader(endless, 100<<10).Next(); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("want ErrTooLarge, got %v", err)
	}
}

type neverEnds struct{}

func (neverEnds) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'a'
	}
	return len(p), nil
}

func TestLineReaderUnfinished(t *testing.T) {
	if _, err := NewLineReader(strings.NewReader(`{"id":1,"method":"stop"}`), 100).Next(); err == nil {
		t.Fatal("строка без перевода строки не должна считаться запросом")
	}
}

func TestParseRequest(t *testing.T) {
	req, err := ParseRequest([]byte(`{"id":7,"method":"start","params":{"config":"{}","name":"NL"}}`))
	if err != nil || req.ID != 7 || req.Method != "start" {
		t.Fatalf("%+v %v", req, err)
	}
	var p StartParams
	if err := json.Unmarshal(req.Params, &p); err != nil || p.Name != "NL" || p.Config != "{}" {
		t.Fatalf("%+v %v", p, err)
	}
	for _, bad := range []string{``, `{`, `[]`, `"x"`, `{"id":"x","method":"stop"}`, `{"id":1}`, `{"id":1,"method":5}`, "\x00\xff"} {
		if _, err := ParseRequest([]byte(bad)); err == nil {
			t.Errorf("%q: ожидалась ошибка", bad)
		}
	}
}

func TestStatusShape(t *testing.T) {
	// поля и null должны совпадать с тем, что читает VpnStatus.fromMap
	b, err := Encode(Event{Event: "status", Data: Status{State: StateDisconnected}})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"event":"status","data":{"state":"disconnected","since":0,"error":null,"rx":0,"tx":0,"name":null}}` + "\n"
	if string(b) != want {
		t.Fatalf("got  %s\nwant %s", b, want)
	}
	name, e := "🇳🇱 <NL> & Co", "сбой"
	b, _ = Encode(Response{ID: 3, OK: true, Result: Status{State: StateConnected, Since: 5, Error: &e, Rx: 1, Tx: 2, Name: &name}})
	want = `{"id":3,"ok":true,"result":{"state":"connected","since":5,"error":"сбой","rx":1,"tx":2,"name":"🇳🇱 <NL> & Co"}}` + "\n"
	if string(b) != want {
		t.Fatalf("got  %s\nwant %s", b, want)
	}
	b, _ = Encode(Response{ID: 4, Error: "нет"})
	if string(b) != `{"id":4,"ok":false,"error":"нет"}`+"\n" {
		t.Fatalf("got %s", b)
	}
}
