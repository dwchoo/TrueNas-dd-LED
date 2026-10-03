# 검증 기록

작성일: 2026-10-03

검증한 프로그램 버전은 `0.1.0`이며 개발 환경은 macOS다. Bash 구문 검사와 기능 회귀 25개, PTY 검증 11개가 통과했다. 현재 실제 TrueNAS SCALE ElectricEel 24.10에 접속해 검증하지 않았다. fixture와 모의 명령을 사용하는 자동검증은 Linux raw device 동작 및 실제 Activity LED 확인을 대신하지 않는다.

## 개발 환경 자동검증

저장소 루트에서 다음 명령을 실행했다. 모두 exit status `0`으로 종료했으며 두 테스트의 합계는 36개다. Python 3는 개발 환경의 PTY 검증에만 사용한다. 테스트용 코드와 도구는 NAS 배포물에 포함하지 않으며, NAS에는 `disk-locate` 파일 하나만 복사한다.

```bash
/bin/bash -n disk-locate
/bin/bash tests/run.sh
python3 tests/pty.py
```

기능 회귀는 fixture와 경계 함수 mock을 사용한다. `dd` 인자 검증은 실제 `launch_burst`를 호출하되 실제 `dd` 실행을 차단하고, 입력 FD를 `/dev/null`로 대체해 호출을 기록했다. PTY 검증도 실제 raw device 대신 추적할 수 있는 `sleep` 자식과 모의 FD offset을 사용했다. 실제 raw device를 여는 root 실행, 디스크 FD 유지 및 direct I/O는 이 검사로 검증하지 않았다.

| 항목 | 확인 내용 | 상태 |
| --- | --- | --- |
| Bash syntax | `/bin/bash -n disk-locate`로 구문 확인 | 통과 |
| CLI와 옵션 | 실제 도움말·버전·잘못된 옵션·non-TTY 거부 호출, read size와 interval 범위 검증 | 통과 |
| 권한 확인 | 실제 일반 사용자 실행에서 FD open 전에 root 필요 안내와 거부 | 통과 |
| 디스크 목록과 선택 | 정확한 Serial 일치, 중복·누락 Serial 거부, alias, 공백·escape 및 terminal 제어 문자 처리 | 모의 검증 통과 |
| ZFS 매핑 | 파티션·by-partuuid의 전체 디스크 연결, OFFLINE·다중 Pool 표시, GUID 및 조회 실패의 UNKNOWN 처리 | 모의 검증 통과 |
| 읽기 명령 | 실제 `launch_burst`의 `dd` 인자와 입력 FD 3 사용, `/dev/null` 출력 고정, 사용자 입력의 명령 실행 방지, ZFS 조회 명령만 호출 | 모의 검증 통과 |
| 장치 재검증 | snapshot과 다른 장치 정보·장치 번호·경로·소실 거부, 재검증 중 INT 수신 후 burst 0회 | 모의 검증 통과 |
| 오류 중단 | read error·short read 이후 재시도 금지, burst timeout, kernel I/O 대기 자식이 남는 상황의 정리 처리 | 모의 검증 통과 |
| 프로세스 정리 | CLI 읽기·휴지 중 INT/TERM/HUP으로 추적한 자식 정리 및 다음 burst 금지, 종료 코드 130/143/129 | 모의 검증 통과 |
| TUI 조작 | PTY에서 번호·잘못된 번호·빈 입력·`r`·`b`·`q`·Ctrl+C와 두 Serial의 반복 선택, 종료 뒤 ECHO 복구 | 모의 검증 통과 |
| TUI 작업 중단 | 식별 중 `q`와 Ctrl+C 후 목록 복귀·다음 디스크 선택, TERM/HUP은 목록 복귀 없이 프로그램 종료 | 모의 검증 통과 |

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
| OFFLINE 유지 | 운영자가 이미 OFFLINE 처리한 장치에서 식별하고 전후 `zpool status`가 OFFLINE 유지 | 미실행 |
| 배포 경로 보존 | 영속 dataset의 파일로 실행하고 재부팅 후 파일 및 실행 가능 여부 확인 | 미실행 |

오류·장치 제거 시험은 운영 Pool의 디스크를 분리해 재현하지 않는다. fixture 또는 별도 폐기 가능 시험 장치로 검증한다. TrueNAS 업데이트 후에는 기본 도구 및 실행 호환성을 다시 확인한다.

정상 I/O에서 1초 이내 중단과 자식 정리를 확인하는 것을 목표로 한다. 고장 장치가 kernel의 중단 불가능한 I/O 대기에 있으면 종료 signal에도 프로세스가 남을 수 있다. 이때 새 읽기를 중단하고 남은 PID를 표시하는지 따로 확인해야 한다.
