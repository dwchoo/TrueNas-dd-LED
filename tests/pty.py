#!/usr/bin/env python3
"""개발용 PTY/signal 회귀 시험. Python은 NAS 실행 의존성이 아니다."""

import errno
import os
from pathlib import Path
import re
import select
import signal
import sys
import tempfile
import termios
import time


PROJECT = Path(__file__).resolve().parent.parent
BASH = os.environ.get("TEST_BASH", "/bin/bash")


class Session:
    def __init__(self, directory, args=(), mode="full", burst_sleep="5"):
        self.directory = Path(directory)
        self.trace = self.directory / "children.log"
        self.pending = ""
        self.transcript = ""
        self.status = None
        environment = dict(os.environ)
        environment.update(
            TERM="dumb",
            DISK_TEST_PROGRAM=str(PROJECT / "disk-locate"),
            DISK_TEST_FIXTURES=str(PROJECT / "tests" / "fixtures"),
            DISK_TEST_POSITION=str(self.directory / "position"),
            DISK_TEST_TRACE=str(self.trace),
            DISK_TEST_MODE=mode,
            DISK_TEST_SLEEP=burst_sleep,
        )
        self.pid, self.fd = os.forkpty()
        if self.pid == 0:
            launcher = str(PROJECT / "tests" / "pty-runtime.sh")
            os.execve(BASH, [BASH, launcher, *args], environment)

    def read(self, timeout=0.1):
        if select.select([self.fd], [], [], timeout)[0]:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            decoded = chunk.decode("utf-8", "replace")
            self.pending += decoded
            self.transcript += decoded
        result, status = os.waitpid(self.pid, os.WNOHANG) if self.status is None else (0, 0)
        if result:
            self.status = os.waitstatus_to_exitcode(status)

    def expect(self, pattern, timeout=7):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = re.search(pattern, self.pending)
            if match:
                self.pending = self.pending[match.end():]
                return match.group(0)
            self.read()
            if self.status is not None:
                break
        raise AssertionError(f"출력 대기 실패: {pattern!r}\n{self.transcript[-2500:]}")

    def send(self, text):
        os.write(self.fd, text.encode())

    def launched(self):
        if not self.trace.exists():
            return []
        return [(int(parts[1]), parts[2] if len(parts) > 2 else "")
                for line in self.trace.read_text().splitlines()
                if (parts := line.split()) and parts[0] == "CHILD"]

    def assert_children_gone(self):
        tracked = set()
        if self.trace.exists():
            for line in self.trace.read_text().splitlines():
                parts = line.split()
                if parts and parts[0] in ("CHILD", "SEEN"):
                    tracked.add(int(parts[1]))
        for pid in tracked:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            raise AssertionError(f"읽기 모의 자식이 남음: {pid}")

    def wait_exit(self, timeout=3):
        deadline = time.monotonic() + timeout
        while self.status is None and time.monotonic() < deadline:
            self.read()
        if self.status is None:
            raise AssertionError(f"프로그램 종료 지연\n{self.transcript[-2000:]}")
        self.assert_children_gone()
        if not termios.tcgetattr(self.fd)[3] & termios.ECHO:
            raise AssertionError("종료 후 terminal echo가 꺼져 있음")
        return self.status

    def close(self):
        if self.status is None:
            try:
                os.killpg(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(self.pid, 0)
        for pid, _serial in self.launched():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(self.fd)


def menu(session):
    session.expect(r"Disk Locator")
    session.expect(r"번호.*입력")


def detail(session, number):
    session.send(f"{number}\n")
    session.expect(r"Device")
    session.expect(r"\[b\].*목록")


def tui_sequence(session):
    menu(session)
    session.send("\n")
    session.read(0.05)
    if session.status is not None or session.launched():
        raise AssertionError("빈 입력으로 종료하거나 읽기를 시작함")
    session.send("0\n")
    session.expect(r"번호.*입력")
    session.send("r\n")
    session.expect(r"번호.*입력")
    detail(session, 1)
    if session.launched():
        raise AssertionError("번호 선택만으로 읽기가 시작됨")
    session.send("b")
    menu(session)
    detail(session, 1)
    session.send("s")
    session.expect(r"식별 시작")
    session.expect(r"읽는 중")
    start = time.monotonic()
    session.send("q")
    session.expect(r"식별 중단", timeout=3)
    menu(session)
    if time.monotonic() - start > 2:
        raise AssertionError("q 처리 후 목록 복귀에 2초 이상 소요")
    session.assert_children_gone()
    detail(session, 2)
    session.send("s")
    session.expect(r"식별 시작")
    session.expect(r"읽는 중")
    session.send("\x03")
    session.expect(r"식별 중단", timeout=3)
    menu(session)
    session.assert_children_gone()
    serials = [serial for _pid, serial in session.launched()]
    if serials != ["SN-A", "SN-B"]:
        raise AssertionError(f"반복 선택 대상이 다름: {serials}")
    session.send("q\n")
    if session.wait_exit() != 0:
        raise AssertionError("목록 q 종료가 실패함")


def signal_case(session, signum, phase):
    session.expect(r"식별 시작")
    session.expect("읽는 중" if phase == "read" else "쉬는 중", timeout=8)
    if phase == "read":
        deadline = time.monotonic() + 3
        while not session.launched() and time.monotonic() < deadline:
            session.read(0.02)
        if not session.launched():
            raise AssertionError("읽기 자식이 시작되지 않음")
    before = len(session.launched())
    os.kill(session.pid, signum)
    status = session.wait_exit()
    if status != 128 + signum:
        raise AssertionError(f"signal 종료 코드가 다름: {status}")
    if len(session.launched()) != before:
        raise AssertionError("종료 signal 이후 새 읽기가 시작됨")


def tui_shutdown(session, signum):
    menu(session)
    detail(session, 1)
    session.send("s")
    session.expect(r"식별 시작")
    session.expect(r"읽는 중")
    deadline = time.monotonic() + 3
    while not session.launched() and time.monotonic() < deadline:
        session.read(0.02)
    if not session.launched():
        raise AssertionError("읽기 자식이 시작되지 않음")
    os.kill(session.pid, signum)
    if session.wait_exit() != 128 + signum:
        raise AssertionError("TUI 종료 signal이 올바른 종료 코드로 끝나지 않음")
    if "Disk Locator" in session.pending:
        raise AssertionError("TUI 종료 signal이 목록으로 복귀함")
    if len(session.launched()) != 1:
        raise AssertionError("TUI 종료 signal 이후 읽기가 다시 시작됨")


def failure_case(session):
    session.expect(r"식별 시작")
    status = session.wait_exit(timeout=7)
    if status == 0:
        raise AssertionError("읽기 실패를 성공 종료로 표시함")
    if len(session.launched()) != 1:
        raise AssertionError("읽기 오류 뒤 재시도 또는 읽기 미실행")


def wait_launches(session, expected):
    deadline = time.monotonic() + 3
    while len(session.launched()) < expected and time.monotonic() < deadline:
        session.read(0.02)
    if len(session.launched()) != expected:
        raise AssertionError(f"읽기 횟수가 다름: {session.launched()}")


def duration_restart(session):
    menu(session)
    detail(session, 1)
    session.send("s")
    session.expect(r"식별 시작")
    session.expect(r"남은 3초")
    session.expect(r"남은 [12]초")
    session.expect(r"남은 0초", timeout=5)
    session.expect(r"\[s\] 다시 3초 식별")
    session.assert_children_gone()
    wait_launches(session, 1)
    session.read(0.2)
    if len(session.launched()) != 1:
        raise AssertionError("시간 만료 후 자동으로 읽기를 다시 시작함")
    session.send("s")
    session.expect(r"식별 시작")
    session.expect(r"남은 3초")
    wait_launches(session, 2)
    if [serial for _pid, serial in session.launched()] != ["SN-A", "SN-A"]:
        raise AssertionError("재시작 대상이 바뀜")
    session.send("q")
    menu(session)
    session.assert_children_gone()
    session.send("q")
    if session.wait_exit() != 0:
        raise AssertionError("재시작 작업 정리 후 종료 실패")


def duration_rest(session):
    menu(session)
    detail(session, 1)
    session.send("s")
    session.expect(r"쉬는 중.*남은 [123]초")
    session.expect(r"쉬는 중.*남은 [12]초")
    session.expect(r"\[s\] 다시 3초 식별", timeout=6)
    session.assert_children_gone()
    wait_launches(session, 1)
    session.send("b")
    menu(session)
    session.send("2\n")
    session.expect(r"Device")
    session.expect(r"\[s\] 3초 식별 시작")
    session.expect(r"\[b\].*목록")
    session.send("q")
    if session.wait_exit() != 0:
        raise AssertionError("휴지 시간 만료 후 종료 실패")


def duration_cli(session):
    session.expect(r"식별 시작")
    if session.wait_exit(timeout=6) != 0:
        raise AssertionError("CLI 전체 시간 만료가 실패로 종료됨")
    if "식별 시간 제한(3초) 도달" not in session.transcript:
        raise AssertionError("CLI 전체 시간 만료 사유가 없음")
    if len(session.launched()) != 1:
        raise AssertionError("시간 만료 뒤 새 burst 시작")


def idle_exit(session, screen):
    menu(session)
    if screen == "detail":
        detail(session, 1)
    elif screen == "settings":
        session.send("t")
        session.expect(r"시간 설정 \(이번 실행에만 적용\)")
        session.send("1\n")
        session.expect(r"새 값 입력")
    os.kill(session.pid, signal.SIGUSR1)
    session.expect(r"30분 경과: 자동 종료", timeout=4)
    if session.wait_exit() != 0 or session.launched():
        raise AssertionError("유휴 종료 시 읽기 실행 또는 오류 발생")


def settings_case(session):
    menu(session)
    session.send("t")
    session.expect(r"시간 설정 \(이번 실행에만 적용\)")
    session.send("1\n")
    session.expect(r"새 값 입력.*1440분")
    session.send("0\n")
    session.expect(r"설정은 변경되지 않았습니다")
    session.expect(r"유휴 자동 종료: 30분")
    session.send("1\n")
    session.expect(r"새 값 입력")
    session.send("15\n")
    session.expect(r"유휴 자동 종료: 15분")
    session.send("2\n")
    session.expect(r"새 값 입력.*3600초")
    session.send("3\n")
    session.expect(r"식별 1회 최대 시간: 3초")
    session.send("b")
    session.expect(r"유휴 자동 종료: 15분.*식별 1회: 3초")
    session.expect(r"번호.*입력")
    detail(session, 1)
    session.send("s")
    session.expect(r"남은 3초")
    session.expect(r"\[s\] 다시 3초 식별", timeout=6)
    session.assert_children_gone()
    session.send("q")
    if session.wait_exit() != 0:
        raise AssertionError("TUI 시간 변경 후 종료 실패")


def idle_key_reset(session):
    menu(session)
    os.kill(session.pid, signal.SIGUSR2)
    session.read(0.1)
    session.send("x")  # 메뉴 동작이 없는 키도 실제 입력으로 유휴 시간을 초기화한다.
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        session.read(0.1)
        if session.status is not None:
            raise AssertionError("일반 키 입력 후 이전 유휴 만료 시간이 적용됨")
    os.kill(session.pid, signal.SIGUSR1)
    session.expect(r"30분 경과: 자동 종료", timeout=4)
    if session.wait_exit() != 0:
        raise AssertionError("새 유휴 시간 만료가 정상 종료되지 않음")


def run_case(label, callback, args=(), mode="full", burst_sleep="5"):
    with tempfile.TemporaryDirectory(prefix="disk-locate-pty-") as directory:
        session = Session(directory, args, mode, burst_sleep)
        try:
            callback(session)
            print(f"PASS {label}")
            return True
        except (AssertionError, OSError) as error:
            print(f"FAIL {label}: {error}", file=sys.stderr)
            return False
        finally:
            session.close()


def main():
    results = [run_case("TUI 선택/새로고침/뒤로/q/Ctrl+C/다음 디스크", tui_sequence)]
    for signum in (signal.SIGTERM, signal.SIGHUP):
        results.append(run_case(
            f"TUI {signal.Signals(signum).name} 작업 정리 후 종료",
            lambda session, s=signum: tui_shutdown(session, s),
        ))
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        for phase in ("read", "rest"):
            results.append(run_case(
                f"CLI {signal.Signals(signum).name} ({phase}) 자식 정리",
                lambda session, s=signum, p=phase: signal_case(session, s, p),
                args=("--interval", "10", "SN-A"),
                burst_sleep="5" if phase == "read" else "0.05",
            ))
    for mode in ("short", "error"):
        results.append(run_case(
            f"CLI {mode} 읽기 실패 후 재시도 금지", failure_case,
            args=("SN-A",), mode=mode, burst_sleep="0.05",
        ))
    results.append(run_case(
        "TUI 읽기 중 전체 시간 만료/countdown/s 명시적 재시작", duration_restart,
        args=("--duration", "3"),
    ))
    results.append(run_case(
        "TUI 휴지 중 시간 만료와 다른 디스크의 만료 상태 초기화", duration_rest,
        args=("--duration", "3", "--interval", "10"), burst_sleep="0.05",
    ))
    for burst_sleep in ("5", "0.05"):
        results.append(run_case(
            f"CLI 전체 시간 만료 정상 종료 ({burst_sleep})", duration_cli,
            args=("--duration", "3", "--interval", "10", "SN-A"),
            burst_sleep=burst_sleep,
        ))
    for screen in ("list", "detail", "settings"):
        results.append(run_case(
            f"TUI {screen} 화면의 30분 유휴 자동 종료",
            lambda session, s=screen: idle_exit(session, s),
        ))
    results.append(run_case("TUI 시간 설정과 잘못된 값 유지", settings_case))
    results.append(run_case("TUI 일반 키 입력 후 유휴 만료 시간 초기화", idle_key_reset))
    print(f"\nPTY/signal 통과 {sum(results)} / 실패 {len(results) - sum(results)}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
