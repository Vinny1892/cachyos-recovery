# cachyos-recovery

Ferramentas de recuperação pra instalações CachyOS com LUKS + Btrfs + snapper.

## O que tem

- `scripts/list-snapshots.sh` — lista snapshots Btrfs (funciona em live USB ou no sistema rodando). Somente leitura.
- `ansible/playbook.yml` — instala o script em `/usr/local/bin/cachyos-list-snapshots`.

## Uso rápido

```sh
# Instala
cd ansible
ansible-playbook -i inventory.yml playbook.yml --ask-become-pass

# Roda
sudo cachyos-list-snapshots
```

## Uso em live USB (sem instalar)

1. Boot pelo live USB do CachyOS.
2. Copia ou baixa o script.
3. `sudo bash list-snapshots.sh`

Saída esperada:

```
LUKS device: /dev/nvme0n1p2
Snapshots em: /mnt/cachyos-snaps-ro/@/.snapshots

NUM  DATE                 TYPE    CLEANUP   DESCRIPTION
1    2026-04-20 14:30:12  single  number    first root
2    2026-04-20 15:17:42  pre     number    pacman -S docker
3    2026-04-20 15:17:45  post    number    pacman -S docker
...
```
