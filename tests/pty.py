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
    print(f"\nPTY/signal 통과 {sum(results)} / 실패 {len(results) - sum(results)}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
