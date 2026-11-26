package main

import (
	"reflect"
	"testing"
	"time"
)

func tries(n int) *int { return &n }

func TestImages(t *testing.T) {
	for _, c := range []struct {
		name    string
		entries []entry
		booted  string
		want    []image
	}{
		{
			"after a switch",
			[]entry{
				{Number: 3, UsrHash: "c", Selected: true},
				{Number: 4, UsrHash: "d", Default: true, TriesLeft: tries(3), TriesDone: tries(0)},
			},
			"c",
			[]image{
				{Name: "ab_4", Role: "staged", UsrHash: "d", TriesLeft: tries(3), TriesDone: tries(0), Fallback: "ab_3"},
				{Name: "ab_3", Role: "booted", UsrHash: "c"},
			},
		},
		{
			"a counted boot",
			[]entry{
				{Number: 3, UsrHash: "c"},
				{Number: 4, UsrHash: "d", Default: true, Selected: true, TriesLeft: tries(2), TriesDone: tries(1)},
			},
			"d",
			[]image{
				{Name: "ab_4", Role: "booted", UsrHash: "d", TriesLeft: tries(2), TriesDone: tries(1), Fallback: "ab_3"},
				{Name: "ab_3", Role: "rollback", UsrHash: "c"},
			},
		},
		{
			"a used-up image",
			[]entry{
				{Number: 5, UsrHash: "e", TriesLeft: tries(0), TriesDone: tries(3)},
				{Number: 1, UsrHash: "a", Default: true, Selected: true},
			},
			"a",
			[]image{
				{Name: "ab_1", Role: "booted", UsrHash: "a"},
				{Name: "ab_5", Role: "used-up", UsrHash: "e", TriesLeft: tries(0), TriesDone: tries(3)},
			},
		},
		{
			"booted from a UKI no longer on the ESP",
			[]entry{{Number: 4, UsrHash: "d", Default: true, TriesLeft: tries(3), TriesDone: tries(0)}},
			"f",
			[]image{
				{Name: "ab_4", Role: "staged", UsrHash: "d", TriesLeft: tries(3), TriesDone: tries(0)},
				{Role: "booted", UsrHash: "f"},
			},
		},
	} {
		if got := images("ab", c.entries, c.booted); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s:\n got %+v\nwant %+v", c.name, got, c.want)
		}
	}
}

func TestHuman(t *testing.T) {
	at := func(clock string) *time.Time {
		v, err := time.Parse("2006-01-02 15:04:05", "2026-11-26 "+clock)
		if err != nil {
			t.Fatal(err)
		}
		return &v
	}
	for _, c := range []struct {
		name string
		r    report
		want string
	}{
		{
			"after a switch",
			report{
				State:        "idle",
				BootStatus:   "good",
				Live:         live{Name: "ab_4", UsrHash: "d", Since: at("13:58:00")},
				RebootNeeded: true,
				StoreInRAM:   412 << 20,
				Images: []image{
					{Name: "ab_4", Role: "staged", UsrHash: "d", TriesLeft: tries(3), TriesDone: tries(0), Fallback: "ab_3"},
					{Name: "ab_3", Role: "booted", UsrHash: "c"},
				},
			},
			`State: idle

  Staged image: ab_4
       Usrhash: d
         Tries: 3 left, then ab_3

● Booted image: ab_3
       Usrhash: c
   Boot status: good
          Live: ab_4 since Thu 2026-11-26 13:58:00 UTC
        Kernel: of ab_3 until the next reboot
  Store in RAM: 412 MiB
`,
		},
		{
			"a counted boot that fails its health check",
			report{
				State:        "busy",
				BootStatus:   "indeterminate",
				RebootAt:     at("14:05:12"),
				FailedUnits:  []string{"poisoned.service", "stale.service"},
				Live:         live{Name: "ab_4", UsrHash: "d"},
				StoreOverlay: true,
				Images: []image{
					{Name: "ab_4", Role: "booted", UsrHash: "d", TriesLeft: tries(2), TriesDone: tries(1), Fallback: "ab_3"},
					{Name: "ab_3", Role: "rollback", UsrHash: "c"},
				},
			},
			`State: busy

● Booted image: ab_4
       Usrhash: d
   Boot status: indeterminate
         Tries: 2 left, then ab_3
       Reboots: at Thu 2026-11-26 14:05:12 UTC unless blessed
        Failed: poisoned.service, stale.service
 Store overlay: active, see ab-overlay status

  Rollback image: ab_3
         Usrhash: c
`,
		},
		{
			"a switch waiting for its confirmation, past a used-up image",
			report{
				State:      "waiting",
				Waiting:    &waiting{Since: *at("14:00:12"), Timeout: "30s"},
				BootStatus: "clean",
				Live:       live{UsrHash: "f"},
				Images: []image{
					{Name: "ab_1", Role: "booted", UsrHash: "a"},
					{Name: "ab_5", Role: "used-up", UsrHash: "e", TriesLeft: tries(0), TriesDone: tries(3)},
				},
			},
			`State: waiting for ab-update confirm since Thu 2026-11-26 14:00:12 UTC, for 30s

● Booted image: ab_1
       Usrhash: a
   Boot status: clean
          Live: f

× Used-up image: ab_5
        Usrhash: e
`,
		},
	} {
		if got := c.r.human(); got != c.want {
			t.Errorf("%s:\n got:\n%s\nwant:\n%s", c.name, got, c.want)
		}
	}
}

func TestLockHeld(t *testing.T) {
	locks := []byte(`1: FLOCK  ADVISORY  WRITE 812 00:19:1234 0 EOF
1: -> FLOCK  ADVISORY  WRITE 813 00:19:77 0 EOF
2: POSIX  ADVISORY  WRITE 99 08:02:5 0 EOF
3: FLOCK  ADVISORY  WRITE 4 103:03:5 0 EOF
`)
	for _, c := range []struct {
		dev, ino uint64
		want     bool
	}{
		{0x19, 1234, true},
		// waits for the lock, holds none
		{0x19, 77, false},
		{0x802, 5, false},
		// major 259, minor 3
		{0x10303, 5, true},
		{0x19, 9, false},
	} {
		if got := lockHeld(locks, c.dev, c.ino); got != c.want {
			t.Errorf("lockHeld(%#x, %d) = %v, want %v", c.dev, c.ino, got, c.want)
		}
	}
}

func TestNextElapse(t *testing.T) {
	for _, c := range []struct {
		timers string
		want   *time.Time
	}{
		{`[{"next":1795683600000000,"unit":"ab-rollback.timer"}]`, func() *time.Time { v := time.UnixMicro(1795683600000000); return &v }()},
		{`[{"next":0,"unit":"ab-rollback.timer"}]`, nil},
		{`[{"next":null,"unit":"ab-rollback.timer"}]`, nil},
		{`[]`, nil},
	} {
		got, err := nextElapse([]byte(c.timers))
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.timers, got, c.want)
		}
	}
}
