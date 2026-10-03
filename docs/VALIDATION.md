# 검증 기록

작성일: 2026-10-03

## v0.2.0 유휴 종료와 작업 시간 제한

기본 30분 유휴 종료, 기본 60초 식별 및 남은 초 표시, 명시적 `s` 재시작, TUI·CLI 시간 설정을 구현했다. macOS에서 Bash 회귀 **45개**, PTY/signal 검증 **20개**, 합계 **65개**가 모두 통과했다. 실제 NAS의 raw direct I/O와 LED 실기 검증은 기존과 마찬가지로 미확인이다.

```bash
/bin/bash -n disk-locate
/bin/bash -n tests/run.sh
/bin/bash -n tests/pty-runtime.sh
/bin/bash tests/run.sh
python3 -u tests/pty.py
```

위 명령은 모두 exit status `0`으로 종료했다. 유휴 검증은 테스트용 runtime에서만 사용하는 USR1/USR2 trap으로 Bash `SECONDS`를 전진시켜 30분 경계를 확인했다. 실제 운영 프로그램에는 이 trap이나 검증 우회 옵션이 없다. 작업 시간 만료 PTY는 공개 옵션 `--duration 3`으로 실제 3초 제한을 검증하고, 기본 60초 값과 감독 루프 경계는 Bash 회귀에서 확인했다. 입력 검사·장치 재검증과 정리는 실제 프로그램 함수를 사용하되 raw device 및 `dd`는 모의 구현으로 대체했다.

| 항목 | 확인 결과 |
| --- | --- |
| 기본값과 범위 | 유휴 30분·식별 60초, 옵션 최소·최대 및 `--옵션=값`, 숫자 아닌 값·0·overflow·범위 초과 거부 |
| 유휴 종료 | 목록·상세·시간 설정 값 입력에서 30분 만료로 정상 종료; 동작 없는 일반 키도 입력으로 초기화; 작업 중 유휴 종료 억제 |
| 전체 작업 시간 | 읽기·휴지 중 만료 시 자식 정리·FD 닫기·새 burst 금지, CLI 정상 종료 |
| 남은 초 표시 | 읽는 중·쉬는 중 countdown 갱신 및 0 표시, 음수 방지 |
| 재시작 | 만료 후 자동 읽기 없음, `s` 입력 후 같은 Serial의 새 작업, 장치 변경 시 FD open 전 거부 |
| 설정 | `t`에서 유휴 분·식별 초 변경 후 목록과 실제 작업에 적용, 범위 밖 값은 기존 설정 유지 |
| 기존 동작 | 메뉴 선택·새로고침·뒤로·`q`·Ctrl+C, CLI/TUI TERM/HUP 자식 정리, short read·읽기 오류 후 재시도 금지 및 terminal ECHO 복구 |

기존 burst별 10초 timeout도 회귀 검증에서 유지됨을 확인했다. 시간 만료는 사용자 공간에서 중단을 요청하는 한도이며, kernel I/O 대기 장치의 실제 종료 시각을 보장한 결과는 아니다.

## v0.1.1 시작 검사 수정

사용자가 실제 TrueNAS에서 v0.1.0을 실행했을 때 `dd`가 존재하지만 `GNU dd가 필요합니다`라는 오류가 발생했다. 정상 GNU 버전 문자열의 `dd (coreutils)` 표기를 잘못 거부하는 검사 문제를 v0.1.1에서 수정했다. GNU 버전 banner 허용과 실패 exit status 거부를 포함한 Bash 회귀 검증 35개가 통과했으며, `--version` 출력은 `disk-locate 0.1.1`로 확인했다. Linux raw direct I/O와 LED 실기 검증은 여전히 미확인이다.

개발 환경은 macOS다. 실제 TrueNAS에서의 v0.1.0 시작 오류는 사용자 보고로 확인했으며, 개발 환경에서 실제 TrueNAS SCALE ElectricEel 24.10에 접속해 검증하지는 않았다. fixture와 모의 명령을 사용하는 자동검증은 Linux raw device 동작 및 실제 Activity LED 확인을 대신하지 않는다.

## v0.1.1 이전 자동검증 기록

v0.1.1에서 저장소 루트의 다음 명령을 실행했다. 두 파일의 Bash 구문 검사와 회귀 검증 35개가 모두 exit status `0`으로 종료했다.

```bash
/bin/bash -n disk-locate
/bin/bash -n tests/run.sh
/bin/bash tests/run.sh
```

기존 v0.1.0에서는 Bash 구문 검사, 기능 회귀 25개와 다음 PTY 검증 11개가 exit status `0`으로 통과했다. PTY 검증은 v0.1.1에서 다시 실행하지 않았다.

```bash
python3 tests/pty.py
```

Python 3는 개발 환경의 PTY 검증에만 사용한다. 테스트용 코드와 도구는 NAS 배포물에 포함하지 않으며, NAS에는 `disk-locate` 파일 하나만 복사한다.

기능 회귀는 fixture와 경계 함수 mock을 사용한다. `dd` 인자 검증은 실제 `launch_burst`를 호출하되 실제 `dd` 실행을 차단하고, 입력 FD를 `/dev/null`로 대체해 호출을 기록했다. PTY 검증도 실제 raw device 대신 추적할 수 있는 `sleep` 자식과 모의 FD offset을 사용했다. 실제 raw device를 여는 root 실행, 디스크 FD 유지 및 direct I/O는 이 검사로 검증하지 않았다.

