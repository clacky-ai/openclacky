# network.sh — network region detection, mirror variables, URL probing
# Depends-On: colors.sh
# Requires-Vars: (none)
# Sets-Vars: $USE_CN_MIRRORS $NETWORK_REGION $CN_CDN_BASE_URL $CN_ALIYUN_MIRROR $CN_RUBYGEMS_URL $CN_NODE_MIRROR_URL $CN_NPM_REGISTRY $CN_MISE_INSTALL_URL $CN_RUBY_PRECOMPILED_URL $MISE_INSTALL_URL $NODE_MIRROR_URL $NPM_REGISTRY_URL $RUBY_VERSION_SPEC $DEFAULT_RUBYGEMS_URL $DEFAULT_MISE_INSTALL_URL $DEFAULT_NPM_REGISTRY
# Include via: @include lib/network.sh

# --------------------------------------------------------------------------
# Mirror variables — overridden by detect_network_region()
# --------------------------------------------------------------------------
SLOW_THRESHOLD_MS=5000
NETWORK_REGION="global"   # china | global | unknown
USE_CN_MIRRORS=false

GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com"
DEFAULT_RUBYGEMS_URL="https://rubygems.org"
DEFAULT_NPM_REGISTRY="https://registry.npmjs.org"
DEFAULT_MISE_INSTALL_URL="https://mise.run"

CN_CDN_BASE_URL="https://oss.1024code.com"
CN_CDN_FALLBACK_URL="https://clackyai-1258723534.cos.ap-guangzhou.myqcloud.com"
CN_ALIYUN_MIRROR="https://mirrors.aliyun.com"
CN_RUBYGEMS_URL="${CN_ALIYUN_MIRROR}/rubygems/"
CN_NPM_REGISTRY="https://registry.npmmirror.com"
CN_NODE_MIRROR_URL="https://cdn.npmmirror.com/binaries/node/"

# Derived from CN_CDN_BASE_URL — always set via _apply_cdn_base_url()
CN_MISE_INSTALL_URL="${CN_CDN_BASE_URL}/mise.sh"
CN_RUBY_PRECOMPILED_URL="${CN_CDN_BASE_URL}/ruby/ruby-{version}.{platform}.tar.gz"
CN_GEM_BASE_URL="${CN_CDN_BASE_URL}/openclacky"
CN_GEM_LATEST_URL="${CN_GEM_BASE_URL}/latest.txt"

# Active values (set by detect_network_region)
MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
RUBYGEMS_INSTALL_URL="$DEFAULT_RUBYGEMS_URL"
NPM_REGISTRY_URL="$DEFAULT_NPM_REGISTRY"
NODE_MIRROR_URL=""          # empty = mise default (nodejs.org)
RUBY_VERSION_SPEC="ruby@3"  # CN mode pins to a specific precompiled build

# --------------------------------------------------------------------------
# Internal probe helpers
# --------------------------------------------------------------------------

# Probe a single URL; echoes round-trip time in ms, or "timeout"
_probe_url() {
    local url="$1"
    local out http_code total_time
    out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout 5 --max-time 5 "$url" 2>/dev/null) || true
    http_code="${out%% *}"
    total_time="${out#* }"
    if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$http_code" = "$out" ]; then
        echo "timeout"; return
    fi
    awk -v s="$total_time" 'BEGIN { printf "%d", s * 1000 }'
}

# Returns 0 (true) if result is slow or unreachable
_is_slow_or_unreachable() {
    local r="$1"
    [ "$r" = "timeout" ] && return 0
    [ "${r:-9999}" -ge "$SLOW_THRESHOLD_MS" ] 2>/dev/null
}

_format_probe_time() {
    local r="$1"
    [ "$r" = "timeout" ] && echo "timeout" && return
    awk -v ms="$r" 'BEGIN { printf "%.1fs", ms / 1000 }'
}

_print_probe_result() {
    local label="$1" result="$2"
    if [ "$result" = "timeout" ]; then
        print_warning "UNREACHABLE  ${label}"
    elif _is_slow_or_unreachable "$result"; then
        print_warning "SLOW ($(_format_probe_time "$result"))  ${label}"
    else
        print_success "OK ($(_format_probe_time "$result"))  ${label}"
    fi
}

