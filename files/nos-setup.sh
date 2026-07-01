#!/bin/sh

# NOS first-time setup script, invoked by cloud-init on first boot.

set -e

echo "nos-setup: running first-time initialization..."

# Allow raw-packet capable ping (kept from previous first-boot setup).
/usr/sbin/setcap cap_net_raw=ep /usr/bin/ping 2>/dev/null || true

# ---------------------------------------------------------------------------
# Parse /etc/machine.conf (key=value) to obtain ONIE platform information.
# ---------------------------------------------------------------------------
read_conf_file() {
    conf_file="$1"
    while IFS='=' read -r var value || [ -n "$var" ]; do
        var=$(echo "$var" | tr -d '\r\n')
        value=$(echo "$value" | tr -d '\r\n')
        # Strip inline comments.
        var=${var%#*}
        value=${value%#*}
        [ -z "$var" ] && continue
        # Trim surrounding quotes.
        tmp_val=${value#\"}
        value=${tmp_val%\"}
        eval "$var=\"$value\""
    done < "$conf_file"
}

ONIE_PLATFORM=""
if [ -r /etc/machine.conf ]; then
    read_conf_file "/etc/machine.conf"
elif [ -r /host/machine.conf ]; then
    read_conf_file "/host/machine.conf"
fi

ONIE_PLATFORM="${onie_platform:-}"
echo "nos-setup: onie_platform=${ONIE_PLATFORM:-unknown}"

# ---------------------------------------------------------------------------
# Add the Ubuntu NOS PPA and install platform-independent packages.
# ---------------------------------------------------------------------------
echo "nos-setup: adding PPA ppa:henrymao/ubuntu-nos..."
if command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository -y ppa:henrymao/ubuntu-nos
else
    # Fallback for minimal images without software-properties-common.
    . /etc/os-release 2>/dev/null || true
    SUITE="${VERSION_CODENAME:-noble}"
    cat > /etc/apt/sources.list.d/henrymao-ubuntu-nos.list <<EOF
deb http://ppa.launchpad.net/henrymao/ubuntu-nos/ubuntu ${SUITE} main
# deb-src http://ppa.launchpad.net/henrymao/ubuntu-nos/ubuntu ${SUITE} main
EOF
    if command -v apt-key >/dev/null 2>&1; then
        apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 2>/dev/null || true
    fi
fi

echo "nos-setup: updating apt cache..."
apt-get update

echo "nos-setup: installing socat, sswsyncd, opennsl, device-data..."
apt-get install -y --no-install-recommends socat sswsyncd opennsl device-data

# ---------------------------------------------------------------------------
# Install platform-specific platform-modules package based on onie_platform.
# ---------------------------------------------------------------------------
case "$ONIE_PLATFORM" in
    x86_64-dellemc_s5232f_c3538-r0)
        echo "nos-setup: installing platform-modules-s5232f for $ONIE_PLATFORM..."
        apt-get install -y --no-install-recommends platform-modules-s5232f
        ;;
    *)
        echo "nos-setup: no platform-modules package mapped for '${ONIE_PLATFORM:-unknown}'"
        ;;
esac

# ---------------------------------------------------------------------------
# Symlink /usr/share/sonic/hwsku -> /usr/share/sonic/device/$onie_platform/
# ---------------------------------------------------------------------------
if [ -n "$ONIE_PLATFORM" ]; then
    HWSKU_SRC="/usr/share/sonic/device/$ONIE_PLATFORM"
    HWSKU_DST="/usr/share/sonic/hwsku"
    if [ -d "$HWSKU_SRC" ]; then
        mkdir -p "$(dirname "$HWSKU_DST")"
        rm -f "$HWSKU_DST"
        ln -s "$HWSKU_SRC" "$HWSKU_DST"
        echo "nos-setup: linked $HWSKU_DST -> $HWSKU_SRC"
    else
        echo "nos-setup: WARNING, $HWSKU_SRC not present, skipping hwsku symlink"
    fi
else
    echo "nos-setup: WARNING, onie_platform is empty, skipping hwsku symlink"
fi

# Clean up apt cache to save space on the image.
apt-get clean
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

echo "nos-setup: first-time initialization complete"

exit 0
