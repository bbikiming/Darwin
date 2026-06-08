#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  tools/switch-pilot/extract-switchroot-to-sd.sh --sd-root /Volumes/SWITCHSD

Options:
  --sd-root PATH       Mounted SD FAT32 root after Hekate partitioning.
  --archive PATH       Switchroot .7z archive. Defaults to the local cached Noble image.
  --sha256 PATH        Checksum file. Defaults to ARCHIVE.sha256.
  --skip-checksum      Skip archive SHA-256 verification.
  --force              Continue even if switchroot/ or L4T ini already exists.
  -h, --help           Show this help.

Run this after Hekate creates the Linux partition. Extracting before Hekate
partitioning can waste time because partitioning may rewrite the SD.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

archive="$repo_root/dist/switchroot-cache/theofficialgman-ubuntu-unity-noble-5.1.2-2025-08-16.7z"
sha256_file=""
sd_root=""
skip_checksum=0
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sd-root)
            sd_root="${2:-}"
            shift 2
            ;;
        --archive)
            archive="${2:-}"
            shift 2
            ;;
        --sha256)
            sha256_file="${2:-}"
            shift 2
            ;;
        --skip-checksum)
            skip_checksum=1
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[BAD] Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$sd_root" ]]; then
    echo "[BAD] --sd-root is required." >&2
    usage >&2
    exit 2
fi

if [[ -z "$sha256_file" ]]; then
    sha256_file="$archive.sha256"
fi

if [[ ! -f "$archive" ]]; then
    echo "[BAD] Switchroot archive not found: $archive" >&2
    exit 1
fi

if [[ ! -d "$sd_root" ]]; then
    echo "[BAD] SD root not mounted: $sd_root" >&2
    exit 1
fi

if [[ ! -w "$sd_root" ]]; then
    echo "[BAD] SD root is not writable: $sd_root" >&2
    exit 1
fi

if ! command -v bsdtar >/dev/null 2>&1; then
    echo "[BAD] bsdtar is required on macOS to extract the 7z archive." >&2
    exit 1
fi

if [[ "$skip_checksum" -eq 0 ]]; then
    if [[ ! -f "$sha256_file" ]]; then
        echo "[BAD] SHA-256 file not found: $sha256_file" >&2
        exit 1
    fi
    echo "[INFO] Verifying Switchroot archive checksum..."
    (
        cd "$(dirname "$archive")"
        shasum -a 256 -c "$(basename "$sha256_file")"
    )
fi

if [[ "$force" -eq 0 ]]; then
    if [[ -d "$sd_root/switchroot" || -f "$sd_root/bootloader/ini/L4T-noble.ini" ]]; then
        echo "[BAD] Switchroot files already appear to exist on the SD." >&2
        echo "      Use --force only if you intentionally want to overwrite or merge files." >&2
        exit 1
    fi
fi

echo "[INFO] Listing archive root layout..."
bsdtar -tf "$archive" | sed -n '1,20p'

echo "[INFO] Extracting Switchroot archive to SD root: $sd_root"
bsdtar -xf "$archive" -C "$sd_root"

echo "[INFO] Running SD layout check..."
"$script_dir/check-switchroot-sd.sh" --stage before-flash --require-darwin-kit "$sd_root"

echo "[INFO] Syncing filesystem buffers..."
sync

cat <<EOF
[OK] Switchroot files are staged on the SD.

Next:
1. Eject or unmount $sd_root safely.
2. Return to Hekate.
3. Run Tools -> Partition SD Card -> Flash Linux.
4. Boot L4T Ubuntu Noble from More Configs.
EOF
