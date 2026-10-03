#!/bin/bash
# 개발용 회귀 테스트. 실제 block device와 root 권한을 사용하지 않는다.

set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
PROGRAM="$PROJECT_DIR/disk-locate"
TEST_BASH=${TEST_BASH:-/bin/bash}
PASSED=0
FAILED=0

assert_eq() {
    if [[ "$1" != "$2" ]]; then
        printf '  예상: <%s>\n  실제: <%s>\n' "$1" "$2" >&2
        return 1
    fi
}

assert_contains() {
    if [[ "$1" != *"$2"* ]]; then
        printf '  다음 내용이 없음: <%s>\n  실제: <%s>\n' "$2" "$1" >&2
        return 1
    fi
}

assert_rejected() {
    if "$@" >/dev/null 2>&1; then
        printf '  거부해야 하는 호출이 성공함: %s\n' "$*" >&2
        return 1
    fi
}

run_test() {
    local label=$1
    shift
    if ( "$@" ); then
        PASSED=$((PASSED + 1))
        printf 'PASS %s\n' "$label"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n' "$label"
    fi
}

load_program() {
    # source guard가 main을 실행하지 않아야 한다.
    source "$PROGRAM" || return 1
    BLOCK_FIXTURE="$TEST_DIR/fixtures/lsblk-pairs.txt"
    POOL_FIXTURE="$TEST_DIR/fixtures/zpool-status.txt"
    POOL_FAIL=0
    BLOCK_MISSING=0
    DEVICE_NUMBER_OVERRIDE=''
    CANONICAL_OVERRIDE=''
    NO_BYID=0
    install_mocks
}

# 이 경계 함수들만 대체한다. parser와 선택/검증 코드는 실제 구현을 실행한다.
install_mocks() {
supplement_identity() { return 0; }
read_block_rows() {
    local line base=${1-}
    base=${base##*/}
    [[ "$BLOCK_MISSING" == 0 ]] || return 1
    if [[ $# == 0 ]]; then
        cat "$BLOCK_FIXTURE"
        return
    fi
    while IFS= read -r line; do
        case "$line" in
            "NAME=\"$base\""*) printf '%s\n' "$line" ;;
        esac
    done < "$BLOCK_FIXTURE"
}

read_pool_status() {
    if [[ "$POOL_FAIL" != 0 ]]; then
        printf 'fixture: permission denied\n' >&2
        return 1
    fi
    cat "$POOL_FIXTURE"
}

canonical_device() {
    [[ -z "$CANONICAL_OVERRIDE" ]] || { printf '%s\n' "$CANONICAL_OVERRIDE"; return; }
    case "$1" in
        /dev/disk/by-id/ata-A|/dev/disk/by-id/wwn-A) printf '/dev/sda\n' ;;
        /dev/disk/by-partuuid/part-B) printf '/dev/sdb1\n' ;;
        /dev/sd[a-d]|/dev/sd[a-d][12]) printf '%s\n' "$1" ;;
        *) return 1 ;;
    esac
}

device_is_block() {
    [[ "$BLOCK_MISSING" == 0 ]] || return 1
    case "$1" in
        /dev/sd[a-d]|/dev/sd[a-d][12]) return 0 ;;
        *) return 1 ;;
    esac
}

