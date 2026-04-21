# cachyos-recovery

Ferramentas de recuperação pra instalações CachyOS com LUKS + Btrfs + snapper.

> 🇺🇸 [English version](README.md)

## O que tem

- `scripts/list-snapshots.sh` — lista snapshots Btrfs (funciona em live USB ou no sistema rodando). Somente leitura.
- `scripts/recover.sh` — rollback guiado pra uma snapshot + chroot com passos de regeneração de UKI/re-assinatura. **Só funciona de live USB** (recusa rodar no próprio sistema).
- `ansible/playbook.yml` — instala os dois em `/usr/local/bin/` como `cachyos-list-snapshots` e `cachyos-recover`.

## Uso rápido

```sh
# Instala
cd ansible
ansible-playbook -i inventory.yml playbook.yml --ask-become-pass

# Roda
sudo cachyos-list-snapshots
```

## Fluxo completo de recovery (só via live USB)

```sh
# 1. Boot pelo live USB do CachyOS. Clona ou copia este repo pro live.

# 2. Descobre qual snapshot você quer restaurar:
sudo bash scripts/list-snapshots.sh
```

Saída esperada:

```
LUKS device: /dev/nvme0n1p2
Snapshots at: /mnt/cachyos-snaps-ro/@/.snapshots

NUM  DATE                 TYPE    CLEANUP   DESCRIPTION
1    2026-04-20 14:30:12  single  number    first root
2    2026-04-20 15:17:42  pre     number    pacman -S docker
3    2026-04-20 15:17:45  post    number    pacman -S docker
...
```

Anota o `NUM` da snapshot que você quer (ex: `2`).

```sh
# 3. Roda o rollback guiado:
sudo bash scripts/recover.sh
```

O `recover.sh` vai listar as snapshots de novo e perguntar:

```
Snapshot number to restore: 2         ← digita o NUM do passo 2
Confirm? type the snapshot number again: 2
```

Ele faz o rollback, monta o chroot e mostra uma MOTD com os comandos pra regenerar initramfs/UKI e re-assinar com sbctl. Roda na ordem e depois `exit`.

```sh
# 4. Reboot no sistema restaurado.
reboot
```

### O que o `recover.sh` faz por dentro

1. Detecta a partição LUKS e abre (ou reusa mapper já aberto).
2. Recusa rodar se o btrfs em questão é o mesmo do sistema vivo.
3. Monta `subvolid=5` (RW), lista snapshots, pede o número.
4. Pede confirmação dupla (digitar o número de novo).
5. Renomeia `@ → @.broken.<timestamp>` (preserva, reversível).
6. Cria novo `@` como snapshot writable da escolhida.
7. Monta ESP + subvols auxiliares e abre chroot com instruções na MOTD.

Saída do chroot faz cleanup automático (umount + luksClose).

**Undo**: se algo der errado depois, boot no live USB e:

```sh
mount -o subvolid=5 /dev/mapper/<luks> /mnt
btrfs subvolume delete /mnt/@
mv /mnt/@.broken.<timestamp> /mnt/@
```
