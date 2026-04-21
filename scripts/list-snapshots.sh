#!/usr/bin/env bash
# Lista snapshots Btrfs de uma instalação CachyOS com LUKS.
# Funciona tanto em live USB quanto no sistema rodando.
# Leitura apenas — não modifica nada.

set -euo pipefail

MOUNT_POINT="/mnt/cachyos-snaps-ro"
LUKS_MAPPER=""
LUKS_OPENED_BY_US="no"

cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    [[ -d "$MOUNT_POINT" ]] && rmdir "$MOUNT_POINT" 2>/dev/null || true
    if [[ "$LUKS_OPENED_BY_US" == "yes" ]] && [[ -n "$LUKS_MAPPER" ]]; then
        cryptsetup luksClose "$LUKS_MAPPER" 2>/dev/null || true
    fi
}
trap cleanup EXIT

die() { echo "ERRO: $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "precisa rodar como root (sudo)."
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
            for d in "${devs[@]}"; do
                echo "  [$i] $d" >&2
                ((i++)) || true
            done
            read -rp "Índice: " idx
            [[ "$idx" =~ ^[0-9]+$ ]] && (( idx < ${#devs[@]} )) || die "índice inválido."
            echo "${devs[$idx]}"
            ;;
    esac
}

reuse_or_open_luks() {
    local dev="$1"
    # Se já está aberto por outro mapper, reusa
    for m in /dev/mapper/*; do
        [[ -b "$m" ]] || continue
        local name backing
        name=$(basename "$m")
        backing=$(cryptsetup status "$name" 2>/dev/null | awk '/device:/ {print $2}') || continue
        if [[ "$backing" == "$dev" ]]; then
            LUKS_MAPPER="$name"
            LUKS_OPENED_BY_US="no"
            echo "LUKS já aberto como /dev/mapper/$LUKS_MAPPER" >&2
            return
        fi
    done
    LUKS_MAPPER="cachyos-snaps-$$"
    cryptsetup luksOpen "$dev" "$LUKS_MAPPER"
    LUKS_OPENED_BY_US="yes"
}

mount_btrfs_ro() {
    mkdir -p "$MOUNT_POINT"
    mount -o ro,subvolid=5 "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT"
}

find_snapshots_dir() {
    for candidate in "@/.snapshots" "@.snapshots" ".snapshots"; do
        if [[ -d "$MOUNT_POINT/$candidate" ]]; then
            echo "$MOUNT_POINT/$candidate"
            return
        fi
    done
    die "diretório .snapshots não encontrado na raiz do Btrfs."
}

extract_tag() {
    # extract_tag <xml_file> <tag_name>
    local file="$1" tag="$2"
    grep -oP "(?<=<${tag}>)[^<]+" "$file" 2>/dev/null | head -n1 || true
}

list_snapshots() {
    local dir="$1"
    local rows=()
    for info in "$dir"/*/info.xml; do
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

    if [[ ${#rows[@]} -eq 0 ]]; then
        echo "Nenhum snapshot encontrado em $dir"
        return
    fi

    {
        printf 'NUM\tDATE\tTYPE\tCLEANUP\tDESCRIPTION\n'
        printf '%s\n' "${rows[@]}" | sort -n
    } | column -t -s $'\t'
}

main() {
    require_root
    local luks_dev snap_dir
    luks_dev=$(find_luks_device)
    echo "LUKS device: $luks_dev"
    reuse_or_open_luks "$luks_dev"
    mount_btrfs_ro
    snap_dir=$(find_snapshots_dir)
    echo "Snapshots em: $snap_dir"
    echo
    list_snapshots "$snap_dir"
}

main "$@"