device_number() {
    local line base=${1##*/} number
    [[ -z "$DEVICE_NUMBER_OVERRIDE" ]] || { printf '%s\n' "$DEVICE_NUMBER_OVERRIDE"; return; }
    while IFS= read -r line; do
        case "$line" in
            "NAME=\"$base\""*)
                number=${line#*MAJ:MIN=\"}
                printf '%s\n' "${number%%\"*}"
                return
                ;;
        esac
    done < "$BLOCK_FIXTURE"
    return 1
}

byid_for_device() {
    [[ "$NO_BYID" == 0 ]] || return 0
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
}

test_args_defaults() {
    load_program || return
    parse_args || return
    assert_eq tui "$MODE" || return
    assert_eq 64 "$READ_MIB" || return
    assert_eq 1 "$INTERVAL"
}

test_args_cli_modes() {
    load_program || return
    parse_args list || return
    assert_eq list "$MODE" || return
    parse_args --read-size 8M --interval 2 SN-A || return
    assert_eq locate "$MODE" || return
    assert_eq SN-A "$TARGET" || return
    assert_eq 8 "$READ_MIB" || return
    assert_eq 2 "$INTERVAL" || return
    parse_args /dev/sdb || return
    assert_eq locate "$MODE" || return
    assert_eq /dev/sdb "$TARGET"
}

test_args_option_only_tui() {
    load_program || return
    parse_args --read-size 1M --interval 10 || return
    assert_eq tui "$MODE" || return
    assert_eq 1 "$READ_MIB" || return
    assert_eq 10 "$INTERVAL"
}

test_args_invalid() {
    load_program || return
    assert_rejected parse_args --read-size 0M || return
    assert_rejected parse_args --read-size 65M || return
    assert_rejected parse_args --read-size 1.5M || return
    assert_rejected parse_args --read-size 8 || return
    assert_rejected parse_args --read-size || return
    assert_rejected parse_args --interval 0 || return
    assert_rejected parse_args --interval 11 || return
    assert_rejected parse_args --interval 1.5 || return
    assert_rejected parse_args --interval || return
    assert_rejected parse_args --of /tmp/output || return
    assert_rejected parse_args SN-A SN-B
}

test_parse_hex_and_spaces() {
    load_program || return
    parse_block_row 'NAME="sda" TYPE="disk" SIZE="17179869184" MODEL="Acme\x20Disk\x22Quote" SERIAL="SN\x5c-A" WWN="0x500a" MAJ:MIN="8:0" LOG-SEC="512"' || return
    assert_eq sda "$ROW_NAME" || return
    assert_eq disk "$ROW_TYPE" || return
    assert_eq 'Acme Disk"Quote' "$ROW_MODEL" || return
    assert_eq 'SN\-A' "$ROW_SERIAL" || return
    assert_eq 8:0 "$ROW_NUMBER" || return
    assert_eq 512 "$ROW_SECTOR"
}

test_parse_no_execution() {
    load_program || return
    parse_block_row 'NAME="sda" TYPE="disk" SIZE="1048576" MODEL="$(printf HACKED)" SERIAL="`printf HACKED`" WWN="" MAJ:MIN="8:0" LOG-SEC="512"' || return
    assert_eq '$(printf HACKED)' "$ROW_MODEL" || return
    assert_eq '`printf HACKED`' "$ROW_SERIAL"
}

test_parse_row_reset() {
    load_program || return
    parse_block_row 'NAME="sda" TYPE="disk" SIZE="1048576" MODEL="First" SERIAL="SN-A" WWN="0x500a" MAJ:MIN="8:0" LOG-SEC="512"' || return
    parse_block_row 'NAME="sdb" TYPE="disk" SIZE="1048576" MODEL="" SERIAL="" WWN="" MAJ:MIN="8:16" LOG-SEC="512"' || return
    assert_eq sdb "$ROW_NAME" || return
    assert_eq '' "$ROW_MODEL" || return
    assert_eq '' "$ROW_SERIAL" || return
    assert_eq '' "$ROW_WWN"
}

test_safe_terminal_output() {
    local result
    load_program || return
    parse_block_row 'NAME="sda" TYPE="disk" SIZE="1048576" MODEL="A\x1b[2JB\x0aC" SERIAL="SN-A" WWN="" MAJ:MIN="8:0" LOG-SEC="512"' || return
    assert_eq $'A\033[2JB\nC' "$ROW_MODEL" || return
    result=$(safe_text "$ROW_MODEL") || return
    [[ "$result" != *$'\033'* && "$result" != *$'\n'* ]] || {
        printf '  terminal 제어 문자가 그대로 출력됨\n' >&2
        return 1
    }
}

test_collection_filters() {
    load_program || return
    collect_disks || return
    assert_eq 4 "${#DISK_NAMES[@]}" || return
    assert_eq sda "${DISK_NAMES[0]}" || return
    assert_eq sdb "${DISK_NAMES[1]}" || return
    assert_eq 'Acme Disk' "${DISK_MODELS[0]}" || return
    assert_eq 4096 "${DISK_SECTORS[1]}"
}

test_pool_partition_and_offline() {
    load_program || return
    collect_disks || return
    assert_contains "${DISK_POOLS[0]}" tank || return
    assert_contains "${DISK_POOLS[0]}" archive || return
    assert_contains "${DISK_STATES[0]}" ONLINE || return
    [[ "${DISK_STATES[0]}" != *DEGRADED* ]] || return 1
    assert_eq tank "${DISK_POOLS[1]}" || return
    assert_eq OFFLINE "${DISK_STATES[1]}" || return
    [[ "${DISK_POOLS[2]}" != *tank* && "${DISK_POOLS[3]}" != *tank* ]] || {
        printf '  매핑 불가 GUID가 다른 디스크에 연결됨\n' >&2
        return 1
    }
    select_target SN-B || return
    assert_eq /dev/sdb "$SELECT_NAME" || return
    assert_eq OFFLINE "$SELECT_STATE"
}

test_pool_failure_unknown() {
    load_program || return
    POOL_FAIL=1
    collect_disks || return
    assert_eq UNKNOWN "${DISK_STATES[0]}" || return
    assert_eq UNKNOWN "${DISK_POOLS[0]}"
}

test_serial_exact_and_alias() {
    load_program || return
    collect_disks || return
    select_target SN-A || return
    assert_eq /dev/sda "$SELECT_NAME" || return
    assert_eq SN-A "$SELECT_SERIAL" || return
    assert_rejected select_target SN || return
    assert_rejected select_target A || return
    assert_rejected select_target 'SN-A;$(printf HACKED)' || return
    assert_rejected select_target /dev/disk/by-id/ata-A
}

test_duplicate_serial() {
    load_program || return
    BLOCK_FIXTURE="$TEST_DIR/fixtures/lsblk-duplicate-serial.txt"
    collect_disks || return
    assert_rejected select_target SN-A || return
    assert_rejected select_target /dev/sda
}

test_missing_identity() {
    load_program || return
    collect_disks || return
    select_target /dev/sdc || return
    assert_eq 0x500c "$SELECT_WWN" || return
    assert_rejected select_target /dev/sdd || return
    assert_rejected select_target /dev/sda1 || return
    assert_rejected select_target /tmp/ordinary-file || return
    assert_rejected select_target /dev/nvme0n1
}

test_no_byid_selection() {
    load_program || return
    NO_BYID=1
    collect_disks || return
    select_target SN-A || return
    assert_eq /dev/sda "$SELECT_NAME" || return
    revalidate_target
}

test_revalidation_snapshot() {
    local before
    load_program || return
    collect_disks || return
    select_target SN-A || return
    before="$SELECT_NAME|$SELECT_SERIAL|$SELECT_WWN|$SELECT_NUMBER|$SELECT_SIZE"
    revalidate_target || return
    assert_eq "$before" "$SELECT_NAME|$SELECT_SERIAL|$SELECT_WWN|$SELECT_NUMBER|$SELECT_SIZE" || return
    DEVICE_NUMBER_OVERRIDE=8:99
    assert_rejected revalidate_target || return
    assert_eq "$before" "$SELECT_NAME|$SELECT_SERIAL|$SELECT_WWN|$SELECT_NUMBER|$SELECT_SIZE" || return
    DEVICE_NUMBER_OVERRIDE=''
    CANONICAL_OVERRIDE=/dev/sdb
    assert_rejected revalidate_target || return
    CANONICAL_OVERRIDE=''
    BLOCK_MISSING=1
    assert_rejected revalidate_target
}

test_revalidation_replacement() {
    local before
    load_program || return
    collect_disks || return
    select_target SN-A || return
    before="$SELECT_NAME|$SELECT_SERIAL|$SELECT_WWN|$SELECT_NUMBER|$SELECT_SIZE"
    TEST_TEMP_ROW=$(mktemp "${TMPDIR:-/tmp}/disk-locate-row.XXXXXX") || return
    trap 'rm -f "$TEST_TEMP_ROW"' EXIT
    printf '%s\n' 'NAME="sda" TYPE="disk" SIZE="17179869184" MODEL="Acme\x20Disk" SERIAL="REPLACEMENT" WWN="0x9999" MAJ:MIN="8:0" LOG-SEC="512"' > "$TEST_TEMP_ROW"
    BLOCK_FIXTURE=$TEST_TEMP_ROW
    assert_rejected revalidate_target || return
    assert_eq "$before" "$SELECT_NAME|$SELECT_SERIAL|$SELECT_WWN|$SELECT_NUMBER|$SELECT_SIZE"
}

test_revalidation_individual_fields() {
    local before changed serial wwn size sector type
    load_program || return
    collect_disks || return
    select_target SN-A || return
    before="$SELECT_NAME|$SELECT_SERIAL|$SELECT_WWN|$SELECT_NUMBER|$SELECT_SIZE"
    TEST_TEMP_ROW=$(mktemp "${TMPDIR:-/tmp}/disk-locate-row.XXXXXX") || return
    trap 'rm -f "$TEST_TEMP_ROW"' EXIT
    BLOCK_FIXTURE=$TEST_TEMP_ROW
    for changed in serial wwn size sector type; do
        serial=SN-A
        wwn=0x500a
        size=17179869184
        sector=512
        type=disk
        case "$changed" in
            serial) serial=REPLACEMENT ;;
            wwn) wwn=0x9999 ;;
            size) size=8589934592 ;;
            sector) sector=4096 ;;
            type) type=part ;;
        esac
        printf 'NAME="sda" TYPE="%s" SIZE="%s" MODEL="Acme\\x20Disk" SERIAL="%s" WWN="%s" MAJ:MIN="8:0" LOG-SEC="%s"\n' \
            "$type" "$size" "$serial" "$wwn" "$sector" > "$TEST_TEMP_ROW"
        if revalidate_target >/dev/null 2>&1; then
            printf '  변경된 속성을 거부하지 않음: %s\n' "$changed" >&2
            return 1
        fi
        assert_eq "$before" "$SELECT_NAME|$SELECT_SERIAL|$SELECT_WWN|$SELECT_NUMBER|$SELECT_SIZE" || return
    done
}

