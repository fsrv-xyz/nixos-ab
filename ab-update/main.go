// ab-update installs an image into the slot not running, numbered one above every UKI of the
// image on the ESP, and leaves the work to systemd-sysupdate.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Set at link time to the system's systemd.
var (
	bootctl   = "bootctl"
	sysupdate = "systemd-sysupdate"
)

var rootHash = regexp.MustCompile(`^[0-9a-f]{64}$`)

func main() {
	log.SetFlags(0)
	log.SetPrefix("ab-update: ")
	templates := flag.String("definitions", "/etc/ab-update", "`directory` of the transfer definition templates and the default source, url")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "usage: ab-update [-definitions directory] [directory | URL | vacuum]\n")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() > 1 {
		flag.Usage()
		os.Exit(2)
	}
	if err := run(*templates, flag.Arg(0)); err != nil {
		log.Fatal(err)
	}
}

func run(templates, arg string) error {
	osRelease, err := os.Open("/etc/os-release")
	if err != nil {
		return err
	}
	defer osRelease.Close()
	id, err := imageID(osRelease)
	if err != nil {
		return err
	}
	cmdline, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		return err
	}
	list, err := exec.Command(bootctl, "list", "--json=short").Output()
	if err != nil {
		return fmt.Errorf("bootctl list: %w", err)
	}
	entries, err := parseEntries(id, list)
	if err != nil {
		return err
	}

	if arg == "vacuum" {
		current, err := runningNumber(entries)
		if err != nil {
			return err
		}
		return update(templates, &server{}, current, "vacuum")
	}

	location := arg
	if location == "" {
		b, err := os.ReadFile(filepath.Join(templates, "url"))
		if errors.Is(err, fs.ErrNotExist) {
			return errors.New("no source given, and ab.update.url is unset")
		} else if err != nil {
			return err
		}
		location = strings.TrimSpace(string(b))
	}
	src := newSource(location)
	b, err := readAll(src, "usrhash")
	if err != nil {
		return err
	}
	incoming := strings.TrimSpace(string(b))
	if !rootHash.MatchString(incoming) {
		return fmt.Errorf("%s: usrhash holds no root hash", location)
	}

	p, err := decide(id, entries, usrHash(string(cmdline)), incoming)
	if err != nil {
		return err
	}
	if !p.Install {
		fmt.Println(p.Message)
		return nil
	}
	sums, err := readAll(src, "SHA256SUMS")
	if err != nil {
		return err
	}
	renamed, files, err := rewriteSums(id, p.Number, sums)
	if err != nil {
		return err
	}
	fmt.Printf("installing %s from %s as %s_%d\n", incoming[:12], location, id, p.Number)
	if err := update(templates, &server{src: src, sums: renamed, files: files}, p.Running, "update", strconv.Itoa(p.Number)); err != nil {
		return err
	}
	fmt.Printf("%s_%d boots next; reboot to activate it\n", id, p.Number)
	return nil
}

// update runs systemd-sysupdate against the artifacts srv serves on the loopback interface.
func update(templates string, srv *server, running int, args ...string) error {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer l.Close()
	go http.Serve(l, srv)

	defs, err := os.MkdirTemp("", "ab-update")
	if err != nil {
		return err
	}
	defer os.RemoveAll(defs)
	if err := renderDefinitions(templates, defs, definitions{Source: "http://" + l.Addr().String() + "/", Running: running}); err != nil {
		return err
	}

	cmd := exec.Command(sysupdate, append([]string{"--definitions=" + defs}, args...)...)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}
