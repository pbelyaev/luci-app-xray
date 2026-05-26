#!/bin/sh

CONFIG="xray_core"
ACTION="${1:-due}"
IMPORTER="/usr/share/xray/subscription_import.uc"
FETCH_TIMEOUT=20

log() {
    logger -st xray-subscription[$$] -p4 "$*"
}

sanitize_message() {
    printf "%s" "$1" | tr '\r\n' ' ' | cut -c 1-160
}

set_subscription_status() {
    local section="$1"
    local status="$2"
    local message="$3"
    local now

    now="$(date +%s)"
    uci -q set "${CONFIG}.${section}.last_refresh=${now}"
    uci -q set "${CONFIG}.${section}.last_status=${status}"
    uci -q set "${CONFIG}.${section}.last_message=$(sanitize_message "$message")"
    uci -q commit "${CONFIG}"
}

interval_seconds() {
    local interval="$1"
    local unit="$2"

    case "${interval}" in
        ''|*[!0-9]*)
            interval=24
            ;;
    esac

    case "${unit}" in
        minute|minutes)
            echo $((interval * 60))
            ;;
        day|days)
            echo $((interval * 86400))
            ;;
        *)
            echo $((interval * 3600))
            ;;
    esac
}

subscription_due() {
    local section="$1"
    local last interval unit seconds now

    [ "${ACTION}" = "all" ] && return 0

    last="$(uci -q get "${CONFIG}.${section}.last_refresh" 2>/dev/null || echo 0)"
    interval="$(uci -q get "${CONFIG}.${section}.refresh_interval" 2>/dev/null || echo 24)"
    unit="$(uci -q get "${CONFIG}.${section}.refresh_unit" 2>/dev/null || echo hour)"
    seconds="$(interval_seconds "${interval}" "${unit}")"
    now="$(date +%s)"

    case "${last}" in
        ''|*[!0-9]*)
            last=0
            ;;
    esac

    [ "${last}" -eq 0 ] || [ $((now - last)) -ge "${seconds}" ]
}

fetch_subscription() {
    local url="$1"
    local output="$2"

    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T "${FETCH_TIMEOUT}" -O "${output}" "${url}"
        return $?
    fi

    wget -q -T "${FETCH_TIMEOUT}" -O "${output}" "${url}"
}

refresh_subscription() {
    local section="$1"
    local enabled url tmp output rc

    enabled="$(uci -q get "${CONFIG}.${section}.enabled" 2>/dev/null || echo 1)"
    [ "${enabled}" = "1" ] || return 0

    subscription_due "${section}" || return 0

    url="$(uci -q get "${CONFIG}.${section}.url" 2>/dev/null)"
    case "${url}" in
        http://*|https://*)
            ;;
        *)
            set_subscription_status "${section}" "error" "invalid subscription URL"
            log "${section}: invalid subscription URL"
            return 0
            ;;
    esac

    tmp="/tmp/xray_subscription_$$_$(echo "${section}" | tr -c 'A-Za-z0-9_' '_')"
    if ! fetch_subscription "${url}" "${tmp}"; then
        rm -f "${tmp}"
        set_subscription_status "${section}" "error" "fetch failed"
        log "${section}: fetch failed"
        return 0
    fi

    output="$(/usr/bin/ucode "${IMPORTER}" "${section}" "${tmp}" 2>&1)"
    rc=$?
    rm -f "${tmp}"

    if [ "${rc}" -ne 0 ]; then
        set_subscription_status "${section}" "error" "${output}"
        log "${section}: import failed: $(sanitize_message "${output}")"
        return 0
    fi

    log "${section}: ${output}"
    case "${output}" in
        *changed=1*)
            return 10
            ;;
    esac

    return 0
}

changed=0
sections="$(uci -q show "${CONFIG}" | sed -n "s/^${CONFIG}\\.\\([^=]*\\)=subscription$/\\1/p")"

for section in ${sections}; do
    refresh_subscription "${section}"
    rc=$?
    if [ "${rc}" -eq 10 ]; then
        changed=1
    fi
done

echo "changed=${changed}"
exit 0
