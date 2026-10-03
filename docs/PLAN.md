# TrueNAS SCALE Disk Locator CLI/TUI 구현 계획

작성일: 2026-10-03

## 1. 목표와 확인된 조건

`disk-locate`는 디스크 목록에서 선택하거나 Serial 또는 현재 장치 경로로 디스크를 지정하고, 제한된 읽기 I/O를 반복해 Activity LED로 물리 베이를 식별하도록 돕는다. 사용자 제공 작업 명세서와 메뉴형 TUI 사용 요청을 기준으로 v1을 계획한다.

| 항목 | 조건 |
| --- | --- |
| 실행 OS | TrueNAS SCALE ElectricEel 24.10 release |
| 추가 설치 | 패키지, runtime, Python module, 별도 바이너리 설치 없이 실행 |
| 하드웨어 | 케이스와 백플레인 모델 미확인 |
| LED 동작 근거 | 사용자가 기존 `dd` 읽기 중 Activity LED 점멸을 확인 |
| 스토리지 | ZFS Pool, `/dev/sdX` 전체 디스크 |
| 프로그램 권한 | Locate는 root, 목록은 권한 범위 내 조회 |
| 사용자 인터페이스 | 인자 없이 실행하는 메뉴형 TUI, 기존 CLI 명령 유지 |
| 작업 범위 | 사용자 승인에 따라 CLI/TUI 구현 및 개발 환경 자동 검증 진행. NAS 실기 검증은 별도 |

추가 설치 금지는 기존 기본 명령 사용과 자체 스크립트 파일 복사를 허용하는 조건으로 해석한다. NAS에는 새로운 라이브러리나 개발 도구를 설치하지 않는다. 실제 NAS의 기본 명령 및 지원 옵션은 아직 확인하지 않았으므로 첫 구현 단계에서 확인한다.

## 2. 구현 및 배포 결정

실행 파일은 **단일 Bash 스크립트**로 만든다. 목록 조회, 선택 검증, ZFS 상태 조회, 읽기 반복, 종료 처리, 메뉴 표시를 작은 함수로 구분하되 별도의 plugin, daemon, service, 설정 파일은 만들지 않는다. TUI와 CLI는 같은 선택 검증 및 읽기 함수를 사용한다.

