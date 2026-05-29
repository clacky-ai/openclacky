# apt.sh — apt package manager helpers (Ubuntu/Debian)
# Depends-On: colors.sh network.sh
# Requires-Vars: $DISTRO $USE_CN_MIRRORS $CN_ALIYUN_MIRROR
# Sets-Vars: (none)
# Include via: @include lib/apt.sh

# Wait until apt/dpkg lock files are no longer held (e.g. by apt-daily on
# freshly-booted WSL/Ubuntu). Uses flock(1) — the same mechanism apt uses —
# rather than checking file existence (the lock files are always present;
# advisory locks live in the kernel, not the filesystem).
wait_apt_lock() {
    [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ] || return 0

    local locks=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
    )
    local max_wait="${1:-120}"
    local waited=0
    local announced=false

    while :; do
        local busy=false
        for f in "${locks[@]}"; do
            [ -e "$f" ] || continue
            if ! sudo flock -n "$f" -c true 2>/dev/null; then
                busy=true
                break
            fi
        done

        [ "$busy" = false ] && break

        if [ "$announced" = false ]; then
            print_info "Waiting for system apt/dpkg to finish (up to ${max_wait}s)..."
            announced=true
        fi

        if [ "$waited" -ge "$max_wait" ]; then
            print_error "apt is still locked after ${max_wait}s."
            print_info  "On WSL try: 'wsl --shutdown' from PowerShell, then rerun the installer."
            return 1
        fi

        sleep 3
        waited=$((waited + 3))
    done

    [ "$announced" = true ] && print_success "apt lock released"
    return 0
}

# Run an apt-get subcommand with lock-wait + transient-failure retry.
# Usage: apt_get_run update [-qq]
#        apt_get_run install -y pkg1 pkg2
apt_get_run() {
    local attempts=3
    local i=1
    while [ "$i" -le "$attempts" ]; do
        wait_apt_lock 120 || return 1
        if sudo apt-get "$@"; then
            return 0
        fi
        local rc=$?
        if [ "$i" -lt "$attempts" ]; then
            print_warning "apt-get $1 failed (exit $rc), retrying ($i/$((attempts-1)))..."
            sleep 5
        else
            print_error "apt-get $1 failed after $attempts attempts."
            return "$rc"
        fi
        i=$((i + 1))
    done
}

# Configure apt mirror for CN region and run apt-get update.
# Guards: only runs on ubuntu/debian ($DISTRO).
# Relies on $USE_CN_MIRRORS set by detect_network_region (network.sh).
setup_apt_mirror() {
    [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ] || return 0

    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Region: China — configuring Aliyun apt mirror"

        if [ -f /etc/apt/sources.list ]; then
            sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
            print_info "Backed up /etc/apt/sources.list to sources.list.bak"
        fi

        if [ "$DISTRO" = "debian" ]; then
            local codename="${VERSION_CODENAME:-bookworm}"
            local components="main contrib non-free non-free-firmware"
            local mirror="${CN_ALIYUN_MIRROR}/debian/"
            local security_mirror="${CN_ALIYUN_MIRROR}/debian-security/"
            sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror} ${codename} ${components}
deb ${mirror} ${codename}-updates ${components}
deb ${mirror} ${codename}-backports ${components}
deb ${security_mirror} ${codename}-security ${components}
EOF
        else
            local codename="${VERSION_CODENAME:-jammy}"
            local components="main restricted universe multiverse"
            local arch; arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
            if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
                local mirror="${CN_ALIYUN_MIRROR}/ubuntu-ports/"
            else
                local mirror="${CN_ALIYUN_MIRROR}/ubuntu/"
            fi
            sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror} ${codename} ${components}
deb ${mirror} ${codename}-updates ${components}
deb ${mirror} ${codename}-backports ${components}
deb ${mirror} ${codename}-security ${components}
EOF
        fi

        print_success "apt mirror set to Aliyun"
    else
        print_info "Region: global — using default apt sources"
    fi

    apt_get_run update -qq || return 1
    print_success "apt updated"
}
