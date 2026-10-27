# shellcheck shell=bash
# ab-overlay [status]: lays a tmpfs over /nix/store, so the running image can be edited until reboot
set -euo pipefail

dir=/run/ab-overlay
fail() {
  echo "ab-overlay: $*" >&2
  exit 1
}
active() { findmnt --noheadings --types overlay /nix/store >/dev/null; }

case ${1-} in
"")
  ! active || fail "already active"
  mkdir -p "$dir"
  mount -t tmpfs -o mode=0700 ab-overlay "$dir"
  mkdir "$dir/lower" "$dir/upper" "$dir/work"
  # the image's store for status; private, or the overlay would propagate onto it
  mount --bind /nix/store "$dir/lower"
  mount --make-private "$dir/lower"
  # the overlay's root takes mode and owner from upper
  chmod --reference=/nix/store "$dir/upper"
  chown --reference=/nix/store "$dir/upper"
  mount -t overlay ab-overlay -o "nosuid,nodev,lowerdir=$dir/lower,upperdir=$dir/upper,workdir=$dir/work" /nix/store
  echo "/nix/store is writable until reboot" | systemd-cat -t ab-overlay -p warning
  echo "ab-overlay: /nix/store is writable until reboot, ab-overlay status shows the changes"
  ;;
status)
  active || fail "not active"
  cd "$dir/upper"
  find . ! -type d -printf '%P\n' | sort | while read -r path; do
    # overlayfs records a deletion as a character device
    if [[ -c $path ]]; then
      echo "deleted /nix/store/$path"
    else
      diff -uN "$dir/lower/$path" "/nix/store/$path" || :
    fi
  done
  ;;
*)
  echo "usage: ab-overlay [status]" >&2
  exit 2
  ;;
esac