TrueNAS 24.10 공식 문서는 시스템 보호를 위해 기본 root/boot filesystem 변경과 `apt` 사용이 제한된다고 설명한다. 따라서 `/usr/local/bin` 설치나 Developer Mode 활성화를 요구하지 않고, 기존 영속 dataset에 스크립트를 저장한다. [TrueNAS 24.10 Developer Mode 문서](https://www.truenas.com/docs/scale/24.10/scaletutorials/systemsettings/advanced/developermode/)

| 도구 또는 인터페이스 | 용도 | 처리 원칙 |
| --- | --- | --- |
| `/bin/bash` | 인자 처리, 메뉴 입력·출력, 반복, signal, PID 관리 | 필수. `sh` 대신 Bash로 실행 |
| `lsblk` | 디스크 목록, 크기, Model, Serial, WWN, 부모 장치 | 명시한 출력 컬럼의 지원 여부 확인 |
| GNU `dd` | 제한된 direct read | `direct`, `fullblock` 옵션 확인 |
| `readlink` | by-id 및 by-partuuid의 실제 경로 확인 | 필수 |
| GNU `stat` | canonical 장치와 열린 FD의 장치 번호 대조 | 필수. 디스크 읽기 전에 지원 옵션 확인 |
| `sleep` | 읽기 사이 휴지, 프로세스 감독 간격 | 필수 |
| `/sys`, `/proc`, `/dev/disk` | 장치 유형·식별 정보·열린 FD 확인 | Linux 기본 인터페이스 |
| `zpool` | Pool 및 leaf vdev 상태 조회 | 실패 시 원인과 `UNKNOWN` 표시 |
| `udevadm` | `lsblk`에 없는 식별 정보 보완 | 있을 때만 조회. 없다고 설치하지 않음 |

`jq`, `pip`, `ledctl`, `storcli`, `sas2ircu`, `sas3ircu`, `sg_ses`에 의존하지 않는다. TUI는 Bash의 `read`, `printf`로 만들며 `dialog`, `whiptail`, `curses`, `fzf`에 의존하지 않는다. burst 시간 제한은 Bash의 `SECONDS`, `kill`, `wait`와 감독 루프로 처리해 `timeout`을 필수 의존성으로 추가하지 않는다.

필수 도구나 옵션이 없으면 누락 항목을 알려주고 Locate를 시작하지 않는다. 해당 NAS에서 기본 설치만으로 실행된다는 완료 판정도 보류한다. 자동 설치 또는 buffered read로의 자동 전환은 하지 않는다.

`dd`의 버전 확인은 정상 GNU 표기인 `dd (coreutils) <version>`과 `dd (GNU coreutils) <version>`을 허용한다. `--version` 명령의 실패도 함께 검사한다. `GNU coreutils` 문자열이 없다는 이유만으로 기존 `dd`를 거부하지 않는다. 사용자 환경에서 발견된 v0.1.0의 시작 검사 오탐은 v0.1.1에서 수정하고 실제 버전 문자열 fixture로 회귀 검증한다.

최종 배포물은 `disk-locate` 파일 하나다. 사용자가 현재 접속 수단으로 복사하고 다음처럼 실행한다.

```bash
# 구현 후 사용 예시. <pool>과 <SERIAL>은 실제 값으로 교체한다.
sudo /bin/bash /mnt/<pool>/scripts/disk-locate
sudo /bin/bash /mnt/<pool>/scripts/disk-locate list
sudo /bin/bash /mnt/<pool>/scripts/disk-locate <SERIAL>
```

이 방식은 실행 권한 부여나 PATH 등록을 필수로 하지 않는다. 저장 경로의 모든 상위 디렉터리와 스크립트는 일반 공유 사용자가 수정할 수 없도록 관리한다. dataset이 잠겼거나 unmount된 동안에는 실행할 수 없다. 재부팅과 TrueNAS 업데이트 후 파일 보존 및 기본 도구 호환성을 다시 확인한다.

## 3. v1 명령과 기본값

최소 명령:

```text
disk-locate
disk-locate list
disk-locate <SERIAL>
disk-locate /dev/sdX
disk-locate --help
disk-locate --version
```

인자 없는 실행은 TUI로 시작한다. stdin과 stdout이 terminal이 아니면 도움말과 명시적 CLI 명령 사용 안내를 출력하고 오류 종료한다. `list`, Serial 및 장치 경로를 지정한 CLI는 TUI에 진입하지 않는다.

일반 사용자 흐름은 `프로그램 인자 없이 실행 → 디스크 목록에서 번호 선택 → 상세 확인 → s로 시작`이다. 사용 안내도 이 흐름을 먼저 보여준다. Serial, 장치 경로와 읽기 옵션 입력은 기본 TUI 사용에 필요하지 않다.

LED 식별에 필요한 조절만 제공한다. 대상 없이 `--read-size` 또는 `--interval`만 지정하면 해당 값을 적용한 TUI로 시작한다. TUI 화면에서 복잡한 설정 메뉴를 별도로 만들지 않는다.

| 옵션 | 기본값 | 허용 범위 |
| --- | --- | --- |
| `--read-size` | `64M`, 64 MiB | `1M`부터 `64M`까지 정수 MiB |
| `--interval` | `1`, 읽기 완료 후 1초 휴지 | 1부터 10까지 정수 초 |

원 명세의 64 MiB / 1초 기본값을 유지한다. 실기 검증은 `--read-size 8M`부터 시작해 점멸이 충분하면 작은 값을 사용한다. 64 MiB가 모든 고장 디스크에 안전하다는 의미는 아니다.

`of=`, `if=`, `conv=`, 임의 `dd` 옵션, 임의 명령 문자열은 받지 않는다. `--device`, `--serial`, `--verbose`, Pool 필터, duration, 영구 로그는 초기 구현에 넣지 않는다.

### TUI 화면과 조작

SSH와 TrueNAS Shell에서 사용할 수 있는 **번호 선택형 메뉴**를 기본으로 한다. 초기 버전에서는 방향키 escape sequence 처리와 mouse 조작을 추가하지 않는다.

```text
Disk Locator · TrueNAS SCALE 24.10

 #  DEVICE  SIZE  SERIAL     POOL  STATE
 1  sda     16T   ZL111111   tank  ONLINE
 2  sdb     16T   ZL222222   tank  ONLINE
 3  sdc     16T   ZL333333   tank  OFFLINE

번호 입력 후 Enter   [r] 새로고침   [q] 종료
```

| 화면 | 표시 내용 | 조작 |
| --- | --- | --- |
| 목록 | 선택 번호, Device, Size, Serial, Pool, leaf vdev State | 번호와 Enter로 상세 보기, `r` 새로고침, `q` 종료 |
| 상세 | Device, Size, Model, 전체 Serial, WWN, Pool, State, by-id, 읽기 설정 | `s` 식별 시작, `b` 목록으로 돌아가기, `q` 종료 |
| 식별 중 | 대상 정보, 읽기 중/휴지 중 상태, 경과 시간, 읽기 설정 | `q` 또는 Ctrl+C로 중단 |
| 정리 중 | 중단 사유와 자식 프로세스 정리 상태 | 새로운 디스크 선택과 읽기 금지 |

식별을 멈추고 자식 정리가 확인되면 목록을 새로 조회해 돌아간다. 목록에는 직전 대상 Serial과 종료 사유를 짧게 표시한다. 읽기 오류도 정리가 끝난 뒤 표시하고, 사용자가 다시 선택하기 전에는 읽지 않는다. 자식이 kernel I/O 대기에 남으면 종료 대기 상태와 PID를 표시하고 TUI를 종료하며, 다른 디스크를 이어서 시작하지 않는다.

일반 사용자로 TUI를 열면 조회 가능한 정보만 보여주고 읽기 시작은 비활성화한다. root가 필요하다는 실행 안내를 제공하며, 메뉴 안에서 `sudo`를 자동 실행하지 않는다.

### TUI의 선택 검증과 표시 원칙

- 번호는 현재 화면의 선택 번호이며 물리 베이 번호가 아니다.
- 화면을 그릴 때 번호와 해당 디스크의 Serial/WWN/장치 정보를 함께 보관한다. 읽기 시작 시 새 목록의 같은 번호로 대상을 바꾸지 않는다.
- 상세 화면에 진입할 때와 `s`를 누를 때 현재 정보를 다시 검증한다. 선택 후 장치가 사라지거나 표시했던 장치 정보가 달라지면 읽지 않고 목록 재선택을 요구한다.
- 중복 Serial 등으로 선택이 모호하거나 식별 정보가 부족하면 이유를 보여주고 시작하지 않는다. 화면 선택으로 CLI의 검증을 우회하지 않는다.
- 목록에서는 긴 정보를 요약할 수 있지만 상세 화면의 Serial, WWN, by-id는 전체 값을 표시한다. `UNKNOWN`과 조회 실패 안내를 화면에 유지한다.
- 화면 갱신은 수동 새로고침과 작업 상태 변경 시에만 수행한다. 읽는 중에는 다른 디스크로 선택을 바꿀 수 없다.
- ANSI를 사용할 수 있는 terminal에서는 구분선과 강조를 적용하고, `TERM=dumb` 또는 기능이 불분명한 terminal에서는 일반 텍스트 메뉴를 사용한다. 상태는 색상 없이도 읽을 수 있어야 한다.
- 화면 제어 때문에 `clear`, `tput`, `stty`를 필수 도구로 추가하지 않는다. alternate screen이나 terminal mode를 계속 변경해 두지 않으며, 종료 후 입력과 echo가 정상인지 확인한다.
- 화면의 읽기/휴지 상태는 프로그램의 작업 상태다. 실제 LED 상태나 물리 베이 번호를 자동 감지한 것처럼 표시하지 않는다.

## 4. 디스크 목록과 Serial 선택

1. `lsblk`와 sysfs에서 `/dev/sd[a-z]+`에 해당하는 실제 전체 디스크를 수집한다. `TYPE=disk`와 block device 여부를 함께 확인한다.
2. `NAME`, 크기, Model, Serial, WWN을 수집하고, `/dev/disk/by-id`의 링크를 실제 디스크에 연결한다.
3. Serial은 조회된 실제 속성과 **전체 문자열이 정확히 일치**해야 한다. by-id 파일명 suffix나 부분 문자열로 결정하지 않는다.
4. 여러 by-id alias가 같은 장치를 가리키면 하나의 디스크로 취급한다. 서로 다른 디스크가 같은 Serial을 보고하면 임의 선택 없이 중단한다.
5. by-id가 없더라도 현재 장치 속성에서 Serial이 유일하고 재검증 가능하면 선택할 수 있다. 이 경우 by-id는 `-`로 표시한다.
6. `/dev/sdX` 직접 입력도 같은 검증을 거친다. 파티션, 일반 파일, directory, loop, device-mapper, NVMe는 v1 Locate 대상에서 제외한다.

SAS도 이 조건을 만족하면 같은 방식으로 지원한다. multipath나 RAID 가상 디스크와 물리 디스크 간 매핑은 v1 지원 범위가 아니다.

목록과 실행 전 화면에는 Device, Size, Model, Serial, WWN, Pool, ZFS State, by-id를 출력한다. 직접 경로로 선택한 경우 경로가 재부팅이나 교체 후 달라질 수 있다는 짧은 안내를 함께 표시한다.

Serial 선택에서 Serial을 확인할 수 없으면 중단한다. 직접 경로 선택에서도 Serial 또는 WWN 중 하나는 있어야 진행 중 장치 식별을 재검증할 수 있다. 누락한 필드는 `UNKNOWN`으로 표시한다.

`lsblk`는 기본 출력에 의존하지 않고 필요한 컬럼을 명시한다. `--pairs` 결과의 hex escape를 제한된 parser로 처리하며 `eval`로 실행하지 않는다. Serial, Model 등 외부 문자열은 명령으로 해석하지 않고, 출력에서도 terminal 제어 문자를 그대로 실행시키지 않는다. [lsblk 공식 manual](https://man7.org/linux/man-pages/man8/lsblk.8.html)

## 5. ZFS Pool과 디스크 상태 연결

`LC_ALL=C`에서 `zpool status -LP`를 조회한다. `-L`은 symlink를 실제 경로로 해석하고, `-P`는 전체 경로를 표시한다. JSON 지원 여부나 최신 OpenZFS 옵션에 의존하지 않는다. [OpenZFS zpool-status manual](https://openzfs.github.io/openzfs-docs/man/v2.2/8/zpool-status.8.html)

처리 순서:

1. `config`의 leaf vdev와 상태를 읽는다. Pool 전체의 `DEGRADED`를 개별 디스크 상태로 사용하지 않는다.
2. by-id, by-partuuid, `/dev/sdX1`처럼 표현된 경로를 실제 장치에 연결한다.
3. 파티션은 `lsblk PKNAME` 또는 sysfs의 부모 관계로 전체 디스크에 연결한다. 문자열 끝의 숫자를 잘라 부모를 추측하지 않는다.
4. 그 전체 디스크의 Serial/WWN과 목록 정보를 교차 확인한다.
5. 같은 디스크에 여러 ZFS 구성 요소가 연결되면 모두 표시한다. 다른 Pool에 속한 것처럼 임의로 하나를 선택하지 않는다.

`OFFLINE`이어도 block device가 존재하고 읽기가 가능하면 Locate를 허용한다. 장치 경로가 사라졌거나 GUID만 남아 매핑할 수 없는 vdev는 디스크 목록의 특정 항목에 억지로 연결하지 않는다.

상태 표기:

| 표기 | 의미 |
| --- | --- |
| `ONLINE`, `OFFLINE` 등 | 현재 조회에서 정확히 연결한 leaf vdev 상태 |
| Pool `-`, State `N/A` | 조회가 성공했고 현재 import된 Pool에서 연결 항목 없음 |
| `UNKNOWN` | 조회 권한 부족, 조회 실패 또는 매핑 불가 |

`UNKNOWN`을 `ONLINE`이나 Pool 미소속으로 바꾸지 않는다. Pool 연결 정보가 부족해도 물리 장치 식별이 정확하면 읽기 자체는 가능하지만, 교체 판단에 사용할 수 없다는 안내를 표시한다.

`zpool` 사용은 조회로 한정한다. `online`, `offline`, `detach`, `replace`, `clear`, `import` 등 변경 명령을 호출하지 않는다. SMART 조회·검사도 v1 기능에 포함하지 않는다.

## 6. 읽기 전용 구조와 장치 변경 방어

읽기 전용은 단순 안내가 아니라 파일 descriptor와 명령 생성 단계에서 보장한다.

1. 실행 직전 canonical path, 전체 디스크 여부, Serial/WWN, 장치 번호를 다시 확인한다.
2. 디스크를 Bash의 입력 전용 redirection으로 한 번 열어 FD를 유지한다. 읽기/쓰기 mode인 `<>`는 사용하지 않는다.
3. 열린 FD의 장치 번호와 조회한 장치 번호를 대조하고, 직후 식별 정보도 다시 확인한다. 불일치하면 읽기 전에 중단한다.
4. `dd`는 검증된 FD를 표준입력으로 상속받는다. 각 burst마다 `/dev/sdX`를 새로 열어 교체된 장치로 자동 이동하지 않는다.
5. 출력은 코드에 고정된 `of=/dev/null`만 사용한다. CLI 인자는 허용된 숫자 값으로 변환한 뒤 전달한다.
6. 매 burst 전에 sysfs 및 식별 정보를 재확인한다. 장치 소실, 번호 변경, 식별 정보 변경 또는 확인 실패 시 새 burst를 시작하지 않는다.

root 실행 시 기본 시스템 경로에서 명령을 찾고, 인자는 Bash 배열과 quoting으로 전달한다. `eval`, `bash -c`로 사용자 문자열을 실행하지 않는다.

이 구조는 검증과 장치 open 사이의 변경 위험을 줄이기 위한 것이다. 실제 24.10에서 FD 상속, direct I/O, 제거 후 장치 번호 재사용 동작을 시험하기 전에는 hot-swap 안전성을 완료로 판단하지 않는다. 읽기가 실행 중인 디스크를 제거하는 사용 흐름은 지원하지 않는다.

읽은 데이터는 `/dev/null`로만 전달하고 파일·로그에 저장하지 않는다. 읽기 전용 보장은 **이 도구가 대상 디스크에 쓰기 요청을 하지 않는 것**을 의미한다. 다른 ZFS 작업이나 서비스가 만드는 I/O까지 중지시키는 기능은 아니다.

실행 코드는 Mac의 Bash 3.2에서도 parser와 메뉴를 모의 시험할 수 있도록 indexed array와 고정 입력 FD 3을 사용한다. 실제 장치 검증은 Linux `/proc`와 GNU `stat`가 있는 환경에서만 수행한다. 개발 테스트는 파일을 source한 뒤 함수 경계만 모의 구현으로 바꾸며, 배포 CLI에 장치 검증 우회 옵션이나 테스트용 경로 override를 추가하지 않는다.

## 7. LED 점멸 방식

기본 동작은 `64 MiB 읽기 → 1초 휴지 → 반복`이다. 연속 전체 디스크 읽기는 사용하지 않는다.

burst는 `bs=1M`, 제한된 `count`, `iflag=direct,fullblock`로 구성한다. FD의 읽기 위치가 다음 burst로 이어지므로 같은 앞부분만 반복 읽지 않는다. 디스크 끝의 경계에 도달하면 새로 장치를 열지 않고 정상 중단한다. 예상보다 짧은 읽기는 종료 상태와 전송량 metadata를 확인해 중단한다.

short read는 자식 `dd`가 종료하고 `wait`로 회수된 뒤 `/proc/<부모PID>/fdinfo/3`의 읽기 전후 `pos` 차이를 비교해 판단한다. `dd`의 exit code 0만으로 전체 burst를 읽었다고 판단하지 않는다. 디스크 끝에 남은 범위가 burst보다 작으면 새 읽기를 시작하지 않고 종료한다.

GNU `dd`의 direct I/O는 OS buffer cache를 우회한다. 크기와 offset은 장치의 sector 정렬 조건을 만족해야 한다. direct I/O를 지원하지 않거나 정렬 오류가 나면 설명을 출력하고 중단한다. [GNU dd manual](https://www.gnu.org/s/coreutils/manual/html_node/dd-invocation.html)

direct I/O가 디스크·컨트롤러 내부 cache까지 비활성화하는 것은 아니다. 또한 다른 workload가 같은 LED를 계속 켜면 휴지 구간이 보이지 않을 수 있다. 이미 확인한 점멸 효과를 실제 burst 조건에서 다시 검증하고, 소프트웨어가 LED 상태나 물리 베이 번호를 읽어냈다고 표현하지 않는다.

## 8. Signal, 읽기 시간 제한과 오류 처리

`dd`와 휴지용 `sleep`은 추적 가능한 자식 프로세스로 실행한다. Bash 감독 루프는 PID와 시작 시간을 관리하고, burst별 **10초**를 넘기면 추가 읽기 없이 종료 절차에 들어간다. 이는 사용자 공간에서 정한 작업 한도이며 kernel I/O의 종료 시각 보장은 아니다.

종료 절차:

1. TUI의 `q` 또는 `SIGINT`, `SIGTERM`, SSH 종료에 해당하는 `SIGHUP`을 받으면 중단 flag를 세운다.
2. 새 burst를 금지하고 이 도구가 생성한 `dd`와 `sleep`에 `SIGTERM`을 보낸다. 비대화형 Bash의 background 작업에서는 `SIGINT`가 무시될 수 있으므로 자식 정리에 `SIGINT`만 의존하지 않는다.
3. 짧은 유예 후 남은 자식에 `SIGKILL`을 보내고, 종료한 자식은 `wait`로 회수한다. 다른 `dd` 프로세스를 이름으로 찾아 종료하지 않는다.
4. FD를 닫고 종료 사유, Device, Serial을 표시한다. 정리 함수는 중복 실행되어도 새 작업을 만들지 않는다. 작업별 중단 및 FD 정리와 프로그램 전체 종료는 구분한다.
5. 제한된 정리 대기 후에도 자식이 남아 있으면 정상 완료라고 표시하지 않고, PID와 I/O 종료 대기 상태를 알려준다.

정상적인 I/O에서는 signal 수신 후 1초 이내에 새 읽기가 중단되고 관련 자식이 없어지는 것을 목표로 한다. Bash의 signal 처리와 `wait` 동작은 구현 시 실제 중단 시험으로 확인한다. [Bash signal 문서](https://www.gnu.org/s/bash/manual/html_node/Signals.html)

TUI에서 `q` 또는 식별 중 Ctrl+C는 현재 작업을 중단하고 정리 완료 후 목록으로 돌아간다. 목록이나 상세 화면의 Ctrl+C는 프로그램을 종료한다. `SIGTERM`과 `SIGHUP`은 어느 화면에서든 정리 후 프로그램을 종료한다. 기존 CLI에서 Ctrl+C는 읽기 중단 후 프로그램 종료 동작을 유지한다. 감독 루프의 terminal 입력은 짧은 timeout으로 확인해 입력 대기 때문에 중단이나 읽기 시간 제한 처리가 막히지 않게 한다.

고장 디스크가 `TASK_UNINTERRUPTIBLE` 상태의 kernel I/O 대기에 있으면 signal만으로 즉시 종료되지 않을 수 있다. 원 명세의 “어떠한 상황에서도 즉시 종료하며 프로세스가 남지 않음”은 이 조건까지 보장할 수 없으므로, 정상 상태의 완료 기준과 커널 대기의 예외를 구분한다. 이 예외에서도 새로운 읽기를 시작하지 않는 것이 필수다. [Linux kernel 대기 동작 문서](https://docs.kernel.org/scheduler/completion.html)

| 오류 | 대응 |
| --- | --- |
| 일반 사용자로 Locate 실행 | raw device를 열기 전에 root 필요 안내 |
| Serial 없음 또는 중복 | 읽기 없이 오류 종료 |
| 장치 없음, 파티션 또는 일반 파일 | 읽기 없이 거부 |
| 장치 제거 또는 식별 정보 변경 | 새 burst 중단, 자식 정리 |
| read error 또는 short read | 재시도 없이 중단 |
| direct I/O 불가 | buffered fallback 없이 중단 |
| burst 시간 초과 | 중단 절차, 종료 지연 시 PID 표시 |
| ZFS 조회 실패 | `UNKNOWN`과 원인 표시. 상태 변경 명령 없음 |

`conv=noerror`로 오류를 무시하거나 디스크 재탐색 후 자동 재시작하지 않는다. stderr의 읽기 오류는 숨기지 않되, 디스크 내용 자체는 출력하지 않는다.

## 9. 구현 순서와 단계별 검증

| 단계 | 구현 내용 | 검증 및 통과 조건 |
| --- | --- | --- |
| 1. 기본 환경 확인 | 24.10의 Bash, GNU dd 옵션, lsblk 컬럼, zpool 경로·출력을 확인하고 문서에 기록 | 추가 설치 없이 필요한 명령이 동작. FD 입력의 direct burst read가 가능 |
| 2. 조회 전용 CLI | `--help`, `--version`, `list`, Serial 선택, ZFS 파티션 매핑 | 실제 Serial과 정확히 대조. alias 중복을 병합하고 모호한 Serial을 거부. Locate I/O는 아직 없음 |
| 3. 조회 전용 TUI | 인자 없는 실행, 번호 선택, 상세 확인, 새로고침, 종료 | 선택만으로 읽기 없음. 잘못된 번호와 선택 후 장치 변경 처리. 일반 사용자 조회 가능 |
| 4. 제한된 읽기 | root 확인, 읽기 전용 FD, direct burst, 설정 범위 검증 | output이 `/dev/null`로 고정. TUI와 CLI에 같은 검증 적용 |
| 5. 종료와 오류 | 자식 PID 관리, signal, 읽기 시간 제한, TUI 작업 상태 및 목록 복귀 | 정상 중단 시험에서 1초 내 자식 정리. 정리 전 새 작업 금지. 오류 후 재시도 없음 |
| 6. TrueNAS 실기 검증 | 실제 LED 패턴, ONLINE 및 이미 OFFLINE인 장치, SSH/Shell 메뉴 사용 | 추가 설치 없음. 대상 LED 식별 가능. OFFLINE 유지. TUI 반복 사용 후 입력 정상 |
| 7. 배포 문서 | README 사용법, 기본 도구 결과, 검증한 환경·한계 작성 | 파일 하나를 복사해 실행 가능. 검증되지 않은 환경을 구분해 기록 |

후속 구현도 문서 변경을 먼저 반영한 뒤 진행한다. 한 단계의 실패가 확인되면 필요한 설계만 수정하고, 미확인 부분을 지원한다고 선언하지 않는다.

예정 파일 구성:

```text
README.md
disk-locate
docs/PLAN.md
tests/run.sh
tests/fixtures/
```

실행 코드는 `disk-locate` 하나에 두고, 테스트와 fixture는 개발 및 검증에만 사용한다.

## 10. 검증 방법

### 개발 환경 검증

- `bash -n`으로 syntax 확인.
- fixture로 by-id alias, 중복·누락 Serial, Model의 공백·escape, by-partuuid, OFFLINE, GUID만 남은 vdev, zpool 조회 실패 검증.
- 호출 기록을 통해 모든 읽기의 출력이 `/dev/null`이며 ZFS 변경 명령이 없는지 검증.
- shell metacharacter 및 임의 dd 인자를 넣어도 명령 실행이나 출력 대상 변경이 일어나지 않는지 검증.
- 읽기 중과 sleep 중에 각각 INT/TERM/HUP을 보내 자식 정리와 다음 burst 금지를 검증.
- 실패·short read·timeout·장치 식별 변경을 재현해 재시도하지 않는지 검증.
- PTY에서 목록 선택, 상세 확인, `r`, `b`, `q`, 빈 입력, 잘못된 번호와 non-TTY 실행을 검증.
- 선택 이후 목록 순서가 바뀌거나 디스크가 교체되어도 같은 번호의 다른 디스크에서 읽지 않는지 검증.
- 식별 중 `q`와 Ctrl+C가 목록으로 돌아가고, TERM/HUP은 종료하는지 검증. 여러 디스크를 차례로 식별해 이전 자식·FD·중단 flag가 다음 작업에 남지 않는지 확인.
- 중단 및 오류 뒤 terminal echo와 입력이 복구되고 일반 텍스트 메뉴도 사용 가능한지 검증.
- Linux의 격리된 폐기 가능 시험 장치에서 열린 FD가 유지되는지, 내용이 변경되지 않는지 검증. 개발용 도구는 NAS 배포 의존성에 포함하지 않음.

### 실제 TrueNAS 24.10 검증

1. 변경 없는 사전 확인으로 기본 도구와 실제 `lsblk`, `zpool status -LP` 형태를 기록한다.
2. 상태를 알고 있는 디스크의 Serial과 출력 정보를 비교한다.
3. 8 MiB burst부터 짧게 실행해 LED가 대상 베이에서 식별되는지 확인한다.
4. SSH와 TrueNAS Shell에서 번호 선택, 상세 확인, 식별, 목록 복귀를 반복한다. `q`, Ctrl+C, SIGTERM을 시험하고 실행 자식이 남지 않았는지 확인한다.
5. 운영자가 이미 OFFLINE 처리한 디스크로 반복하고, 종료 후 `zpool status`에서 OFFLINE 유지 확인.
6. 제거·오류 시험은 운영 Pool의 디스크를 뽑아 재현하지 않고 fixture 또는 별도 폐기 가능 시험 장치에서 수행한다.
7. dataset 경로에서 재부팅 후 실행을 확인하고, 이후 TrueNAS 업데이트 시 호환성을 재확인한다.

전체 시스템의 write counter가 0이라는 조건은 다른 workload 때문에 검증 기준으로 사용하지 않는다. 테스트 장치의 전후 내용 비교와 프로그램의 쓰기 경로 부재를 함께 검증한다.

현재 작업 환경은 macOS이며 실제 NAS에 접속하지 않았다. Linux raw device 동작, TrueNAS 기본 도구, 실제 signal 지연, LED 패턴은 이 계획 작성만으로 검증된 항목이 아니다.

## 11. v1 완료 기준

- 확인된 TrueNAS 24.10에서 추가 패키지와 Developer Mode 없이 파일 하나로 실행된다.
- 인자 없이 TUI가 열리고 번호 선택, 상세 확인, 식별 시작, 중단, 목록 복귀를 반복할 수 있다.
- 기존 CLI 명령은 TUI 진입 없이 동작하며 같은 디스크 검증과 읽기 함수를 사용한다.
- TUI 번호는 화면의 디스크 정보에 연결되어 있고 새로고침이나 장치 교체 후 다른 디스크로 자동 선택되지 않는다.
- 목록과 실행 전 화면에서 Device, Size, Model, Serial, WWN, Pool, leaf vdev State, 가능한 by-id를 확인할 수 있다.
- Serial의 정확한 일치와 중복 검증을 거쳐 유일한 디스크를 선택한다.
- `/dev/sdX` 직접 선택에도 동일한 장치 검증과 정보 출력을 적용한다.
- 디스크 FD는 읽기 전용이며 `/dev/null` 이외의 output을 선택하는 인터페이스가 없다.
- ZFS OFFLINE 디스크도 읽을 수 있으면 식별 가능하고 ZFS 관리 상태는 변경하지 않는다.
- 사용자 환경에서 Activity LED의 읽기/휴지 패턴으로 대상 베이를 식별할 수 있다.
- 정상적인 I/O에서 `q`, Ctrl+C 및 종료 signal 후 1초 이내 읽기 작업을 정리하고 자식이 남지 않는다. TUI의 작업 중단은 목록으로 복귀하고 CLI 및 TERM/HUP은 프로그램을 종료한다.
- 종료와 오류 후 terminal 입력 및 echo가 정상이며 kernel I/O 대기 자식이 남은 상태에서 새 작업을 시작하지 않는다.
- 장치 소실, 식별 변경, 읽기 오류, short read, timeout 후 새 읽기를 실행하지 않는다.
- kernel I/O 대기로 정리가 지연되면 성공으로 숨기지 않고 남은 PID를 표시한다.

## 12. 구현 범위에서 제외하는 기능

ZFS offline/online/detach/replace, disk wipe/format, partition 변경, SMART test/repair, SES/RAID LED 제어, TrueNAS Web UI 통합, Custom App, 자동 시작 및 background service는 만들지 않는다.

디스크 분리나 교체는 운영자가 Locate 종료와 ZFS 상태를 확인한 뒤 TrueNAS의 기존 관리 절차로 수행한다. 이 도구의 LED 출력만으로 교체 가능 여부를 판단하지 않는다.