| 항목 | 확인 내용 | 상태 |
| --- | --- | --- |
| Bash syntax | `/bin/bash -n`으로 `disk-locate`와 `tests/run.sh` 구문 확인 | v0.1.1 통과 |
| GNU dd 시작 검사 | GNU 9.1·9.5 및 기존 GNU 표기 허용, BSD·BusyBox·빈 출력·오류 문자열·실패 exit status 거부 | v0.1.1 모의 검증 통과 |
| CLI와 옵션 | 실제 도움말·버전·잘못된 옵션·non-TTY 거부 호출, read size와 interval 범위 검증 | v0.1.1 통과 |
| 권한 확인 | 실제 일반 사용자 실행에서 FD open 전에 root 필요 안내와 거부 | v0.1.1 통과 |
| 디스크 목록과 선택 | 정확한 Serial 일치, 중복·누락 Serial 거부, alias, 공백·escape 및 terminal 제어 문자 처리 | v0.1.1 모의 검증 통과 |
| ZFS 매핑 | 파티션·by-partuuid의 전체 디스크 연결, OFFLINE·다중 Pool 표시, GUID 및 조회 실패의 UNKNOWN 처리 | v0.1.1 모의 검증 통과 |
| 읽기 명령 | 실제 `launch_burst`의 `dd` 인자와 입력 FD 3 사용, `/dev/null` 출력 고정, 사용자 입력의 명령 실행 방지, ZFS 조회 명령만 호출 | v0.1.1 모의 검증 통과 |
| 장치 재검증 | snapshot과 다른 장치 정보·장치 번호·경로·소실 거부, 재검증 중 INT 수신 후 burst 0회 | v0.1.1 모의 검증 통과 |
| 감독 및 정리 경계 | burst timeout, kernel I/O 대기 자식이 남는 상황의 정리 처리 | v0.1.1 모의 검증 통과 |
| 읽기 오류 중단 | read error·short read 이후 재시도 금지 | v0.1.0 PTY 모의 검증 통과 |
| 프로세스 정리 | CLI 읽기·휴지 중 INT/TERM/HUP으로 추적한 자식 정리 및 다음 burst 금지, 종료 코드 130/143/129 | v0.1.0 PTY 모의 검증 통과 |
| TUI 조작 | PTY에서 번호·잘못된 번호·빈 입력·`r`·`b`·`q`·Ctrl+C와 두 Serial의 반복 선택, 종료 뒤 ECHO 복구 | v0.1.0 PTY 모의 검증 통과 |
| TUI 작업 중단 | 식별 중 `q`와 Ctrl+C 후 목록 복귀·다음 디스크 선택, TERM/HUP은 목록 복귀 없이 프로그램 종료 | v0.1.0 PTY 모의 검증 통과 |

## 실제 TrueNAS 24.10 확인표

대상은 TrueNAS SCALE ElectricEel 24.10 release이며 케이스와 백플레인 모델은 미확인이다. 사용자가 기존 `dd` 읽기 중 LED 점멸을 확인했지만, 아래 스크립트 동작은 아직 실기 미검증이다.

| 항목 | 확인 방법 및 통과 조건 | 상태 |
| --- | --- | --- |
| 기본 도구 | 추가 설치 없이 Bash, GNU `dd`의 direct/fullblock, 필요한 `lsblk` 컬럼, `readlink`, GNU `stat -Lc`의 장치 번호 조회, `sleep`, `zpool` 조회 사용 가능 | 미실행 |
| 실제 디스크 정보 | Device, Size, Model, Serial, WWN, by-id를 알려진 디스크 정보와 대조 | 미실행 |
| 실제 ZFS 매핑 | `zpool status -LP`의 leaf vdev를 전체 디스크에 연결하고 개별 상태가 일치 | 미실행 |
| 읽기 전용 FD와 direct I/O | Linux의 별도 폐기 가능 시험 장치에서 FD 유지 및 전후 내용 동일 확인 | 미실행 |
| Activity LED | `--read-size 8M --interval 1`부터 짧게 실행해 대상 베이의 점멸 식별 | 미실행 |
| SSH 및 TrueNAS Shell TUI | 선택·상세·시작·중단·목록 복귀를 여러 디스크에 반복하고 입력과 echo 정상 확인 | 미실행 |
| 정상 중단 | 읽기 중과 휴지 중 `q`, Ctrl+C, TERM/HUP 후 새 읽기 중단 및 추적 자식 부재 확인 | 미실행 |
| 작업 시간 만료 | 기본 60초 countdown 후 중단, `s` 재시작 및 CLI 정상 종료, 시간 설정 변경 반영 | 미실행 |
| 유휴 종료 | 입력 없는 목록·상세·시간 설정 화면의 기본 30분 종료 및 키 입력 후 초기화 | 미실행 |
| OFFLINE 유지 | 운영자가 이미 OFFLINE 처리한 장치에서 식별하고 전후 `zpool status`가 OFFLINE 유지 | 미실행 |
| 배포 경로 보존 | 영속 dataset의 파일로 실행하고 재부팅 후 파일 및 실행 가능 여부 확인 | 미실행 |

오류·장치 제거 시험은 운영 Pool의 디스크를 분리해 재현하지 않는다. fixture 또는 별도 폐기 가능 시험 장치로 검증한다. TrueNAS 업데이트 후에는 기본 도구 및 실행 호환성을 다시 확인한다.

정상 I/O에서 1초 이내 중단과 자식 정리를 확인하는 것을 목표로 한다. 고장 장치가 kernel의 중단 불가능한 I/O 대기에 있으면 종료 signal에도 프로세스가 남을 수 있다. 이때 새 읽기를 중단하고 남은 PID를 표시하는지 따로 확인해야 한다.
