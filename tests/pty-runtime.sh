#!/bin/bash
# PTY 시험용 runtime 경계. 실제 디스크를 열거나 root 권한을 사용하지 않는다.

source "$DISK_TEST_PROGRAM"

supplement_identity() { return 0; }
read_block_rows() {
    local line base=${1-}
    base=${base##*/}
    if [[ $# == 0 ]]; then
        cat "$DISK_TEST_FIXTURES/lsblk-pairs.txt"
        return
    fi
    while IFS= read -r line; do
        case "$line" in
            "NAME=\"$base\""*) printf '%s\n' "$line" ;;
        esac
    done < "$DISK_TEST_FIXTURES/lsblk-pairs.txt"
}

read_pool_status() { cat "$DISK_TEST_FIXTURES/zpool-status.txt"; }
canonical_device() {
    case "$1" in
        /dev/disk/by-id/ata-A) printf '/dev/sda\n' ;;
        /dev/disk/by-partuuid/part-B) printf '/dev/sdb1\n' ;;
        /dev/sd[a-d]|/dev/sd[a-d][12]) printf '%s\n' "$1" ;;
        *) return 1 ;;
    esac
}
device_is_block() {
    case "$1" in /dev/sd[a-d]|/dev/sd[a-d][12]) return 0 ;; *) return 1 ;; esac
}
device_number() {
    case "$1" in
        /dev/sda) printf '8:0\n' ;;
        /dev/sdb) printf '8:16\n' ;;
        /dev/sdc) printf '8:32\n' ;;
        /dev/sdd) printf '8:48\n' ;;
        *) return 1 ;;
    esac
}
byid_for_device() {
    case "$1" in
        /dev/sda) printf '/dev/disk/by-id/ata-A\n' ;;
        /dev/sdb) printf '/dev/disk/by-id/ata-B\n' ;;
    esac
}
parent_disk() {
    case "$1" in
        /dev/sda1|/dev/sda2) printf '/dev/sda\n' ;;
        /dev/sdb1) printf '/dev/sdb\n' ;;
        /dev/sd[a-d]) printf '%s\n' "$1" ;;
        *) return 1 ;;
    esac
}
check_runtime() { return 0; }
require_root() { return 0; }

open_selected_device() {
    exec 3</dev/null
    printf '0\n' > "$DISK_TEST_POSITION"
    FD_OPEN=1
}
fd_position() { cat "$DISK_TEST_POSITION"; }
child_running() {
    printf 'SEEN %s\n' "$1" >> "$DISK_TEST_TRACE"
    kill -0 "$1" 2>/dev/null
}

launch_burst() {
    local position bytes=$((READ_MIB * 1048576))
    position=$(cat "$DISK_TEST_POSITION")
    case "$DISK_TEST_MODE" in
        short) bytes=$((bytes / 2)) ;;
        error) bytes=0 ;;
    esac
    printf '%s\n' "$((position + bytes))" > "$DISK_TEST_POSITION"
    if [[ "$DISK_TEST_MODE" == error ]]; then
        /bin/bash -c 'exit 1' <&3 >/dev/null &
    else
        /bin/sleep "$DISK_TEST_SLEEP" <&3 >/dev/null &
    fi
    ACTIVE_PID=$!
    printf 'CHILD %s %s\n' "$ACTIVE_PID" "$SELECT_SERIAL" >> "$DISK_TEST_TRACE"
}

# 실제 30분을 기다리지 않고 유휴 만료 경계를 통과시키는 개발용 clock 전진.
trap 'SECONDS=$((SECONDS + IDLE_MINUTES * 60))' USR1
trap 'SECONDS=$((SECONDS + IDLE_MINUTES * 60 - 5))' USR2

main "$@"
