package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"log/syslog"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
)

const (
	store     = "/nix/store"
	baseStore = "/usr/nix/store"
	runDir    = "/run/ab-update"
	slotDir   = runDir + "/slot"
	deltaDir  = runDir + "/store"
	liveFile  = runDir + "/live"
)

// partUUIDs gives the UUIDs of an image's store and verity partitions: the halves of its root hash.
func partUUIDs(hash string) (data, verity string) {
	uuid := func(h string) string {
		return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
	}
	return uuid(hash[:32]), uuid(hash[32:])
}

func missing(want, have []string) []string {
	var out []string
	for _, name := range want {
		if !slices.Contains(have, name) {
			out = append(out, name)
		}
	}
	return out
}

// treeSize is what the named trees take in a tmpfs, which stores files in pages.
func treeSize(root string, names []string) (int64, error) {
	const page = 4096
	var size int64
	for _, name := range names {
		err := filepath.WalkDir(filepath.Join(root, name), func(_ string, d fs.DirEntry, err error) error {
			if err != nil || !d.Type().IsRegular() {
				return err
			}
			info, err := d.Info()
			if err != nil {
				return err
			}
			size += (info.Size() + page - 1) / page * page
			return nil
		})
		if err != nil {
			return 0, err
		}
	}
	return size, nil
}

func memAvailable(meminfo []byte) (int64, error) {
	s := bufio.NewScanner(bytes.NewReader(meminfo))
	for s.Scan() {
		if f := strings.Fields(s.Text()); len(f) >= 2 && f[0] == "MemAvailable:" {
			kb, err := strconv.ParseInt(f[1], 10, 64)
			return kb * 1024, err
		}
	}
	return 0, errors.New("meminfo has no MemAvailable")
}

// lowerDirs lists the deltas, newest first, over the store of the booted image.
func lowerDirs(numbers []int) string {
	sorted := slices.Sorted(slices.Values(numbers))
	slices.Reverse(sorted)
	var dirs []string
	for _, n := range sorted {
		dirs = append(dirs, filepath.Join(deltaDir, strconv.Itoa(n)))
	}
	return strings.Join(append(dirs, baseStore), ":")
}

// writableStore reports an overlay with an upper directory on the store, as ab-overlay mounts it.
func writableStore(mountinfo []byte) bool {
	s := bufio.NewScanner(bytes.NewReader(mountinfo))
	for s.Scan() {
		mount, super, ok := strings.Cut(s.Text(), " - ")
		if f := strings.Fields(mount); !ok || len(f) < 5 || f[4] != store {
			continue
		}
		if strings.HasPrefix(super, "overlay ") && strings.Contains(super, "upperdir=") {
			return true
		}
	}
	return false
}

// rebootNeeded reports whether next brings what a switch cannot activate.
func rebootNeeded(booted, next string) bool {
	for _, name := range []string{"kernel", "initrd", "kernel-modules"} {
		a, _ := os.Readlink(filepath.Join(booted, name))
		b, _ := os.Readlink(filepath.Join(next, name))
		if a != b {
			return true
		}
	}
	a, _ := os.ReadFile(filepath.Join(booted, "kernel-params"))
	b, _ := os.ReadFile(filepath.Join(next, "kernel-params"))
	return !bytes.Equal(a, b)
}

func blessed(status string) bool {
	s := strings.TrimSpace(status)
	return s == "good" || s == "clean"
}

const (
	mapping    = "ab-update"
	switchUnit = "ab-update-switch"
	inUnit     = "AB_UPDATE_SWITCH"
)

// output never fails: stderr is the caller's pipe, which breaks when the switch cuts their session,
// and switch-to-configuration panics on a write that fails.
type output struct{ journal io.Writer }

func (o output) Write(p []byte) (int, error) {
	os.Stderr.Write(p)
	if o.journal != nil {
		o.journal.Write(p)
	}
	return len(p), nil
}

var out output

func command(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout, cmd.Stderr = out, out
	return cmd.Run()
}

