# TrueNas-dd-LED

TrueNAS SCALE에서 대상 디스크에 읽기 I/O를 발생시켜 Hot-swap Bay의 Activity LED로 물리 위치를 확인하는 CLI/TUI 도구다. 프로그램명은 `disk-locate`다.

버전 `0.2.0`은 단일 Bash 스크립트로 메뉴형 TUI와 CLI를 제공한다. macOS에서 Bash 구문 검사, 모의 회귀 45개와 PTY 검증 20개가 통과했다. 실제 TrueNAS 장치의 기본 도구, raw device 읽기 및 LED 동작은 개발 환경에서 아직 검증하지 않았다. 버전별 검증 범위와 실기 확인 항목은 [검증 기록](docs/VALIDATION.md)에 정리한다.

## 대상 환경

- TrueNAS SCALE ElectricEel 24.10 release.
- Linux에서 `/dev/sdX` 전체 디스크로 보이는 SATA/SAS 장치.
- SES Locate 기능 없이 Activity LED로 디스크를 식별하는 환경.
- 사용자가 기존 `dd` 읽기로 Activity LED 점멸을 확인했다. 케이스와 백플레인 모델은 미확인이다.

## 바로 실행하기

추가 패키지 설치 없이 TrueNAS에 이미 있는 Bash와 기본 명령을 사용하도록 작성했다. 저장소의 `disk-locate` 파일 하나만 영속 dataset에 복사하고 신뢰할 수 있는 관리자 shell에서 실행한다. 스크립트와 dataset을 포함한 모든 상위 디렉터리는 일반 공유 사용자가 수정할 수 없는 경로로 관리한다.

아래 예시는 Pool 이름이 `tank`이고, 스크립트를 `/mnt/tank/scripts/disk-locate`에 복사한 경우다. `tank`는 실제 Pool 이름으로 바꾼다. **프로그램 인자 없이 실행하면 바로 TUI의 디스크 목록이 열린다.** Serial이나 장치 경로를 입력하지 않고 화면에서 번호를 선택한다. LED 식별은 root 권한이 필요하며, 이미 root로 접속했다면 `sudo`를 생략할 수 있다.

```bash
sudo /bin/bash /mnt/tank/scripts/disk-locate
```

스크립트가 있는 폴더에서는 `sudo /bin/bash ./disk-locate`로 실행해도 된다. 실행 후 `번호 + Enter → 상세 정보 → s로 시작 → q 또는 Ctrl+C로 중단 → 목록 복귀` 순서로 사용한다.

NAS에 패키지, Git, `pip`, Docker 또는 Developer Mode를 준비할 필요가 없다. `/bin/bash`로 실행하므로 실행 권한 부여나 PATH 등록도 필수는 아니다. 일반 사용자는 권한 범위에서 목록을 조회할 수 있으며, TUI 안에서 `sudo`를 자동 실행하지 않는다.

Linux의 Bash, GNU `dd`, `lsblk`, `readlink`, GNU `stat`, `sleep`을 사용한다. `zpool` 조회 실패는 상태를 `UNKNOWN`으로 표시한다. 기본 도구가 없으면 자동 설치하지 않고 실행을 중단한다. 기본 읽기 설정은 64 MiB burst와 1초 휴지다.

## TUI 사용 흐름

인자 없이 실행하면 디스크 목록을 보여주는 메뉴형 TUI로 시작한다. SSH 또는 TrueNAS Shell에서 번호를 선택하고 상세 정보를 확인한 뒤 LED 식별을 시작한다.

```text
Disk Locator · TrueNAS SCALE 24.10

 #  DEVICE  SIZE  SERIAL     POOL  STATE
 1  sda     16T   ZL111111   tank  ONLINE
 2  sdb     16T   ZL222222   tank  ONLINE
 3  sdc     16T   ZL333333   tank  OFFLINE

번호 입력 후 Enter   [r] 새로고침   [t] 시간 설정   [q] 종료
```

- 선택한 디스크의 Model, Serial, WWN, Pool, 상태, by-id를 상세 화면에서 확인한다.
- 목록에서 번호와 Enter로 상세 화면에 들어가고, `r`로 새로고침하며 `q`로 종료한다.
- 상세 화면에서 `s`로 시작하고 `b`로 목록에 돌아가며 `q`로 종료한다. 선택만으로 읽기를 시작하지 않는다.
- 식별 중에는 대상 디스크, 읽기/휴지 상태, 경과 시간과 읽기 설정을 표시한다.
- `q` 또는 Ctrl+C로 읽기를 중단하고, 자식 프로세스 정리 후 목록으로 돌아간다.
- 목록이나 상세 화면의 Ctrl+C는 프로그램을 종료한다. `SIGTERM`과 `SIGHUP`은 어느 화면에서든 정리 후 종료한다.
- 화면의 번호는 목록 선택용이며 물리 베이 번호가 아니다.

프로그램은 입력이나 화면·작업 상태 변화 없이 기본 **30분** 동안 대기하면 종료한다. 키 입력, 화면 전환, 식별 시작·종료 및 시간 설정 변경이 대기 시간을 초기화한다. 식별 중에는 유휴 종료를 적용하지 않고 작업 자체의 시간 제한을 적용한다. 단순 화면 출력이나 남은 시간 갱신은 유휴 타이머를 초기화하는 사용자 입력으로 취급하지 않는다. 외부 NAS 상태를 자동 감시하는 기능은 포함하지 않는다.

