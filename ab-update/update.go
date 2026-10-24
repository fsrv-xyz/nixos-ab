package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"text/template"
)

// entry is a UKI of this image on the ESP.
type entry struct {
	Number   int
	UsrHash  string
	Default  bool
	Selected bool
}

var entryName = regexp.MustCompile(`^(.+)_([0-9]+)(\+[0-9]+(-[0-9]+)?)?\.efi$`)

func parseEntries(id string, bootctlJSON []byte) ([]entry, error) {
	var list []struct {
		Type       string
		Path       string
		Cmdline    string
		IsDefault  bool
		IsSelected bool
	}
	if err := json.Unmarshal(bootctlJSON, &list); err != nil {
		return nil, fmt.Errorf("bootctl list: %w", err)
	}
	var entries []entry
	for _, e := range list {
		m := entryName.FindStringSubmatch(filepath.Base(e.Path))
		if e.Type != "type2" || m == nil || m[1] != id {
			continue
		}
		n, err := strconv.Atoi(m[2])
		if err != nil {
			return nil, fmt.Errorf("%s: %w", e.Path, err)
		}
		entries = append(entries, entry{Number: n, UsrHash: usrHash(e.Cmdline), Default: e.IsDefault, Selected: e.IsSelected})
	}
	return entries, nil
}

func usrHash(cmdline string) string {
	for _, f := range strings.Fields(cmdline) {
		if h, ok := strings.CutPrefix(f, "usrhash="); ok {
			return h
		}
	}
	return ""
}

func imageID(osRelease io.Reader) (string, error) {
	s := bufio.NewScanner(osRelease)
	for s.Scan() {
		if v, ok := strings.CutPrefix(s.Text(), "IMAGE_ID="); ok {
			return strings.Trim(v, `"`), nil
		}
	}
	if err := s.Err(); err != nil {
		return "", err
	}
	return "", errors.New("os-release has no IMAGE_ID")
}

// plan says whether the incoming image needs installing, and under which number.
type plan struct {
	Install bool
	Number  int
	Running int
	Message string
}

func runningNumber(entries []entry) (int, error) {
	for _, e := range entries {
		if e.Selected {
			return e.Number, nil
		}
	}
	return 0, errors.New("no UKI of this image is the booted entry")
}

func decide(id string, entries []entry, running, incoming string) (plan, error) {
	current, err := runningNumber(entries)
	if err != nil {
		return plan{}, err
	}
	if incoming == running {
		return plan{Number: current, Running: current, Message: fmt.Sprintf("%s_%d runs this image already", id, current)}, nil
	}
	highest := 0
	for _, e := range entries {
		if e.Default && e.UsrHash == incoming {
			return plan{Number: e.Number, Running: current, Message: fmt.Sprintf("%s_%d holds this image already and boots next", id, e.Number)}, nil
		}
		highest = max(highest, e.Number)
	}
	// Above every entry, a used-up one included: sysupdate takes an installed version as done.
	return plan{Install: true, Number: highest + 1, Running: current}, nil
}

// rewriteSums renames the artifacts in the build's SHA256SUMS to carry the number sysupdate
// installs them as, and maps each new name to the file it serves.
func rewriteSums(id string, number int, sums []byte) ([]byte, map[string]string, error) {
	var out bytes.Buffer
	files := map[string]string{}
	for line := range strings.Lines(string(sums)) {
		hash, name, ok := strings.Cut(strings.TrimSpace(line), "  ")
		if !ok {
			continue
		}
		var renamed string
		switch {
		case name == id+".efi":
			renamed = fmt.Sprintf("%s_%d.efi", id, number)
		case strings.HasPrefix(name, id+"_") && strings.HasSuffix(name, ".raw.zst"):
			renamed = fmt.Sprintf("%s_%d_%s", id, number, strings.TrimPrefix(name, id+"_"))
		default:
			continue
		}
		files[renamed] = name
		fmt.Fprintf(&out, "%s  %s\n", hash, renamed)
	}
	if len(files) == 0 {
		return nil, nil, fmt.Errorf("SHA256SUMS lists no artifacts of image %s", id)
	}
	return out.Bytes(), files, nil
}

type source interface {
	Open(name string) (io.ReadCloser, error)
}

type dirSource string

func (d dirSource) Open(name string) (io.ReadCloser, error) {
	return os.Open(filepath.Join(string(d), name))
}

type urlSource string

func (u urlSource) Open(name string) (io.ReadCloser, error) {
	resp, err := http.Get(string(u) + name)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("%s%s: %s", u, name, resp.Status)
	}
	return resp.Body, nil
}

func newSource(s string) source {
	if strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://") {
		return urlSource(strings.TrimSuffix(s, "/") + "/")
	}
	return dirSource(s)
}

func readAll(src source, name string) ([]byte, error) {
	f, err := src.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

// server hands sysupdate the artifacts under their numbered names.
type server struct {
	src   source
	sums  []byte
	files map[string]string
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/")
	if name == "SHA256SUMS" {
		w.Write(s.sums)
		return
	}
	original, ok := s.files[name]
	if !ok {
		http.NotFound(w, r)
		return
	}
	f, err := s.src.Open(original)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer f.Close()
	io.Copy(w, f)
}

type definitions struct {
	Source  string
	Running int
}

func renderDefinitions(templates, out string, data definitions) error {
	paths, err := filepath.Glob(filepath.Join(templates, "*.transfer"))
	if err != nil {
		return err
	}
	for _, p := range paths {
		t, err := template.New(filepath.Base(p)).Option("missingkey=error").ParseFiles(p)
		if err != nil {
			return err
		}
		f, err := os.Create(filepath.Join(out, filepath.Base(p)))
		if err != nil {
			return err
		}
		err = errors.Join(t.Execute(f, data), f.Close())
		if err != nil {
			return err
		}
	}
	return nil
}