# Probe URL up to max_retries times; returns first fast result or last result
_probe_url_with_retry() {
    local url="$1" max="${2:-2}" result
    for _ in $(seq 1 "$max"); do
        result=$(_probe_url "$url")
        ! _is_slow_or_unreachable "$result" && { echo "$result"; return 0; }
    done
    echo "$result"
}

# --------------------------------------------------------------------------
# CN CDN resolution helpers
# --------------------------------------------------------------------------

# Probe primary CDN then fallback; echoes the reachable base URL or exits 1
_resolve_cdn_base_url() {
    local result
    result=$(_probe_url_with_retry "$CN_CDN_BASE_URL")
    _print_probe_result "CN CDN (oss.1024code.com)" "$result"
    ! _is_slow_or_unreachable "$result" && return 0

    print_warning "CN CDN unreachable — trying fallback..."
    result=$(_probe_url_with_retry "$CN_CDN_FALLBACK_URL")
    _print_probe_result "CN CDN fallback" "$result"
    if _is_slow_or_unreachable "$result"; then
        print_error "CN CDN and fallback both unreachable — cannot install."
        exit 2
    fi
    CN_CDN_BASE_URL="$CN_CDN_FALLBACK_URL"
}

# Apply a resolved base URL to all CDN-derived variables
_apply_cdn_base_url() {
    local base="$1"
    CN_CDN_BASE_URL="$base"
    CN_MISE_INSTALL_URL="${base}/mise.sh"
    CN_RUBY_PRECOMPILED_URL="${base}/ruby/ruby-{version}.{platform}.tar.gz"
    CN_GEM_BASE_URL="${base}/openclacky"
    CN_GEM_LATEST_URL="${CN_GEM_BASE_URL}/latest.txt"
}

# --------------------------------------------------------------------------
# detect_network_region — sets USE_CN_MIRRORS and active mirror variables
# --------------------------------------------------------------------------
detect_network_region() {
    print_step "Network pre-flight check..."
    echo ""

    local probe_google="https://www.google.com"
    local probe_github="https://raw.githubusercontent.com"
    local probe_baidu="https://www.baidu.com"

    local google_result github_result baidu_result
    google_result=$(_probe_url "$probe_google")
    github_result=$(_probe_url "$probe_github")
    baidu_result=$(_probe_url "$probe_baidu")

    _print_probe_result "google.com"            "$google_result"
    _print_probe_result "raw.githubusercontent.com" "$github_result"
    _print_probe_result "baidu.com"             "$baidu_result"

    local google_ok=false github_ok=false baidu_ok=false
    ! _is_slow_or_unreachable "$google_result" && google_ok=true
    ! _is_slow_or_unreachable "$github_result" && github_ok=true
    ! _is_slow_or_unreachable "$baidu_result"  && baidu_ok=true

    if [ "$google_ok" = true ] && [ "$github_ok" = true ]; then
        NETWORK_REGION="global"
        print_success "Region: global"
    elif [ "$baidu_ok" = true ]; then
        NETWORK_REGION="china"
        print_success "Region: china"
    else
        print_error "Region: unknown (all unreachable) — cannot install."
        exit 2
    fi
    echo ""

    if [ "$NETWORK_REGION" = "china" ]; then
        _resolve_cdn_base_url
        _apply_cdn_base_url "$CN_CDN_BASE_URL"

        local mirror_result
        mirror_result=$(_probe_url_with_retry "$CN_ALIYUN_MIRROR")
        _print_probe_result "Aliyun mirror" "$mirror_result"

        local mirror_ok=false
        ! _is_slow_or_unreachable "$mirror_result" && mirror_ok=true

        if [ "$mirror_ok" = true ]; then
            USE_CN_MIRRORS=true
            MISE_INSTALL_URL="$CN_MISE_INSTALL_URL"
            RUBYGEMS_INSTALL_URL="$CN_RUBYGEMS_URL"
            NPM_REGISTRY_URL="$CN_NPM_REGISTRY"
            NODE_MIRROR_URL="$CN_NODE_MIRROR_URL"
            RUBY_VERSION_SPEC="ruby@3.4.8"
            print_info "CN mirrors applied"
        else
            print_error "CN mirrors unreachable — cannot install."
            exit 2
        fi
    else
        USE_CN_MIRRORS=false
        RUBY_VERSION_SPEC="ruby@3"
    fi

    echo ""
}