test_cli_help_and_version() {
    local result
    result=$("$TEST_BASH" "$PROGRAM" --help 2>&1) || return
    assert_contains "$result" disk-locate || return
    assert_contains "$result" --read-size || return
    assert_contains "$result" --interval || return
    result=$("$TEST_BASH" "$PROGRAM" --version 2>&1) || return
    assert_contains "$result" disk-locate
}

test_dd_version() {
    local expected=$1
    load_program || return
    MOCK_DD_STATUS=$2
    MOCK_DD_OUTPUT=$3
    MOCK_DD_ERROR=${4-}
    declare -F check_dd >/dev/null || { printf '  check_dd 함수가 없음\n' >&2; return 1; }
    command() {
        if [[ $1 == dd ]]; then
            [[ $# == 2 && $2 == --version ]] || return 99
            printf '%s\n' "$MOCK_DD_OUTPUT"
            [[ -z $MOCK_DD_ERROR ]] || printf '%s\n' "$MOCK_DD_ERROR" >&2
            return "$MOCK_DD_STATUS"
        fi
        builtin command "$@"
    }
    if [[ $expected == accept ]]; then
        check_dd
    else
        assert_rejected check_dd
    fi
}

test_launch_fixed_dd_args() {
    local args argument
    load_program || return
    TEST_TEMP_ROW=$(mktemp "${TMPDIR:-/tmp}/disk-locate-dd-args.XXXXXX") || return
    trap 'rm -f "$TEST_TEMP_ROW"' EXIT
    command() {
        if [[ $1 == dd ]]; then
            shift
            printf '%s\n' "$@" > "$TEST_TEMP_ROW"
        else
            builtin command "$@"
        fi
    }
    exec 3</dev/null
    READ_MIB=8
    launch_burst || return
    wait "$ACTIVE_PID" || return
    args=$(cat "$TEST_TEMP_ROW") || return
    args=$'\n'$args$'\n'
    assert_contains "$args" $'\nof=/dev/null\n' || return
    assert_contains "$args" $'\nbs=1M\n' || return
    assert_contains "$args" $'\ncount=8\n' || return
    assert_contains "$args" $'\niflag=direct,fullblock\n' || return
    while IFS= read -r argument; do
        case "$argument" in
            of=/dev/null|bs=1M|count=8|iflag=direct,fullblock|status=none) ;;
            *) printf '  허용하지 않은 dd 인자: %s\n' "$argument" >&2; return 1 ;;
        esac
    done < "$TEST_TEMP_ROW"
    : > "$TEST_TEMP_ROW"
    ACTIVE_PID=
    STOP_REQUESTED=1
    launch_burst || :
    assert_eq '' "$ACTIVE_PID" || return
    [[ ! -s "$TEST_TEMP_ROW" ]] || return 1
    STOP_REQUESTED=0
    SHUTDOWN=1
    launch_burst || :
    assert_eq '' "$ACTIVE_PID" || return
    [[ ! -s "$TEST_TEMP_ROW" ]] || return 1
    exec 3<&-
}

