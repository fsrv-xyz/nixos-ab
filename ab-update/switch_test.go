package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestPartUUIDs(t *testing.T) {
	data, verity := partUUIDs("0123456789abcdef0123456789abcdef" + "fedcba9876543210fedcba9876543210")
	if data != "01234567-89ab-cdef-0123-456789abcdef" || verity != "fedcba98-7654-3210-fedc-ba9876543210" {
		t.Fatalf("got %q, %q", data, verity)
	}
}

func TestMissing(t *testing.T) {
	got := missing([]string{"a", "b", "c"}, []string{"b"})
	if want := []string{"a", "c"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestTreeSize(t *testing.T) {
	dir := t.TempDir()
	for name, size := range map[string]int{"p/x": 1, "p/d/y": 4097, "q/z": 1} {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got, err := treeSize(dir, []string{"p"})
	if err != nil || got != 4096+8192 {
		t.Fatalf("got %d, %v", got, err)
	}
}

func TestMemAvailable(t *testing.T) {
	got, err := memAvailable([]byte("MemTotal: 9 kB\nMemAvailable:    2048 kB\n"))
	if err != nil || got != 2097152 {
		t.Fatalf("got %d, %v", got, err)
	}
	if _, err := memAvailable([]byte("MemTotal: 9 kB\n")); err == nil {
		t.Fatal("no MemAvailable: want an error")
	}
}

func TestLowerDirs(t *testing.T) {
	want := "/run/ab-update/store/10:/run/ab-update/store/7:/run/ab-update/store/3:/usr/nix/store"
	if got := lowerDirs([]int{3, 10, 7}); got != want {
		t.Fatalf("got %q", got)
	}
}

func TestWritableStore(t *testing.T) {
	base := "30 1 0:27 /nix/store /nix/store ro,relatime shared:5 - erofs /dev/mapper/usr ro\n"
	live := "95 30 0:50 / /nix/store ro,nosuid,nodev shared:60 - overlay ab-update ro,lowerdir=/run/ab-update/store/2:/usr/nix/store\n"
	edit := "99 95 0:55 / /nix/store rw,nosuid,nodev shared:70 - overlay ab-overlay rw,lowerdir=/run/ab-overlay/lower,upperdir=/run/ab-overlay/upper,workdir=/run/ab-overlay/work\n"
	if writableStore([]byte(base + live)) {
		t.Fatal("a switched store is not writable")
	}
	if !writableStore([]byte(base + live + edit)) {
		t.Fatal("ab-overlay makes the store writable")
	}
}

func TestRebootNeeded(t *testing.T) {
	system := func(initrd, params string) string {
		dir := t.TempDir()
		for name, target := range map[string]string{"kernel": "/k", "initrd": initrd, "kernel-modules": "/m"} {
			if err := os.Symlink(target, filepath.Join(dir, name)); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(dir, "kernel-params"), []byte(params), 0o644); err != nil {
			t.Fatal(err)
		}
		return dir
	}
	booted := system("/i", "panic=10")
	if rebootNeeded(booted, system("/i", "panic=10")) {
		t.Fatal("identical systems need no reboot")
	}
	if !rebootNeeded(booted, system("/i", "panic=10 quiet")) {
		t.Fatal("other kernel parameters need a reboot")
	}
	if !rebootNeeded(booted, system("/other", "panic=10")) {
		t.Fatal("another initrd needs a reboot")
	}
}

func TestBlessed(t *testing.T) {
	for status, want := range map[string]bool{"good\n": true, "clean\n": true, "indeterminate\n": false, "dirty\n": false, "bad\n": false} {
		if blessed(status) != want {
			t.Errorf("blessed(%q) = %v", status, !want)
		}
	}
}