// switchSystem makes the running system the image that boots next.
func switchSystem(templates, id string, entries []entry) error {
	if os.Getenv(inUnit) == "" {
		return inTransientUnit(templates)
	}
	signal.Ignore(syscall.SIGPIPE)
	if journal, err := syslog.New(syslog.LOG_NOTICE, "ab-update"); err == nil {
		out.journal = journal
	}
	log.SetOutput(out)

	var target entry
	for _, e := range entries {
		if e.Default {
			target = e
		}
	}
	if target.Init == "" {
		return errors.New("no UKI of this image boots next")
	}
	name := fmt.Sprintf("%s_%d", id, target.Number)
	toplevel := filepath.Dir(target.Init)
	before, err := os.Readlink("/run/current-system")
	if err != nil {
		return err
	}
	if before == toplevel {
		log.Printf("%s is active already", name)
		return nil
	}

	status, err := exec.Command(blessBoot, "status").Output()
	if err != nil {
		return fmt.Errorf("systemd-bless-boot status: %w", err)
	}
	if !blessed(string(status)) {
		return errors.New("this boot is not blessed yet")
	}
	mountinfo, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return err
	}
	if writableStore(mountinfo) {
		return errors.New("ab-overlay is active: its edits would be hidden, end it first")
	}
	b, err := os.ReadFile(filepath.Join(templates, "rollback-timeout"))
	if err != nil {
		return err
	}
	timeout := strings.TrimSpace(string(b))
	if err := healthy(timeout); err != nil {
		return fmt.Errorf("the running system fails its health check, not switching: %w", err)
	}

	if !target.Selected {
		if err := stage(id, target); err != nil {
			return err
		}
	}
	// check first: a missing or unwilling switch-to-configuration is no failure of the image
	activate := filepath.Join(toplevel, "bin/switch-to-configuration")
	if err := command(activate, "check"); err != nil {
		return fmt.Errorf("%s check: %w", activate, err)
	}
	err = command(activate, "test")
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 100 {
		return fmt.Errorf("%s takes a reboot to activate", name)
	}
	if err == nil {
		err = healthy(timeout)
	}
	if err != nil {
		return undo(id, entries, target, before, timeout, err)
	}

	if err := os.WriteFile(liveFile, []byte(target.UsrHash+"\n"), 0o644); err != nil {
		return err
	}
	log.Printf("%s is active", name)
	if rebootNeeded("/run/booted-system", toplevel) {
		log.Print("kernel, initrd or kernel command line changed: they take effect at the next reboot")
	}
	return nil
}

// undo returns to the system that ran before a failed switch, and reboots if that fails too.
func undo(id string, entries []entry, target entry, before, timeout string, cause error) error {
	name := fmt.Sprintf("%s_%d", id, target.Number)
	log.Printf("switch to %s failed: %v; returning to %s", name, cause, before)
	result := name + " failed"
	// the booted image stays bootable: it is what a reboot falls back to
	if !target.Selected {
		if err := os.Rename(target.Path, usedUp(target.Path)); err != nil {
			log.Print(err)
		} else {
			result += " and is used up"
		}
	}
	err := command(filepath.Join(before, "bin/switch-to-configuration"), "test")
	if err == nil {
		err = healthy(timeout)
	}
	if err != nil {
		log.Printf("returning to %s failed: %v; rebooting", before, err)
		if err := command(systemctl, "reboot"); err != nil {
			return err
		}
		return errors.New(result)
	}
	result += ", " + before + " is active again"
	for _, e := range entries {
		if e.Selected && filepath.Dir(e.Init) != before {
			result += fmt.Sprintf("; it is no longer installed: a reboot starts %s_%d, roll it out again to keep it", id, e.Number)
		}
	}
	return errors.New(result)
}

// inTransientUnit runs the switch outside the caller's session, which the switch may end.
func inTransientUnit(templates string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(systemdRun, "--unit="+switchUnit, "--wait", "--pipe", "--collect", "--quiet",
		"--setenv="+inUnit+"=1", self, "-definitions", templates, "switch")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err = cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		os.Exit(exit.ExitCode())
	}
	return err
}

// healthy runs what blesses a boot: the oneshot services boot-complete.target requires
// start anew, its other requirements are active.
func healthy(timeout string) error {
	requires, err := exec.Command(systemctl, "show", "--property=Requires", "--value", "boot-complete.target").Output()
	if err != nil {
		return fmt.Errorf("systemctl show boot-complete.target: %w", err)
	}
	var oneshots, others []string
	for _, unit := range strings.Fields(string(requires)) {
		// restarting sysinit.target would restart every service
		if strings.HasSuffix(unit, ".target") {
			continue
		}
		kind, err := exec.Command(systemctl, "show", "--property=Type", "--value", unit).Output()
		if err != nil {
			return fmt.Errorf("systemctl show %s: %w", unit, err)
		}
		if strings.TrimSpace(string(kind)) == "oneshot" {
			oneshots = append(oneshots, unit)
		} else {
			others = append(others, unit)
		}
	}
	if len(oneshots) > 0 {
		restart := append([]string{"--wait", "--pipe", "--collect", "--quiet", "--property=RuntimeMaxSec=" + timeout, systemctl, "restart"}, oneshots...)
		if err := command(systemdRun, restart...); err != nil {
			// a probe must not leave the system degraded
			exec.Command(systemctl, append([]string{"reset-failed"}, oneshots...)...).Run()
			return fmt.Errorf("%s: %w", strings.Join(oneshots, " "), err)
		}
	}
	for _, unit := range others {
		if err := command(systemctl, "is-active", "--quiet", unit); err != nil {
			return fmt.Errorf("%s is not active", unit)
		}
	}
	return nil
}

