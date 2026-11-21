package helper

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"
)

// Сквозная проверка без Windows: настоящие проверка конфигурации и ядро, вместо канала — пара в памяти.
func TestEndToEnd(t *testing.T) {
	srv, eng := New(Options{Dir: t.TempDir()})
	defer eng.Shutdown()
	server, client := net.Pipe()
	go srv.Handle(server)
	defer client.Close()
	r := bufio.NewReaderSize(client, 1<<20)

	call := func(line string) map[string]any {
		t.Helper()
		go func() { _, _ = client.Write([]byte(line + "\n")) }()
		for {
			_ = client.SetReadDeadline(time.Now().Add(20 * time.Second))
			text, err := r.ReadString('\n')
			if err != nil {
				t.Fatalf("чтение: %v", err)
			}
			var m map[string]any
			if err := json.Unmarshal([]byte(text), &m); err != nil {
				t.Fatalf("не JSON: %q", text)
			}
			if _, event := m["event"]; !event {
				return m
			}
		}
	}

	v := call(`{"id":1,"method":"version"}`)
	if v["ok"] != true || v["result"].(map[string]any)["core"] != "26.11.9" || v["result"].(map[string]any)["helper"] == "" {
		t.Fatalf("%v", v)
	}

	// вход socks: ядро не запускается, порт не открывается
	bad, _ := json.Marshal(`{"inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":19080}],"outbounds":[{"protocol":"freedom"}]}`)
	res := call(`{"id":2,"method":"start","params":{"config":` + string(bad) + `,"name":"x"}}`)
	if res["ok"] != false || !strings.HasPrefix(res["error"].(string), "Конфигурация отклонена") {
		t.Fatalf("%v", res)
	}
	if conn, err := net.DialTimeout("tcp", "127.0.0.1:19080", 300*time.Millisecond); err == nil {
		conn.Close()
		t.Fatal("открыт локальный порт")
	}

	// замер через сервер, который не отвечает: -1, служба жива
	probe, _ := json.Marshal(`{"inbounds":[],"log":{"loglevel":"none"},"outbounds":[{"tag":"proxy","protocol":"blackhole"}],"routing":{"rules":[]}}`)
	res = call(`{"id":3,"method":"ping","params":{"configs":[` + string(probe) + `,"мусор"]}}`)
	delays := res["result"].(map[string]any)["delays"].([]any)
	if res["ok"] != true || len(delays) != 2 || delays[0] != float64(-1) || delays[1] != float64(-1) {
		t.Fatalf("%v", res)
	}

	res = call(`{"id":4,"method":"status"}`)
	if res["result"].(map[string]any)["state"] != "disconnected" {
		t.Fatalf("%v", res)
	}
	if res = call(`{"id":5,"method":"logs"}`); res["ok"] != true {
		t.Fatalf("%v", res)
	}
}
