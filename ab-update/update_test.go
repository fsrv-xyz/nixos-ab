package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const (
	hashA = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
	hashB = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"
	hashC = "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
)

func TestParseEntries(t *testing.T) {
	data := []byte(`[
		{"type":"type2","path":"/boot/EFI/Linux/ab_3.efi","cmdline":"init=/x usrhash=` + hashA + `","isDefault":false,"isSelected":true},
		{"type":"type2","path":"/boot/EFI/Linux/ab_4+2-1.efi","cmdline":"usrhash=` + hashB + ` quiet","isDefault":true,"isSelected":false},
		{"type":"type2","path":"/boot/EFI/Linux/other_7.efi","cmdline":"usrhash=` + hashC + `"},
		{"type":"type1","path":"/boot/loader/entries/ab_9.conf"},
		{"type":"auto","id":"auto-reboot-to-firmware-setup"}
	]`)
	got, err := parseEntries("ab", data)
	if err != nil {
		t.Fatal(err)
	}
	want := []entry{
		{Number: 3, UsrHash: hashA, Selected: true},
		{Number: 4, UsrHash: hashB, Default: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestDecide(t *testing.T) {
	running := entry{Number: 3, UsrHash: hashA, Selected: true, Default: true}
	failed := entry{Number: 4, UsrHash: hashB}
	staged := entry{Number: 4, UsrHash: hashB, Default: true}

	for _, tc := range []struct {
		name     string
		entries  []entry
		incoming string
		want     plan
	}{
		{"running image", []entry{running, failed}, hashA, plan{Number: 3, Running: 3, Message: "ab_3 runs this image already"}},
		{"staged image", []entry{{Number: 3, UsrHash: hashA, Selected: true}, staged}, hashB, plan{Number: 4, Running: 3, Message: "ab_4 holds this image already and boots next"}},
		{"new image after a rollback", []entry{running, failed}, hashC, plan{Install: true, Number: 5, Running: 3}},
		{"failed image again", []entry{running, failed}, hashB, plan{Install: true, Number: 5, Running: 3}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := decide("ab", tc.entries, hashA, tc.incoming)
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}

	if _, err := decide("ab", []entry{failed}, hashA, hashC); err == nil {
		t.Fatal("no booted entry: want an error")
	}
}

func TestRewriteSums(t *testing.T) {
	sums := []byte("11  ab.efi\n" +
		"22  ab_0f3a-uuid.store.raw.zst\n" +
		"33  ab_9c1e-uuid.verity.raw.zst\n" +
		"44  usrhash\n")
	got, files, err := rewriteSums("ab", 5, sums)
	if err != nil {
		t.Fatal(err)
	}
	wantSums := "11  ab_5.efi\n22  ab_5_0f3a-uuid.store.raw.zst\n33  ab_5_9c1e-uuid.verity.raw.zst\n"
	if string(got) != wantSums {
		t.Fatalf("got sums %q, want %q", got, wantSums)
	}
	wantFiles := map[string]string{
		"ab_5.efi":                      "ab.efi",
		"ab_5_0f3a-uuid.store.raw.zst":  "ab_0f3a-uuid.store.raw.zst",
		"ab_5_9c1e-uuid.verity.raw.zst": "ab_9c1e-uuid.verity.raw.zst",
	}
	if !reflect.DeepEqual(files, wantFiles) {
		t.Fatalf("got files %v, want %v", files, wantFiles)
	}

	if _, _, err := rewriteSums("other", 5, sums); err == nil {
		t.Fatal("artifacts of another image: want an error")
	}
}

func TestServer(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "ab.efi"), []byte("uki"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(&server{
		src:   newSource(dir),
		sums:  []byte("11  ab_5.efi\n"),
		files: map[string]string{"ab_5.efi": "ab.efi"},
	})
	defer srv.Close()

	for path, want := range map[string]string{"/SHA256SUMS": "11  ab_5.efi\n", "/ab_5.efi": "uki"} {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK || string(body) != want {
			t.Fatalf("%s: got %d %q, want %q", path, resp.StatusCode, body, want)
		}
	}
	resp, err := http.Get(srv.URL + "/ab.efi")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unrenamed name: got %d, want 404", resp.StatusCode)
	}
}

func TestRenderDefinitions(t *testing.T) {
	templates, out := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(templates, "20-store.transfer"), []byte("[Source]\nPath={{.Source}}\n[Transfer]\nProtectVersion={{.Running}}\n"), 0o644)
	os.WriteFile(filepath.Join(templates, "url"), []byte("http://updates.example/"), 0o644)

	if err := renderDefinitions(templates, out, definitions{Source: "http://127.0.0.1:4711/", Running: 3}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(out, "20-store.transfer"))
	if err != nil {
		t.Fatal(err)
	}
	if want := "[Source]\nPath=http://127.0.0.1:4711/\n[Transfer]\nProtectVersion=3\n"; string(got) != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	if names, _ := filepath.Glob(filepath.Join(out, "*")); len(names) != 1 {
		t.Fatalf("got %v, want only the transfer", names)
	}
}

func TestUsrHashAndImageID(t *testing.T) {
	if got := usrHash("init=/x usrhash=" + hashA + " quiet\n"); got != hashA {
		t.Fatalf("usrHash: got %q", got)
	}
	id, err := imageID(strings.NewReader("NAME=NixOS\nIMAGE_ID=\"example\"\nIMAGE_VERSION=\"\"\n"))
	if err != nil || id != "example" {
		t.Fatalf("imageID: got %q, %v", id, err)
	}
}