test_signal_during_revalidation() {
    load_program || return
    collect_disks || return
    select_target SN-A || return
    require_root() { return 0; }
    open_selected_device() { exec 3</dev/null; FD_OPEN=1; }
    fd_position() { printf '0\n'; }
    launch_burst() { TEST_BURSTS=$((TEST_BURSTS + 1)); }
    revalidate_target() {
        TEST_REVALIDATIONS=$((TEST_REVALIDATIONS + 1))
        [[ "$TEST_REVALIDATIONS" != 2 ]] || handle_signal INT
        return 0
    }
    TEST_REVALIDATIONS=0
    TEST_BURSTS=0
    MODE=locate
    run_locate >/dev/null 2>&1 || :
    assert_eq 0 "$TEST_BURSTS" || return
    assert_eq 1 "$STOP_REQUESTED" || return
    assert_eq 1 "$SHUTDOWN" || return
    assert_eq 0 "$FD_OPEN"
}

test_unprivileged_read_rejection() {
    load_program || return
    if (( EUID == 0 )); then
        printf '  SKIP: 일반 사용자 검사에는 root 이외 계정이 필요함\n'
        return 0
    fi
    collect_disks || return
    select_target SN-A || return
    TEST_RAW_OPENS=0
    open_selected_device() { TEST_RAW_OPENS=$((TEST_RAW_OPENS + 1)); return 1; }
    assert_rejected run_locate || return
    assert_eq 0 "$TEST_RAW_OPENS"
}

