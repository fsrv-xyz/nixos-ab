package main

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

type image struct {
	Name      string `json:"name,omitempty"`
	Role      string `json:"role"`
	UsrHash   string `json:"usrhash"`
	TriesLeft *int   `json:"triesLeft,omitempty"`
	TriesDone *int   `json:"triesDone,omitempty"`
	Fallback  string `json:"fallback,omitempty"`
}

// live is the image the last switch activated, else the booted one.
type live struct {
	Name    string     `json:"name,omitempty"`
	UsrHash string     `json:"usrhash"`
	Since   *time.Time `json:"since,omitempty"`
}

type waiting struct {
	Since   time.Time `json:"since"`
	Timeout string    `json:"timeout"`
}

type report struct {
	State        string     `json:"state"`
	Waiting      *waiting   `json:"waiting,omitempty"`
	BootStatus   string     `json:"bootStatus"`
	RebootAt     *time.Time `json:"rebootAt,omitempty"`
	FailedUnits  []string   `json:"failedUnits"`
	Live         live       `json:"live"`
	RebootNeeded bool       `json:"rebootNeeded"`
	StoreInRAM   int64      `json:"storeInRAM"`
	StoreOverlay bool       `json:"storeOverlay"`
	Images       []image    `json:"images"`
}

var roles = []string{"staged", "booted", "rollback", "used-up"}

// images gives the UKIs of the image by role, and the booted image even when its UKI is gone.
func images(id string, entries []entry, booted string) []image {
	sorted := slices.Clone(entries)
	slices.SortFunc(sorted, func(a, b entry) int { return b.Number - a.Number })
	usedUp := func(e entry) bool { return e.TriesLeft != nil && *e.TriesLeft == 0 }
	var list []image
	for _, e := range sorted {
		img := image{Name: fmt.Sprintf("%s_%d", id, e.Number), Role: "rollback", UsrHash: e.UsrHash, TriesLeft: e.TriesLeft, TriesDone: e.TriesDone}
		switch {
		case e.Selected:
			img.Role = "booted"
		case usedUp(e):
			img.Role = "used-up"
		case e.Default:
			img.Role = "staged"
		}
		if e.TriesLeft != nil && !usedUp(e) {
			// systemd-boot sorts an entry without tries left last, behind the next lower one
			for _, o := range sorted {
				if o.Number != e.Number && !usedUp(o) {
					img.Fallback = fmt.Sprintf("%s_%d", id, o.Number)
					break
				}
			}
		}
		list = append(list, img)
	}
	if !slices.ContainsFunc(list, func(i image) bool { return i.Role == "booted" }) {
		list = append(list, image{Role: "booted", UsrHash: booted})
	}
	slices.SortStableFunc(list, func(a, b image) int { return slices.Index(roles, a.Role) - slices.Index(roles, b.Role) })
	return list
}

var headers = map[string]string{
	"staged":   "  Staged image",
	"booted":   "● Booted image",
	"rollback": "  Rollback image",
	"used-up":  "× Used-up image",
}

func stamp(t time.Time) string { return t.Format("Mon 2006-01-02 15:04:05 MST") }

// human lays the report out as bootc status does: a block per image, its keys aligned to its header.
func (r report) human() string {
	var b strings.Builder
	state := r.State
	if r.Waiting != nil {
		state = fmt.Sprintf("waiting for ab-update confirm since %s, for %s", stamp(r.Waiting.Since), r.Waiting.Timeout)
	}
	fmt.Fprintf(&b, "State: %s\n", state)
	for _, img := range r.Images {
		name := cmp.Or(img.Name, "not on the ESP")
		rows := [][2]string{{"Usrhash", img.UsrHash}}
		booted := img.Role == "booted"
		if booted {
			rows = append(rows, [2]string{"Boot status", r.BootStatus})
		}
		if img.TriesLeft != nil && img.Role != "used-up" {
			tries := fmt.Sprintf("%d left", *img.TriesLeft)
			if img.Fallback != "" {
				tries += ", then " + img.Fallback
			}
			rows = append(rows, [2]string{"Tries", tries})
		}
		if booted {
			if r.RebootAt != nil {
				rows = append(rows, [2]string{"Reboots", "at " + stamp(*r.RebootAt) + " unless blessed"})
			}
			if len(r.FailedUnits) > 0 {
				rows = append(rows, [2]string{"Failed", strings.Join(r.FailedUnits, ", ")})
			}
			if r.Live.UsrHash != img.UsrHash {
				switched := cmp.Or(r.Live.Name, r.Live.UsrHash)
				if r.Live.Since != nil {
					switched += " since " + stamp(*r.Live.Since)
				}
				rows = append(rows, [2]string{"Live", switched})
			}
			if r.RebootNeeded {
				rows = append(rows, [2]string{"Kernel", "of " + name + " until the next reboot"})
			}
			if r.StoreInRAM > 0 {
				rows = append(rows, [2]string{"Store in RAM", fmt.Sprintf("%d MiB", (r.StoreInRAM+1<<20-1)>>20)})
			}
			if r.StoreOverlay {
				rows = append(rows, [2]string{"Store overlay", "active, see ab-overlay status"})
			}
		}
		header := headers[img.Role]
		fmt.Fprintf(&b, "\n%s: %s\n", header, name)
		for _, row := range rows {
			fmt.Fprintf(&b, "%*s: %s\n", utf8.RuneCountInString(header), row[0], row[1])
		}
	}
	return b.String()
}

