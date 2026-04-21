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

Só um script é necessário: `recover.sh`. Ele lista as snapshots pra você e depois guia o rollback.

```sh
# 1. Boot pelo live USB do CachyOS. Clona ou copia este repo pro live.

# 2. Roda o rollback guiado:
sudo bash scripts/recover.sh
```

O script imprime a tabela de snapshots e pergunta:

```
NUM  DATE                 TYPE    CLEANUP   DESCRIPTION
1    2026-04-20 14:30:12  single  number    first root
2    2026-04-20 15:17:42  pre     number    pacman -S docker
3    2026-04-20 15:17:45  post    number    pacman -S docker
...

Snapshot number to restore: 2
Confirm? type the snapshot number again: 2
```

Depois faz o rollback, monta o chroot e mostra uma MOTD com os comandos pra regenerar initramfs/UKI e re-assinar com sbctl. Roda na ordem e depois `exit`.

```sh
# 3. Reboot no sistema restaurado.
reboot
```

### Quando usar o `list-snapshots.sh`

O `list-snapshots.sh` é um **preview read-only opcional** — use quando:

- Só quer inspecionar as snapshots (sem intenção de rollback).
- Está rodando no sistema vivo (auditoria de snapshots existentes).
- Quer um primeiro olhar mais seguro: ele monta `subvolid=5` como **read-only** e nunca abre o LUKS em modo escrita.

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
