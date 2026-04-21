#!/usr/bin/env bash
# Guia recuperação do CachyOS: rollback pra uma snapshot Btrfs e regenera boot.
# Use SOMENTE a partir de live USB. Recusa rodar se estiver no próprio sistema.
#
# Fluxo:
#   1. Detecta partição LUKS, pede passphrase (ou reusa mapper aberto).
#   2. Monta btrfs em subvolid=5 (read-write).
#   3. Lista snapshots; você escolhe o número.
#   4. Confirma duas vezes.
#   5. Renomeia subvol @ atual pra @.broken.<timestamp> (reversível).
#   6. Cria novo @ como snapshot writable da escolhida.
#   7. Oferece chroot guiado pra regenerar UKI e re-assinar com sbctl.

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

die() { echo "ERRO: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
step(){ echo; echo "==> $*"; }

require_root() {
    [[ $EUID -eq 0 ]] || die "precisa rodar como root (sudo)."
}

refuse_if_on_target() {
    local running_uuid="$1" target_uuid="$2"
    if [[ "$running_uuid" == "$target_uuid" ]]; then
        die "você está rodando no MESMO btrfs que tenta recuperar.
      Use o live USB do CachyOS."
    fi
}

find_luks_device() {
    local devs=()
    while IFS= read -r line; do
        devs+=("$line")
    done < <(lsblk -ndo PATH,FSTYPE | awk '$2=="crypto_LUKS" {print $1}')
    case ${#devs[@]} in
        0) die "nenhuma partição crypto_LUKS encontrada." ;;
        1) echo "${devs[0]}" ;;
        *)
            echo "Múltiplas partições LUKS:" >&2
            local i=0
            for d in "${devs[@]}"; do echo "  [$i] $d" >&2; ((i++)) || true; done
            read -rp "Índice: " idx
            [[ "$idx" =~ ^[0-9]+$ ]] && (( idx < ${#devs[@]} )) || die "índice inválido."
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
            ok "LUKS já aberto em /dev/mapper/$LUKS_MAPPER"
            return
        fi
    done
    LUKS_MAPPER="cachyos-recover-$$"
    cryptsetup luksOpen "$dev" "$LUKS_MAPPER"
    LUKS_OPENED_BY_US="yes"
    ok "LUKS aberto em /dev/mapper/$LUKS_MAPPER"
}

mount_btrfs_root_rw() {
    mkdir -p "$MOUNT_POINT"
    mount -o subvolid=5,rw "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT"
    ok "btrfs montado em $MOUNT_POINT (subvolid=5, rw)"
}

detect_layout() {
    # Retorna via globals: SNAPSHOTS_DIR (fs path), SNAPSHOTS_REL (relativo ao root fs)
    for candidate in "@/.snapshots" "@.snapshots"; do
        if [[ -d "$MOUNT_POINT/$candidate" ]]; then
            SNAPSHOTS_DIR="$MOUNT_POINT/$candidate"
            SNAPSHOTS_REL="$candidate"
            return
        fi
    done
    die "diretório .snapshots não encontrado."
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
    [[ ${#rows[@]} -gt 0 ]] || die "nenhum snapshot encontrado."
    {
        printf 'NUM\tDATE\tTYPE\tCLEANUP\tDESCRIPTION\n'
        printf '%s\n' "${rows[@]}" | sort -n
    } | column -t -s $'\t'
}

pick_snapshot() {
    local num
    read -rp "Número da snapshot pra restaurar: " num
    [[ "$num" =~ ^[0-9]+$ ]] || die "número inválido."
    local snap="$SNAPSHOTS_DIR/$num/snapshot"
    [[ -d "$snap" ]] || die "snapshot $num não existe em $SNAPSHOTS_DIR"
    echo "$num"
}

confirm_rollback() {
    local num="$1"
    local info="$SNAPSHOTS_DIR/$num/info.xml"
    echo
    echo "Você escolheu snapshot #$num:"
    echo "  data: $(extract_tag "$info" date | sed 's/T/ /')"
    echo "  desc: $(extract_tag "$info" description)"
    echo
    echo "Ações que serão executadas:"
    echo "  1. renomear $MOUNT_POINT/@  →  $MOUNT_POINT/@.broken.$(date +%Y%m%d-%H%M%S)"
    echo "  2. criar novo $MOUNT_POINT/@ como snapshot writable de #$num"
    echo "  3. abrir chroot pra regenerar UKI + re-assinar"
    echo
    read -rp "Confirma? digite o número da snapshot novamente: " confirm
    [[ "$confirm" == "$num" ]] || die "confirmação não bate. Abortado."
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
    ok "@ novo criado a partir da snapshot #$num"
    echo
    echo "Rollback no filesystem está feito. Subvol antigo preservado em $broken_name"
    echo "(pode deletar depois com: btrfs subvolume delete $MOUNT_POINT/$broken_name)"
}

setup_chroot() {
    step "Preparando chroot em $MOUNT_POINT"
    # Desmonta subvolid=5 e remonta com @ direto
    umount "$MOUNT_POINT"
    mount -o subvol=@ "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT"
    ok "montado subvol=@ em $MOUNT_POINT"

    # Descobre a partição ESP automaticamente (fstab do sistema restaurado)
    local esp_uuid
    esp_uuid=$(awk '$2=="/boot" && $3=="vfat" {for(i=1;i<=NF;i++)if($i~/UUID=/){split($i,a,"=");print a[2];exit}}' "$MOUNT_POINT/etc/fstab")
    local esp_dev
    esp_dev=$(blkid -U "$esp_uuid" 2>/dev/null || true)
    if [[ -n "$esp_dev" ]]; then
        mount "$esp_dev" "$MOUNT_POINT/boot"
        ok "ESP ($esp_dev) montada em /boot"
    else
        echo "  ⚠ não consegui detectar ESP pelo fstab; monte manualmente dentro do chroot."
    fi

    # Subvols auxiliares (melhor UX no chroot, alguns são opcionais)
    for pair in "home:@home" "var/log:@log" "var/cache:@cache" "var/tmp:@tmp" "srv:@srv" "root:@root"; do
        local mp="${pair%%:*}" subvol="${pair##*:}"
        if [[ -d "$MOUNT_POINT/$mp" ]]; then
            mount -o subvol="$subvol" "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT/$mp" 2>/dev/null && \
                ok "mounted subvol=$subvol em /$mp" || true
        fi
    done

    # Virtual fs pro chroot
    mount --bind /dev "$MOUNT_POINT/dev"
    mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
    mount -t proc proc "$MOUNT_POINT/proc"
    mount -t sysfs sys "$MOUNT_POINT/sys"
    mount --bind /run "$MOUNT_POINT/run"
    if [[ -d /sys/firmware/efi/efivars ]]; then
        mount --bind /sys/firmware/efi/efivars "$MOUNT_POINT/sys/firmware/efi/efivars" 2>/dev/null || true
    fi
    ok "virtual fs mounted"
}

enter_chroot() {
    step "Entrando no chroot"
    cat <<'EOF'

  ┌─ Dentro do chroot, rode os passos abaixo na ordem: ──────────────┐
  │                                                                   │
  │   # 1. Regenerar initramfs e (se configurado) UKI                 │
  │   mkinitcpio -P                                                   │
  │                                                                   │
  │   # 2. Re-assinar binários da cadeia de boot                      │
  │   sbctl sign-all -g                                               │
  │   sbctl verify                                                    │
  │                                                                   │
  │   # 3. Se usar systemd-boot, atualizar binário:                   │
  │   bootctl update                                                  │
  │   sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi             │
  │   sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI                        │
  │                                                                   │
  │   # 4. Se usar Limine, atualizar binário:                         │
  │   limine-update                                                   │
  │   sbctl sign -s /boot/EFI/limine/limine_x64.efi                   │
  │   sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI                        │
  │                                                                   │
  │   # 5. Sair — a limpeza é automática.                             │
  │   exit                                                            │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘

EOF
    chroot "$MOUNT_POINT" /bin/bash || true
}

main() {
    require_root

    step "Detecção"
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

    step "Snapshots disponíveis"
    list_snapshots_table

    echo
    local num
    num=$(pick_snapshot)
    confirm_rollback "$num"

    do_rollback "$num"
    setup_chroot
    enter_chroot

    step "Done"
    echo "  Reinicie pra testar o sistema restaurado."
    echo "  Se der problema: volte ao live USB, monte subvolid=5,"
    echo "  apague o @ novo e renomeie @.broken.<ts> de volta pra @."
}

main "$@"