// lockHeld tells from /proc/locks whether a process holds a flock on the file of this device and inode.
func lockHeld(locks []byte, dev, ino uint64) bool {
	major := (dev>>8)&0xfff | (dev>>32)&^0xfff
	minor := dev&0xff | (dev>>12)&^0xff
	id := fmt.Sprintf("%02x:%02x:%d", major, minor, ino)
	for _, line := range strings.Split(string(locks), "\n") {
		// a process waiting for the lock has "->" in the second field
		if f := strings.Fields(line); len(f) > 5 && f[1] == "FLOCK" && f[5] == id {
			return true
		}
	}
	return false
}

// nextElapse reads when the timer of systemctl list-timers --output=json elapses, nil once it has.
func nextElapse(timers []byte) (*time.Time, error) {
	var list []struct{ Next *int64 }
	if err := json.Unmarshal(timers, &list); err != nil {
		return nil, fmt.Errorf("systemctl list-timers: %w", err)
	}
	if len(list) == 0 || list[0].Next == nil || *list[0].Next == 0 {
		return nil, nil
	}
	t := time.UnixMicro(*list[0].Next)
	return &t, nil
}

// status reports what runs, what booted and what boots next: for people, or with format short or pretty as JSON.
func status(templates, format string) error {
	indent := ""
	switch format {
	case "off", "short":
	case "pretty":
		indent = "  "
	default:
		return fmt.Errorf("-json takes short, pretty or off, not %s", format)
	}
	id, entries, cmdline, err := readEntries()
	if err != nil {
		return err
	}
	booted := usrHash(cmdline)
	r := report{State: "idle", FailedUnits: []string{}, Live: live{UsrHash: booted}, Images: images(id, entries, booted)}

	if info, err := os.Stat(fifo); err == nil && info.Mode().Type() == fs.ModeNamedPipe {
		timeout, err := os.ReadFile(filepath.Join(templates, "rollback-timeout"))
		if err != nil {
			return err
		}
		r.State, r.Waiting = "waiting", &waiting{Since: info.ModTime(), Timeout: strings.TrimSpace(string(timeout))}
	} else if info, err := os.Stat(lockPath); err == nil {
		locks, err := os.ReadFile("/proc/locks")
		if err != nil {
			return err
		}
		if st := info.Sys().(*syscall.Stat_t); lockHeld(locks, st.Dev, st.Ino) {
			r.State = "busy"
		}
	}

	s, err := exec.Command(blessBoot, "status").Output()
	if err != nil {
		return fmt.Errorf("systemd-bless-boot status: %w", err)
	}
	r.BootStatus = strings.TrimSpace(string(s))
	if !blessed(r.BootStatus) {
		timers, err := exec.Command(systemctl, "list-timers", "--all", "--output=json", "ab-rollback.timer").Output()
		if err != nil {
			return fmt.Errorf("systemctl list-timers: %w", err)
		}
		if r.RebootAt, err = nextElapse(timers); err != nil {
			return err
		}
	}
	units, err := exec.Command(systemctl, "list-units", "--state=failed", "--output=json").Output()
	if err != nil {
		return fmt.Errorf("systemctl list-units: %w", err)
	}
	var failed []struct{ Unit string }
	if err := json.Unmarshal(units, &failed); err != nil {
		return fmt.Errorf("systemctl list-units: %w", err)
	}
	for _, u := range failed {
		r.FailedUnits = append(r.FailedUnits, u.Unit)
	}

	if info, err := os.Stat(liveFile); err == nil {
		b, err := os.ReadFile(liveFile)
		if err != nil {
			return err
		}
		since := info.ModTime()
		r.Live.UsrHash, r.Live.Since = strings.TrimSpace(string(b)), &since
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	for _, e := range entries {
		if e.UsrHash == r.Live.UsrHash {
			r.Live.Name = fmt.Sprintf("%s_%d", id, e.Number)
		}
	}
	r.RebootNeeded = rebootNeeded("/run/booted-system", "/run/current-system")
	// a switch may be copying or removing a delta meanwhile
	if deltas, err := names(deltaDir); err == nil {
		r.StoreInRAM, _ = treeSize(deltaDir, deltas)
	}
	mountinfo, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return err
	}
	r.StoreOverlay = writableStore(mountinfo)

	if format == "off" {
		fmt.Print(r.human())
		return nil
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", indent)
	return enc.Encode(r)
}
