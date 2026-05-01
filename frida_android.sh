#!/usr/bin/env bash
set -euo pipefail

FRIDA_PORT="${FRIDA_PORT:-27042}"
FRIDA_REMOTE="${FRIDA_REMOTE:-/data/local/tmp/frida-server}"
FRIDA_VERSION="${FRIDA_VERSION:-}"
CACHE_DIR="${FRIDA_CACHE_DIR:-$HOME/.cache/frida-android-server}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

HAS_ROOT=""

detect_root() {
    if adb shell "su -c 'id'" 2>/dev/null | grep -q 'uid=0'; then
        HAS_ROOT=1
    else
        HAS_ROOT=""
        echo -e "${YELLOW}Warning: device does not have root (su) — running in non-root mode${RESET}" >&2
        echo -e "${YELLOW}         frida-server will only see debuggable apps${RESET}" >&2
    fi
}

device_shell() {
    if [[ -n "$HAS_ROOT" ]]; then
        adb shell "su -c '$*'"
    else
        adb shell "$*"
    fi
}

usage() {
    cat <<EOF
${BOLD}Frida Android Server Manager${RESET}

Usage: $(basename "$0") <command>

Commands:
  start        Ensure frida-server is installed at the matching version and launch it
                 (aliases: on, up)
  stop         Kill frida-server on the device
                 (aliases: off, down)
  restart      Stop, then start
  status       Show device/host versions, running pid, port, connectivity
                 (alias: st)
  install      Download + push frida-server, do not start
  uninstall    Stop and remove ${FRIDA_REMOTE}

Environment:
  FRIDA_VERSION    Override version (default: host \`frida --version\`,
                     fallback to latest GitHub release)
  FRIDA_PORT       Listen port (default: 27042)
  FRIDA_REMOTE     On-device path (default: /data/local/tmp/frida-server)
  FRIDA_CACHE_DIR  Host cache dir (default: \$HOME/.cache/frida-android-server)

Root access is auto-detected. On non-rooted devices frida-server runs as the
shell user and can only instrument debuggable apps.
EOF
}

check_adb() {
    if ! command -v adb &>/dev/null; then
        echo -e "${RED}Error: adb not found in PATH${RESET}" >&2
        exit 1
    fi
    local count
    count=$(adb devices | grep -c 'device$' || true)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${RED}Error: no Android device connected${RESET}" >&2
        exit 1
    fi
}

check_tools() {
    local missing=()
    for t in curl xz; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Error: missing required host tools: ${missing[*]}${RESET}" >&2
        exit 1
    fi
}

detect_arch() {
    local abi
    abi=$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n')
    case "$abi" in
        arm64-v8a)            echo "arm64" ;;
        armeabi-v7a|armeabi)  echo "arm" ;;
        x86_64)               echo "x86_64" ;;
        x86)                  echo "x86" ;;
        *)
            echo -e "${RED}Error: unsupported device ABI: '${abi}'${RESET}" >&2
            exit 1
            ;;
    esac
}

resolve_version() {
    if [[ -n "$FRIDA_VERSION" ]]; then
        echo "$FRIDA_VERSION"
        return
    fi
    if command -v frida &>/dev/null; then
        local v
        v=$(frida --version 2>/dev/null | tr -d '\r\n')
        if [[ -n "$v" ]]; then
            echo "$v"
            return
        fi
    fi
    echo -e "${YELLOW}Warning: host \`frida\` not found — fetching latest release tag from GitHub${RESET}" >&2
    local tag
    tag=$(curl -fsSL https://api.github.com/repos/frida/frida/releases/latest \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])' 2>/dev/null)
    if [[ -z "$tag" ]]; then
        echo -e "${RED}Error: failed to resolve latest frida version from GitHub${RESET}" >&2
        exit 1
    fi
    echo "$tag"
}

ensure_binary() {
    local version="$1" arch="$2"
    local fname="frida-server-${version}-android-${arch}"
    local cached="${CACHE_DIR}/${fname}"
    if [[ -x "$cached" ]]; then
        echo -e "${CYAN}Using cached binary: ${cached}${RESET}" >&2
        echo "$cached"
        return
    fi
    mkdir -p "$CACHE_DIR"
    local url="https://github.com/frida/frida/releases/download/${version}/${fname}.xz"
    local xz_path="${cached}.xz"
    echo -e "${CYAN}Downloading ${url}${RESET}" >&2
    if ! curl -fL --progress-bar -o "$xz_path" "$url" >&2; then
        echo -e "${RED}Error: failed to download ${url}${RESET}" >&2
        rm -f "$xz_path"
        exit 1
    fi
    echo -e "${CYAN}Decompressing ${xz_path}${RESET}" >&2
    xz -d -f "$xz_path"
    chmod +x "$cached"
    echo "$cached"
}

server_running_pid() {
    local pid
    pid=$(device_shell "pidof frida-server" 2>/dev/null | tr -d '\r' | awk '{print $1}')
    echo "$pid"
}

push_binary() {
    local local_path="$1"
    echo -e "${CYAN}Pushing $(basename "$local_path") -> ${FRIDA_REMOTE}${RESET}"
    adb push "$local_path" "$FRIDA_REMOTE" >/dev/null
    device_shell "chmod 755 ${FRIDA_REMOTE}"
}

launch_server() {
    echo -e "${CYAN}Launching frida-server on port ${FRIDA_PORT}...${RESET}"
    device_shell "nohup ${FRIDA_REMOTE} -l 0.0.0.0:${FRIDA_PORT} >/dev/null 2>&1 &" >/dev/null || true
    sleep 1
    local pid
    pid=$(server_running_pid)
    if [[ -n "$pid" ]]; then
        echo -e "${GREEN}frida-server running (pid ${pid}) on port ${FRIDA_PORT}${RESET}"
    else
        echo -e "${RED}Error: frida-server failed to start${RESET}" >&2
        exit 1
    fi
}

frida_install() {
    check_tools
    echo -e "${CYAN}[1/4] Detecting device architecture...${RESET}"
    local arch
    arch=$(detect_arch)
    echo -e "       arch: ${arch}"

    echo -e "${CYAN}[2/4] Resolving frida version...${RESET}"
    local version
    version=$(resolve_version)
    echo -e "       version: ${version}"

    echo -e "${CYAN}[3/4] Ensuring binary is available...${RESET}"
    local bin_path
    bin_path=$(ensure_binary "$version" "$arch")

    echo -e "${CYAN}[4/4] Pushing to device...${RESET}"
    push_binary "$bin_path"
    echo -e "${GREEN}Installed frida-server ${version} (${arch}) at ${FRIDA_REMOTE}${RESET}"
}

frida_start() {
    local pid
    pid=$(server_running_pid)
    if [[ -n "$pid" ]]; then
        echo -e "${YELLOW}frida-server already running (pid ${pid}) — restart to refresh${RESET}"
        return 0
    fi

    local installed=""
    installed=$(device_shell "[ -x ${FRIDA_REMOTE} ] && ${FRIDA_REMOTE} --version" 2>/dev/null | tr -d '\r\n' || true)
    local desired
    desired=$(resolve_version)

    if [[ -z "$installed" || "$installed" != "$desired" ]]; then
        if [[ -z "$installed" ]]; then
            echo -e "${YELLOW}No frida-server on device — installing ${desired}${RESET}"
        else
            echo -e "${YELLOW}On-device frida-server ${installed} != desired ${desired} — reinstalling${RESET}"
        fi
        frida_install
    else
        echo -e "${CYAN}Using existing on-device frida-server ${installed}${RESET}"
    fi

    launch_server
}

frida_stop() {
    echo -e "${CYAN}Stopping frida-server...${RESET}"
    local pid
    pid=$(server_running_pid)
    if [[ -z "$pid" ]]; then
        echo -e "${GREEN}frida-server is not running${RESET}"
        return 0
    fi

    device_shell "kill ${pid}" 2>/dev/null || true
    sleep 1

    pid=$(server_running_pid)
    if [[ -n "$pid" ]]; then
        echo -e "${YELLOW}SIGTERM ignored, sending SIGKILL...${RESET}"
        device_shell "kill -9 ${pid}" 2>/dev/null || true
        sleep 1
        pid=$(server_running_pid)
    fi

    if [[ -z "$pid" ]]; then
        echo -e "${GREEN}frida-server stopped${RESET}"
    else
        echo -e "${RED}frida-server still running (pid ${pid})${RESET}" >&2
        exit 1
    fi
}

frida_restart() {
    frida_stop || true
    frida_start
}

frida_uninstall() {
    frida_stop || true
    echo -e "${CYAN}Removing ${FRIDA_REMOTE}...${RESET}"
    device_shell "rm -f ${FRIDA_REMOTE}" 2>/dev/null || true
    local exists
    exists=$(adb shell "[ -e ${FRIDA_REMOTE} ] && echo yes || echo no" 2>/dev/null | tr -d '\r\n')
    if [[ "$exists" == "no" ]]; then
        echo -e "${GREEN}Uninstalled frida-server from device${RESET}"
    else
        echo -e "${RED}Failed to remove ${FRIDA_REMOTE}${RESET}" >&2
        exit 1
    fi
}

frida_status() {
    echo -e "${BOLD}=== Frida Android Server Status ===${RESET}\n"

    local device
    device=$(adb devices | grep 'device$' | awk '{print $1}')
    echo -e "${BOLD}Device:${RESET}        ${device:-none}"

    local arch
    arch=$(detect_arch 2>/dev/null || echo "unknown")
    echo -e "${BOLD}Arch:${RESET}          ${arch}"

    local host_v="not installed"
    if command -v frida &>/dev/null; then
        host_v=$(frida --version 2>/dev/null | tr -d '\r\n')
    fi
    echo -e "${BOLD}Host frida:${RESET}    ${host_v}"

    local device_v
    device_v=$(device_shell "[ -x ${FRIDA_REMOTE} ] && ${FRIDA_REMOTE} --version" 2>/dev/null | tr -d '\r\n' || true)
    if [[ -n "$device_v" ]]; then
        echo -e "${BOLD}Device server:${RESET} ${device_v} at ${FRIDA_REMOTE}"
    else
        echo -e "${BOLD}Device server:${RESET} ${YELLOW}not installed${RESET}"
    fi

    if [[ -n "$device_v" && -n "$host_v" && "$host_v" != "not installed" && "$host_v" != "$device_v" ]]; then
        echo -e "${YELLOW}                Warning: host (${host_v}) != device (${device_v})${RESET}"
    fi

    local pid
    pid=$(server_running_pid)
    if [[ -n "$pid" ]]; then
        echo -e "${BOLD}Process:${RESET}       ${GREEN}running (pid ${pid})${RESET}"
    else
        echo -e "${BOLD}Process:${RESET}       ${YELLOW}not running${RESET}"
    fi

    local listen
    listen=$(device_shell "netstat -tln 2>/dev/null | grep :${FRIDA_PORT}" 2>/dev/null | tr -d '\r' | head -1 || true)
    if [[ -n "$listen" ]]; then
        echo -e "${BOLD}Listening:${RESET}     ${GREEN}port ${FRIDA_PORT}${RESET}"
    else
        echo -e "${BOLD}Listening:${RESET}     ${YELLOW}port ${FRIDA_PORT} not bound${RESET}"
    fi

    echo ""
    echo -e "${BOLD}Connectivity:${RESET}"
    if command -v frida-ps &>/dev/null; then
        if frida-ps -U >/dev/null 2>&1; then
            echo -e "  frida-ps -U:   ${GREEN}OK${RESET}"
        else
            echo -e "  frida-ps -U:   ${RED}FAILED${RESET}"
        fi
    else
        echo -e "  frida-ps -U:   ${YELLOW}skipped (frida-tools not on host)${RESET}"
    fi
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

check_adb
detect_root

case "$1" in
    start|on|up)        frida_start ;;
    stop|off|down)      frida_stop ;;
    restart)            frida_restart ;;
    status|st)          frida_status ;;
    install)            frida_install ;;
    uninstall)          frida_uninstall ;;
    -h|--help|help)     usage ;;
    *)
        echo -e "${RED}Unknown command: $1${RESET}" >&2
        usage
        exit 1
        ;;
esac
