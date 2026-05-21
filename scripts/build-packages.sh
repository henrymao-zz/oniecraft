#!/bin/bash
set -euo pipefail

ROOTFS=""
DEBS_DIR=""
SOURCE_DIR=""
INCLUDE_DEBS=""
INCLUDE_SOURCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --debs-dir) DEBS_DIR="$2"; shift 2 ;;
        --source-dir) SOURCE_DIR="$2"; shift 2 ;;
        --include-debs) INCLUDE_DEBS="$2"; shift 2 ;;
        --include-source) INCLUDE_SOURCE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "${ROOTFS:-}" ]]; then
    echo "ERROR: --rootfs is required"
    exit 1
fi

ROOTFS="$(readlink -f "$ROOTFS")"
: "${DEBS_DIR:=packages/debs}"
: "${SOURCE_DIR:=packages/source}"

install_deb() {
    local deb="$1"
    echo "  Installing: $(basename "$deb")"
    if ! sudo dpkg --root="$ROOTFS" --install "$deb"; then
        sudo chroot "$ROOTFS" apt-get install -f -y || true
        sudo dpkg --root="$ROOTFS" --install "$deb"
    fi
}

build_and_install_source() {
    local src_dir="$1"
    src_dir="$(readlink -f "$src_dir")"

    if [[ ! -d "$src_dir" ]]; then
        echo "  WARNING: Source directory not found: $src_dir"
        return 1
    fi

    echo "  Building source package: $(basename "$src_dir")"

    if [[ -f "$src_dir/Makefile" ]] || [[ -f "$src_dir/makefile" ]]; then
        make -C "$src_dir" -j"$(nproc)"
        if [[ -f "$src_dir/install.sh" ]]; then
            sudo bash "$src_dir/install.sh" "$ROOTFS"
        else
            sudo make -C "$src_dir" DESTDIR="$ROOTFS" install
        fi
    elif [[ -f "$src_dir/CMakeLists.txt" ]]; then
        local build_dir="$src_dir/build"
        mkdir -p "$build_dir"
        cmake -S "$src_dir" -B "$build_dir" -DCMAKE_INSTALL_PREFIX=/usr
        cmake --build "$build_dir" -j"$(nproc)"
        sudo cmake --install "$build_dir" --prefix "$ROOTFS/usr"
    elif [[ -f "$src_dir/setup.py" ]] || [[ -f "$src_dir/pyproject.toml" ]]; then
        if ! sudo chroot "$ROOTFS" pip install "/host$(basename "$src_dir")" 2>/dev/null; then
            sudo rsync -a "$src_dir/" "$ROOTFS/host/$(basename "$src_dir")/"
            sudo chroot "$ROOTFS" pip install "/host/$(basename "$src_dir")"
            sudo rm -rf "$ROOTFS/host/$(basename "$src_dir")"
        fi
    elif [[ -f "$src_dir/install.sh" ]]; then
        sudo bash "$src_dir/install.sh" "$ROOTFS"
    else
        echo "  WARNING: Unknown build system in $src_dir, trying make install"
        if ! make -C "$src_dir" -j"$(nproc)" 2>/dev/null; then
            echo "  ERROR: Could not build $src_dir"
            return 1
        fi
        if ! sudo make -C "$src_dir" DESTDIR="$ROOTFS" install 2>/dev/null; then
            echo "  ERROR: Could not install $src_dir"
            return 1
        fi
    fi
}

echo "Installing packages..."

if [[ -d "$DEBS_DIR" ]]; then
    for deb in "$DEBS_DIR"/*.deb; do
        [[ -f "$deb" ]] || continue
        install_deb "$deb"
    done
fi

if [[ -n "${INCLUDE_DEBS:-}" ]]; then
    for deb in $INCLUDE_DEBS; do
        if [[ -f "$deb" ]]; then
            install_deb "$deb"
        else
            echo "  WARNING: .deb file not found: $deb"
        fi
    done
fi

sudo chroot "$ROOTFS" apt-get install -f -y 2>/dev/null || true

if [[ -n "${INCLUDE_SOURCE:-}" ]]; then
    for src in $INCLUDE_SOURCE; do
        if [[ -d "$src" ]]; then
            build_and_install_source "$src"
        else
            echo "  WARNING: Source directory not found: $src"
        fi
    done
fi

if [[ -d "$SOURCE_DIR" ]]; then
    for src in "$SOURCE_DIR"/*/; do
        [[ -d "$src" ]] || continue
        build_and_install_source "$src"
    done
fi

sudo chroot "$ROOTFS" ldconfig 2>/dev/null || true

echo "Package installation complete."
