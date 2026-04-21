# cachyos-recovery

Recovery tooling for CachyOS installs using LUKS + Btrfs + snapper.

> 🇧🇷 [Versão em português](README.pt.md)

## What's inside

- `scripts/list-snapshots.sh` — lists Btrfs snapshots (works on a live USB or the running system). Read-only.
- `scripts/recover.sh` — guided rollback to a snapshot plus a chroot with regeneration/re-signing steps. **Live USB only** (refuses to run on the target system itself).
- `ansible/playbook.yml` — installs both scripts to `/usr/local/bin/` as `cachyos-list-snapshots` and `cachyos-recover`.

## Quick start

```sh
# Install
cd ansible
ansible-playbook -i inventory.yml playbook.yml --ask-become-pass

# Run
sudo cachyos-list-snapshots
```

## End-to-end recovery flow (live USB only)

Only one script is required: `recover.sh`. It lists snapshots for you and then guides the rollback.

```sh
# 1. Boot the CachyOS live USB. Clone or copy this repo onto it.

# 2. Run the guided rollback:
sudo bash scripts/recover.sh
```

The script will print the snapshots table and then prompt:

```
NUM  DATE                 TYPE    CLEANUP   DESCRIPTION
1    2026-04-20 14:30:12  single  number    first root
2    2026-04-20 15:17:42  pre     number    pacman -S docker
3    2026-04-20 15:17:45  post    number    pacman -S docker
...

Snapshot number to restore: 2
Confirm? type the snapshot number again: 2
```

It then performs the rollback, sets up a chroot, and prints a MOTD with the commands to regenerate the initramfs/UKI and re-sign with sbctl. Run them in order, then `exit`.

```sh
# 3. Reboot into the restored system.
reboot
```

### When to use `list-snapshots.sh` instead

`list-snapshots.sh` is an **optional read-only preview** — use it when:

- You just want to inspect snapshots (no rollback intent).
- You're running on the live system (auditing which snapshots exist).
- You want a safer first look: it mounts `subvolid=5` as **read-only** and never opens LUKS read-write.

### What `recover.sh` does internally

1. Detects the LUKS partition and opens it (or reuses an already-open mapper).
2. Refuses to run if the target Btrfs is the same filesystem backing the running system.
3. Mounts `subvolid=5` (RW), lists snapshots, prompts for a number.
4. Double-confirms (you re-type the number).
5. Renames `@ → @.broken.<timestamp>` (preserved, reversible).
6. Creates a new `@` as a writable snapshot of the chosen one.
7. Mounts ESP + auxiliary subvols and enters a chroot with instructions in the MOTD.

Exiting the chroot triggers automatic cleanup (umount + luksClose).

**Undo** — if something goes wrong later, boot the live USB and:

```sh
mount -o subvolid=5 /dev/mapper/<luks> /mnt
btrfs subvolume delete /mnt/@
mv /mnt/@.broken.<timestamp> /mnt/@
```
