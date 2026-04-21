#!/usr/bin/env bash
# Guided CachyOS recovery: rollback to a Btrfs snapshot and regenerate boot.
# Live-USB ONLY. Refuses to run on the target system itself.
#
# Flow:
#   1. Detect LUKS partition, prompt for passphrase (or reuse an open mapper).
#   2. Mount btrfs at subvolid=5 (read-write).
#   3. List snapshots; pick a number.
#   4. Double-confirm.
#   5. Rename the current @ subvol to @.broken.<timestamp> (reversible).
#   6. Create a new @ as a writable snapshot of the chosen one.
#   7. Offer a guided chroot to regenerate the UKI and re-sign with sbctl.

set -euo pipefail

MOUNT_POINT="/mnt/cachyos-recover"
LUKS_MAPPER=""
LUKS_OPENED_BY_US="no"

cleanup() {
    if mountpoint -q "$MOUNT_POINT/boot" 2>/dev/null; then umount "$MOUNT_POINT/boot" || true; fi
    for p in dev/pts dev proc sys/firmware/efi/efivars sys run \
             home log cache srv root var/tmp; do
        mountpoint -q "$MOUNT_POINT/$p" 2>/dev/null && umount "$MOUNT_POINT/$p" 2>/dev/null || true
    done
    mountpoint -q "$MOUNT_POINT" 2>/dev/null && umount "$MOUNT_POINT" 2>/dev/null || true
    [[ -d "$MOUNT_POINT" ]] && rmdir "$MOUNT_POINT" 2>/dev/null || true
    if [[ "$LUKS_OPENED_BY_US" == "yes" ]] && [[ -n "$LUKS_MAPPER" ]]; then
        cryptsetup luksClose "$LUKS_MAPPER" 2>/dev/null || true
    fi
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
step(){ echo; echo "==> $*"; }

require_root() {
    [[ $EUID -eq 0 ]] || die "must run as root (use sudo)."
}

refuse_if_on_target() {
    local running_uuid="$1" target_uuid="$2"
    if [[ "$running_uuid" == "$target_uuid" ]]; then
        die "you are running on the SAME btrfs you're trying to recover.
      Boot from the CachyOS live USB."
    fi
}

find_luks_device() {
    local devs=()
    while IFS= read -r line; do
        devs+=("$line")
    done < <(lsblk -ndo PATH,FSTYPE | awk '$2=="crypto_LUKS" {print $1}')
    case ${#devs[@]} in
        0) die "no crypto_LUKS partition found." ;;
        1) echo "${devs[0]}" ;;
        *)
            echo "Multiple LUKS partitions found:" >&2
            local i=0
            for d in "${devs[@]}"; do echo "  [$i] $d" >&2; ((i++)) || true; done
            read -rp "Index: " idx
            [[ "$idx" =~ ^[0-9]+$ ]] && (( idx < ${#devs[@]} )) || die "invalid index."
            echo "${devs[$idx]}"
            ;;
    esac
}

reuse_or_open_luks() {
    local dev="$1"
    for m in /dev/mapper/*; do
        [[ -b "$m" ]] || continue
        local name backing
        name=$(basename "$m")
        backing=$(cryptsetup status "$name" 2>/dev/null | awk '/device:/ {print $2}') || continue
        if [[ "$backing" == "$dev" ]]; then
            LUKS_MAPPER="$name"
            LUKS_OPENED_BY_US="no"
            ok "LUKS already open at /dev/mapper/$LUKS_MAPPER"
            return
        fi
    done
    LUKS_MAPPER="cachyos-recover-$$"
    cryptsetup luksOpen "$dev" "$LUKS_MAPPER"
    LUKS_OPENED_BY_US="yes"
    ok "LUKS opened at /dev/mapper/$LUKS_MAPPER"
}

mount_btrfs_root_rw() {
    mkdir -p "$MOUNT_POINT"
    mount -o subvolid=5,rw "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT"
    ok "btrfs mounted at $MOUNT_POINT (subvolid=5, rw)"
}

detect_layout() {
    # Sets globals: SNAPSHOTS_DIR (absolute path), SNAPSHOTS_REL (fs-relative)
    for candidate in "@/.snapshots" "@.snapshots"; do
        if [[ -d "$MOUNT_POINT/$candidate" ]]; then
            SNAPSHOTS_DIR="$MOUNT_POINT/$candidate"
            SNAPSHOTS_REL="$candidate"
            return
        fi
    done
    die ".snapshots directory not found."
}

extract_tag() { grep -oP "(?<=<$2>)[^<]+" "$1" 2>/dev/null | head -n1 || true; }

list_snapshots_table() {
    local rows=()
    for info in "$SNAPSHOTS_DIR"/*/info.xml; do
        [[ -f "$info" ]] || continue
        local num date type cleanup desc
        num=$(extract_tag "$info" num)
        date=$(extract_tag "$info" date | sed 's/T/ /')
        type=$(extract_tag "$info" type)
        cleanup=$(extract_tag "$info" cleanup)
        desc=$(extract_tag "$info" description)
        : "${num:=?}" "${date:=?}" "${type:=?}" "${cleanup:=-}" "${desc:=-}"
        rows+=("$(printf '%d\t%s\t%s\t%s\t%s' "$num" "$date" "$type" "$cleanup" "$desc")")
    done
    [[ ${#rows[@]} -gt 0 ]] || die "no snapshots found."
    {
        printf 'NUM\tDATE\tTYPE\tCLEANUP\tDESCRIPTION\n'
        printf '%s\n' "${rows[@]}" | sort -n
    } | column -t -s $'\t'
}

pick_snapshot() {
    local num
    read -rp "Snapshot number to restore: " num
    [[ "$num" =~ ^[0-9]+$ ]] || die "invalid number."
    local snap="$SNAPSHOTS_DIR/$num/snapshot"
    [[ -d "$snap" ]] || die "snapshot $num does not exist under $SNAPSHOTS_DIR"
    echo "$num"
}

confirm_rollback() {
    local num="$1"
    local info="$SNAPSHOTS_DIR/$num/info.xml"
    echo
    echo "You picked snapshot #$num:"
    echo "  date: $(extract_tag "$info" date | sed 's/T/ /')"
    echo "  desc: $(extract_tag "$info" description)"
    echo
    echo "Actions that will be performed:"
    echo "  1. rename $MOUNT_POINT/@  →  $MOUNT_POINT/@.broken.$(date +%Y%m%d-%H%M%S)"
    echo "  2. create new $MOUNT_POINT/@ as a writable snapshot of #$num"
    echo "  3. open a chroot for regenerating the UKI and re-signing"
    echo
    read -rp "Confirm? type the snapshot number again: " confirm
    [[ "$confirm" == "$num" ]] || die "confirmation mismatch. Aborted."
}

do_rollback() {
    local num="$1"
    local ts broken_name
    ts=$(date +%Y%m%d-%H%M%S)
    broken_name="@.broken.$ts"

    step "Rollback"
    mv "$MOUNT_POINT/@" "$MOUNT_POINT/$broken_name"
    ok "@ → $broken_name"

    btrfs subvolume snapshot "$SNAPSHOTS_DIR/$num/snapshot" "$MOUNT_POINT/@" >/dev/null
    ok "new @ created from snapshot #$num"
    echo
    echo "Filesystem rollback done. Old subvol preserved at $broken_name"
    echo "(you can delete it later with: btrfs subvolume delete $MOUNT_POINT/$broken_name)"
}

setup_chroot() {
    step "Preparing chroot at $MOUNT_POINT"
    # Remount using subvol=@ (current root subvol) so paths line up for chroot
    umount "$MOUNT_POINT"
    mount -o subvol=@ "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT"
    ok "mounted subvol=@ at $MOUNT_POINT"

    # Find the ESP from the restored fstab
    local esp_uuid
    esp_uuid=$(awk '$2=="/boot" && $3=="vfat" {for(i=1;i<=NF;i++)if($i~/UUID=/){split($i,a,"=");print a[2];exit}}' "$MOUNT_POINT/etc/fstab")
    local esp_dev
    esp_dev=$(blkid -U "$esp_uuid" 2>/dev/null || true)
    if [[ -n "$esp_dev" ]]; then
        mount "$esp_dev" "$MOUNT_POINT/boot"
        ok "ESP ($esp_dev) mounted at /boot"
    else
        echo "  ⚠ could not auto-detect ESP from fstab; mount it manually inside the chroot."
    fi

    # Auxiliary subvols — nice-to-have for a smoother chroot
    for pair in "home:@home" "var/log:@log" "var/cache:@cache" "var/tmp:@tmp" "srv:@srv" "root:@root"; do
        local mp="${pair%%:*}" subvol="${pair##*:}"
        if [[ -d "$MOUNT_POINT/$mp" ]]; then
            mount -o subvol="$subvol" "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT/$mp" 2>/dev/null && \
                ok "mounted subvol=$subvol at /$mp" || true
        fi
    done

    # Virtual filesystems for chroot
    mount --bind /dev "$MOUNT_POINT/dev"
    mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
    mount -t proc proc "$MOUNT_POINT/proc"
    mount -t sysfs sys "$MOUNT_POINT/sys"
    mount --bind /run "$MOUNT_POINT/run"
    if [[ -d /sys/firmware/efi/efivars ]]; then
        mount --bind /sys/firmware/efi/efivars "$MOUNT_POINT/sys/firmware/efi/efivars" 2>/dev/null || true
    fi
    ok "virtual filesystems mounted"
}

enter_chroot() {
    step "Entering chroot"
    cat <<'EOF'

  ┌─ Inside the chroot, run the steps below in order: ───────────────┐
  │                                                                   │
  │   # 1. Regenerate initramfs (and UKI, if configured)              │
  │   mkinitcpio -P                                                   │
  │                                                                   │
  │   # 2. Re-sign boot chain binaries                                │
  │   sbctl sign-all -g                                               │
  │   sbctl verify                                                    │
  │                                                                   │
  │   # 3. If using systemd-boot, update its binary:                  │
  │   bootctl update                                                  │
  │   sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi             │
  │   sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI                        │
  │                                                                   │
  │   # 4. If using Limine, update its binary:                        │
  │   limine-update                                                   │
  │   sbctl sign -s /boot/EFI/limine/limine_x64.efi                   │
  │   sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI                        │
  │                                                                   │
  │   # 5. Exit — cleanup happens automatically.                      │
  │   exit                                                            │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘

EOF
    chroot "$MOUNT_POINT" /bin/bash || true
}

main() {
    require_root

    step "Detection"
    local luks_dev target_uuid running_uuid
    luks_dev=$(find_luks_device)
    ok "LUKS device: $luks_dev"

    reuse_or_open_luks "$luks_dev"

    target_uuid=$(blkid -o value -s UUID "/dev/mapper/$LUKS_MAPPER" 2>/dev/null || echo "?")
    running_uuid=$(findmnt -no UUID / 2>/dev/null || echo "??")
    refuse_if_on_target "$running_uuid" "$target_uuid"

    mount_btrfs_root_rw
    detect_layout
    ok "layout: $SNAPSHOTS_REL"

    step "Available snapshots"
    list_snapshots_table

    echo
    local num
    num=$(pick_snapshot)
    confirm_rollback "$num"

    do_rollback "$num"
    setup_chroot
    enter_chroot

    step "Done"
    echo "  Reboot to test the restored system."
    echo "  If something breaks: boot back into the live USB, mount subvolid=5,"
    echo "  delete the new @, and rename @.broken.<ts> back to @."
}

main "$@"