// stage copies the store paths of an installed image that the running system lacks into
// memory and adds them to the store.
func stage(id string, e entry) error {
	if !rootHash.MatchString(e.UsrHash) {
		return fmt.Errorf("%s_%d has no root hash on its command line", id, e.Number)
	}
	// what a killed run left
	syscall.Unmount(slotDir, 0)
	exec.Command(veritysetup, "detach", mapping).Run()

	// udev's partition UUIDs are from before sysupdate wrote the slot
	if err := command(udevadm, "trigger", "--settle", "--subsystem-match=block", "--action=change"); err != nil {
		return fmt.Errorf("udevadm trigger: %w", err)
	}
	data, verity := partUUIDs(e.UsrHash)
	if err := command(veritysetup, "attach", mapping, "/dev/disk/by-partuuid/"+data, "/dev/disk/by-partuuid/"+verity, e.UsrHash); err != nil {
		return fmt.Errorf("systemd-veritysetup attach: %w", err)
	}
	defer exec.Command(veritysetup, "detach", mapping).Run()
	if err := os.MkdirAll(slotDir, 0o700); err != nil {
		return err
	}
	if err := syscall.Mount("/dev/mapper/"+mapping, slotDir, "erofs", syscall.MS_RDONLY, ""); err != nil {
		return fmt.Errorf("mount %s_%d: %w", id, e.Number, err)
	}
	defer syscall.Unmount(slotDir, 0)

	slotStore := filepath.Join(slotDir, store)
	next, err := names(slotStore)
	if err != nil {
		return err
	}
	have, err := names(store)
	if err != nil {
		return err
	}
	paths := missing(next, have)
	if len(paths) == 0 {
		return nil
	}
	size, err := treeSize(slotStore, paths)
	if err != nil {
		return err
	}
	meminfo, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return err
	}
	available, err := memAvailable(meminfo)
	if err != nil {
		return err
	}
	if size > available/2 {
		return fmt.Errorf("the delta of %d MiB exceeds half of the available memory (%d MiB): reboot to activate %s_%d",
			size>>20, available>>20, id, e.Number)
	}

	if err := os.Mkdir(deltaDir, 0o755); err == nil {
		if err := syscall.Mount("ab-update", deltaDir, "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=0755"); err != nil {
			os.Remove(deltaDir)
			return fmt.Errorf("tmpfs on %s: %w", deltaDir, err)
		}
	} else if !errors.Is(err, fs.ErrExist) {
		return err
	}
	// copied under another name: only complete deltas join the store
	dir := filepath.Join(deltaDir, strconv.Itoa(e.Number))
	partial := dir + ".partial"
	if err := os.RemoveAll(partial); err != nil {
		return err
	}
	if err := os.Mkdir(partial, 0o755); err != nil {
		return err
	}
	// the overlay's root takes mode and owner from its topmost directory
	info, err := os.Stat(store)
	if err != nil {
		return err
	}
	owner := info.Sys().(*syscall.Stat_t)
	if err := errors.Join(os.Chown(partial, int(owner.Uid), int(owner.Gid)), os.Chmod(partial, info.Mode())); err != nil {
		return err
	}
	args := []string{"-a", "--target-directory=" + partial}
	for _, p := range paths {
		args = append(args, filepath.Join(slotStore, p))
	}
	if err := command(cp, args...); err != nil {
		os.RemoveAll(partial)
		return fmt.Errorf("copying the delta: %w", err)
	}
	if err := os.Rename(partial, dir); err != nil {
		return err
	}

	deltas, err := names(deltaDir)
	if err != nil {
		return err
	}
	var numbers []int
	for _, d := range deltas {
		if n, err := strconv.Atoi(d); err == nil {
			numbers = append(numbers, n)
		}
	}
	// built from the image's store each time: overlayfs nests two deep at most
	if err := syscall.Mount("ab-update", store, "overlay", syscall.MS_RDONLY|syscall.MS_NOSUID|syscall.MS_NODEV, "lowerdir="+lowerDirs(numbers)); err != nil {
		os.RemoveAll(dir)
		return fmt.Errorf("overlay on %s: %w", store, err)
	}
	return nil
}

func names(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var list []string
	for _, e := range entries {
		list = append(list, e.Name())
	}
	return list, nil
}