test_burst_timeout() {
    load_program || return
    collect_disks || return
    select_target SN-A || return
    require_root() { return 0; }
    open_selected_device() { exec 3</dev/null; FD_OPEN=1; }
    fd_position() { printf '0\n'; }
    child_running() { builtin kill -0 "$1" 2>/dev/null; }
    launch_burst() { /bin/sleep 30 & ACTIVE_PID=$!; TEST_READ_PID=$ACTIVE_PID; TEST_BURSTS=$((TEST_BURSTS + 1)); }
    poll_controls() { SECONDS=$((SECONDS + 10)); }
    TEST_BURSTS=0
    if run_locate >/dev/null 2>&1; then
        printf '  burst timeout이 성공 종료로 표시됨\n' >&2
        return 1
    fi
    assert_eq 1 "$TEST_BURSTS" || return
    assert_contains "$STOP_REASON" '시간 제한' || return
    assert_eq 0 "$FD_OPEN" || return
    if builtin kill -0 "$TEST_READ_PID" 2>/dev/null; then
        builtin kill -KILL "$TEST_READ_PID" 2>/dev/null || :
        wait "$TEST_READ_PID" 2>/dev/null || :
        printf '  timeout 후 모의 읽기 자식이 남음\n' >&2
        return 1
    fi
}

test_cleanup_stuck_child() {
    load_program || return
    child_running() { return 0; }
    kill() { TEST_SIGNALS+="|$*"; return 0; }
    ACTIVE_PID=99999999
    POLL_PID=
    FD_OPEN=1
    exec 3</dev/null
    TEST_SIGNALS=
    if cleanup_work >/dev/null 2>&1; then
        printf '  종료 대기 자식을 정상 정리로 표시함\n' >&2
        return 1
    fi
    assert_eq 1 "$SHUTDOWN" || return
    assert_eq 1 "$EXIT_CODE" || return
    assert_eq 0 "$FD_OPEN" || return
    assert_contains "$TEST_SIGNALS" '-TERM 99999999' || return
    assert_contains "$TEST_SIGNALS" '-KILL 99999999' || return
    cleanup_work || return
    assert_eq 1 "$SHUTDOWN"
}

test_cli_invalid_and_non_tty() {
    local result
    assert_rejected "$TEST_BASH" "$PROGRAM" --read-size 999M || return
    assert_rejected "$TEST_BASH" "$PROGRAM" --unknown || return
    if result=$("$TEST_BASH" "$PROGRAM" </dev/null 2>&1); then
        printf '  non-TTY에서 인자 없는 실행이 성공함\n' >&2
        return 1
    fi
    case "$result" in
        *TTY*|*terminal*|*터미널*) return 0 ;;
        *) printf '  non-TTY 사용 안내가 없음: %s\n' "$result" >&2; return 1 ;;
    esac
}

