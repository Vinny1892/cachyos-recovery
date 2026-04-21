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

## Usage from a live USB (no install)

1. Boot the CachyOS live USB.
2. Copy or download the script.
3. `sudo bash list-snapshots.sh`

Expected output:

```
LUKS device: /dev/nvme0n1p2
Snapshots at: /mnt/cachyos-snaps-ro/@/.snapshots

NUM  DATE                 TYPE    CLEANUP   DESCRIPTION
1    2026-04-20 14:30:12  single  number    first root
2    2026-04-20 15:17:42  pre     number    pacman -S docker
3    2026-04-20 15:17:45  post    number    pacman -S docker
...
```

## Recovery (live USB only)

```sh
# On the live USB, with this repo available:
sudo bash scripts/recover.sh
```

The script:

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