dd 식별은 휴지 구간을 포함해 기본 **60초** 후 자동 중단하며, 읽는 중과 쉬는 중에 `남은 N초`를 표시한다. 정리 후 같은 디스크의 상세 화면에서 `[s] 다시 60초 식별`을 안내한다. `s`를 누른 경우에만 장치 정보를 재검증하고 새 60초 작업을 시작한다. `q` 또는 Ctrl+C로 직접 중단하면 기존처럼 목록으로 돌아간다. CLI로 디스크를 지정했을 때는 제한 시간이 끝나면 프로그램을 종료한다.

목록의 `[t] 시간 설정`에서 유휴 종료 시간(1~1440분)과 식별 시간(1~3600초)을 변경할 수 있다. 설정은 이번 실행 동안만 유지한다. 기본값으로 실행할 때는 여전히 인자가 필요 없다.

Bash의 `read`, `printf`로 구현하므로 `dialog`, `whiptail`, `curses`, `fzf` 설치가 필요 없다. 인자 없는 TUI 실행에는 terminal 입출력이 필요하다. `list`, Serial 또는 `/dev/sdX`를 지정하면 TUI에 진입하지 않고 CLI로 동작하며, CLI의 Ctrl+C는 읽기를 중단하고 프로그램을 종료한다.

## 선택적으로 사용하는 CLI와 옵션

일반적인 식별 작업은 위 TUI에서 수행한다. 목록만 출력하거나 디스크를 직접 지정하고 싶을 때 다음 CLI를 사용할 수 있다. 예시 Serial `ZL333333`과 `/dev/sdc`는 실제 목록에서 확인한 값으로 바꾼다.

```bash
sudo /bin/bash /mnt/tank/scripts/disk-locate list
sudo /bin/bash /mnt/tank/scripts/disk-locate ZL333333
sudo /bin/bash /mnt/tank/scripts/disk-locate /dev/sdc
/bin/bash /mnt/tank/scripts/disk-locate --help
```

| 옵션 | 기본값 | 허용 범위 |
| --- | --- | --- |
| `--read-size` | `64M` | `1M`부터 `64M`까지 정수 MiB |
| `--interval` | `1` | 읽기 완료 후 1부터 10까지 정수 초 |
| `--idle-timeout` | `30` | 유휴 종료 시간, 1부터 1440까지 정수 분 |
| `--duration` | `60` | 식별 작업 최대 시간, 1부터 3600까지 정수 초 |

예를 들어 `sudo bash disk-locate --idle-timeout 15 --duration 45`로 실행하면 유휴 종료는 15분, 식별 1회는 45초가 된다. 읽기 1회가 멈췄을 때의 기존 10초 timeout은 별도로 유지한다. 작업 시간 만료 시 진행 중인 자식을 종료하고 정리한다. 고장 장치의 kernel I/O 대기로 정리가 지연되는 경우까지 종료 시각을 보장하지는 않는다.

필요하면 `--read-size 8M --interval 1`처럼 설정을 조절할 수 있다. 옵션은 필수가 아니며, 대상 없이 옵션만 지정해도 TUI를 연다. 최초 실기 확인에서 읽기 부담을 줄이고 싶다면 8 MiB로 시작해 LED 식별 여부를 확인한다.

## 동작 원칙

- 디스크는 읽기 전용으로 열고, 읽은 데이터의 출력은 `/dev/null`로 고정한다.
- Serial을 정확히 대조하고, 실제 장치 정보를 보여준 뒤 읽기를 시작한다.
- 제한된 burst와 휴지 구간을 반복한다. 읽기 오류나 장치 변경을 감지하면 중단한다.
- `/dev/sdX` 전체 디스크만 대상으로 한다. 파티션, NVMe, loop 및 device-mapper 장치는 지원하지 않는다.
- ZFS Pool 및 디스크 관리 상태를 조회하며, `online`, `offline`, `detach`, `replace`를 실행하지 않는다.
- ZFS `OFFLINE` 장치도 현재 block device가 존재하고 읽을 수 있으면 선택할 수 있다. Pool 및 상태 조회 실패는 `UNKNOWN`으로 표시한다.
- Ctrl+C 시 새 읽기를 중단하고 이 도구가 생성한 프로세스를 정리한다. 고장 장치의 kernel I/O 대기로 종료가 지연되면 남은 PID를 표시하고 다른 디스크 읽기를 시작하지 않는다.

세부 설계, 단계별 검증, 완료 기준은 [구현 계획](docs/PLAN.md)에 정리했다.

## 시작 검사 오류

v0.1.0에서 `dd`가 있어도 `GNU dd가 필요합니다`라는 오류가 발생할 수 있다. 정상 GNU 버전 표기인 `dd (coreutils)`를 시작 검사에서 잘못 거부한 문제이며, v0.1.1에서 수정했다. v0.1.1 이상 파일로 교체하면 되며, 추가 패키지 설치는 필요하지 않다.