if [[ ! -f "$PROGRAM" ]]; then
    printf '실행 파일이 없습니다: %s\n' "$PROGRAM" >&2
    exit 1
fi

"$TEST_BASH" -n "$PROGRAM" || exit 1
run_test '인자 없음의 TUI 기본값' test_args_defaults
run_test 'CLI 모드와 읽기 옵션' test_args_cli_modes
run_test '옵션만 지정한 TUI' test_args_option_only_tui
run_test '잘못된 옵션 및 범위 거부' test_args_invalid
run_test 'lsblk 공백 및 hex escape 파싱' test_parse_hex_and_spaces
run_test 'lsblk 문자열을 명령으로 실행하지 않음' test_parse_no_execution
run_test '연속 lsblk 행 사이 식별 속성 초기화' test_parse_row_reset
run_test 'terminal 제어 문자 표시 정화' test_safe_terminal_output
run_test '전체 SATA/SAS 디스크만 수집' test_collection_filters
run_test 'ZFS 파티션/by-partuuid/OFFLINE 및 다중 Pool 매핑' test_pool_partition_and_offline
run_test 'ZFS 조회 실패의 UNKNOWN 표시' test_pool_failure_unknown
run_test 'Serial 정확 일치와 alias 경로 거부' test_serial_exact_and_alias
run_test '중복 Serial의 모호한 선택 거부' test_duplicate_serial
run_test 'WWN 대체 및 식별 없는 디스크/파티션 거부' test_missing_identity
run_test 'by-id 없는 유일 Serial 선택' test_no_byid_selection
run_test '장치 번호/경로/소실 재검증 및 snapshot 유지' test_revalidation_snapshot
run_test '번호가 재사용된 교체 디스크 거부' test_revalidation_replacement
run_test 'Serial/WWN/크기/sector/type 개별 변경 거부' test_revalidation_individual_fields
run_test '실제 CLI help/version' test_cli_help_and_version
run_test '실제 CLI 잘못된 옵션과 non-TTY 거부' test_cli_invalid_and_non_tty
run_test 'GNU dd 9.1 실제 버전 banner 허용' test_dd_version accept 0 $'dd (coreutils) 9.1\nversion fixture detail'
run_test 'GNU dd 9.5 실제 버전 banner 허용' test_dd_version accept 0 $'dd (coreutils) 9.5\nversion fixture detail'
run_test '기존 GNU coreutils 표기 허용' test_dd_version accept 0 $'dd (GNU coreutils) 8.32\nversion fixture detail'
run_test 'BSD dd 버전 옵션 오류 거부' test_dd_version reject 1 '' $'dd: illegal option -- -\nusage: dd [operands ...]'
run_test 'BusyBox dd banner 거부' test_dd_version reject 0 $'BusyBox v1.36.1\nUsage: dd [if=FILE] [of=FILE]'
run_test '버전 옵션 오류 문자열 거부' test_dd_version reject 0 "dd: unrecognized option '--version'"
run_test '뒤쪽 GNU 문구로 dd를 오인하지 않음' test_dd_version reject 0 $'dd (BSD) 1.0\nGNU coreutils compatibility wrapper'
run_test 'GNU dd 9.1 banner라도 실패 exitstatus 거부' test_dd_version reject 1 'dd (coreutils) 9.1'
run_test '기존 GNU banner라도 실패 exitstatus 거부' test_dd_version reject 1 'dd (GNU coreutils) 8.32'
run_test '빈 dd 버전 출력 거부' test_dd_version reject 0 ''
run_test 'dd 출력 고정/direct/FD 상속 인자' test_launch_fixed_dd_args
run_test '재검증 도중 signal 후 burst 시작 금지' test_signal_during_revalidation
run_test '일반 사용자 Locate가 FD를 열기 전에 거부됨' test_unprivileged_read_rejection
run_test 'burst 시간 제한 후 새 읽기 금지와 자식 정리' test_burst_timeout
run_test 'kernel 종료 대기 모의 상황의 실패 표시와 새 작업 금지' test_cleanup_stuck_child
printf '\n통과 %s / 실패 %s\n' "$PASSED" "$FAILED"
[[ "$FAILED" == 0 ]]
