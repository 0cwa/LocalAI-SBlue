#!/usr/bin/env python3
"""Small KDE-friendly tray controller for the configured LocalAI stack."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from PyQt6.QtCore import QObject, QProcess, QTimer, QUrl, pyqtSignal
from PyQt6.QtGui import QAction, QDesktopServices, QIcon
from PyQt6.QtNetwork import QLocalServer, QLocalSocket
from PyQt6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from adapter import (
    command_args,
    display_state,
    endpoint,
    has_unavailable_manager,
    parse_status,
    stack_healthy,
)


COMMAND_TIMEOUT_MS = 15_000


class ServiceController(QObject):
    """Invoke only the repository's allowlisted localaictl façade."""

    finished = pyqtSignal(str, bool, object, str)

    def __init__(self, parent: object | None = None) -> None:
        super().__init__(parent)
        default_ctl = Path(__file__).with_name("localaictl")
        self.control = os.environ.get("LOCALAI_CONTROL_BIN", str(default_ctl))
        self._process: QProcess | None = None
        self._operation = ""
        self._timer = QTimer(parent)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self._timed_out)

    @property
    def busy(self) -> bool:
        return self._process is not None

    def run(self, operation: str) -> bool:
        if self.busy:
            return False
        process = QProcess()
        process.setProcessChannelMode(QProcess.ProcessChannelMode.SeparateChannels)
        process.finished.connect(self._finished)
        process.errorOccurred.connect(self._error)
        self._process = process
        self._operation = operation
        try:
            args = command_args(operation)
        except ValueError as error:
            self._finish(False, None, str(error))
            return False
        process.start(self.control, args)
        self._timer.start(COMMAND_TIMEOUT_MS)
        return True

    def _finish(self, ok: bool, status: object, output: str) -> None:
        process = self._process
        if process is None:
            return
        self._timer.stop()
        operation = self._operation
        self._process = None
        self._operation = ""
        process.deleteLater()
        self.finished.emit(operation, ok, status, output.strip())

    def _finished(self, exit_code: int, _status: QProcess.ExitStatus) -> None:
        process = self._process
        if process is None:
            return
        stdout = bytes(process.readAllStandardOutput()).decode(errors="replace")
        stderr = bytes(process.readAllStandardError()).decode(errors="replace")
        output = "\n".join(part for part in (stdout, stderr) if part.strip())
        if self._operation == "status":
            try:
                parsed = parse_status(stdout)
            except (ValueError, TypeError) as error:
                self._finish(False, None, str(error) if not output else output)
            else:
                # status intentionally remains usable when localaictl exits 1
                # because a component is unhealthy; its JSON is still useful.
                self._finish(True, parsed, output)
            return
        self._finish(exit_code == 0, None, output or ("ok" if exit_code == 0 else "command failed"))

    def _error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.ProcessError.FailedToStart:
            self._finish(False, None, f"Could not start {self.control}.")

    def _timed_out(self) -> None:
        process = self._process
        if process is None:
            return
        process.kill()
        self._finish(False, None, "The LocalAI control command timed out.")


class LocalAITray(QSystemTrayIcon):
    def __init__(self, app: QApplication, start_requested: bool) -> None:
        icon_path = Path(__file__).with_name("localai.svg")
        super().__init__(QIcon(str(icon_path)), app)
        self.setToolTip("LocalAI")
        self._app = app
        self._start_requested = start_requested
        self._status: dict[str, object] | None = None
        self._controller = ServiceController(self)
        self._controller.finished.connect(self._command_finished)

        self._status_action = QAction("LocalAI: Checking…", self)
        self._status_action.setEnabled(False)
        self._start_action = QAction("Start LocalAI stack", self)
        self._start_action.triggered.connect(self.start_service)
        self._stop_action = QAction("Stop LocalAI stack", self)
        self._stop_action.triggered.connect(self.stop_service)
        self._open_action = QAction("Open LocalAI Web UI", self)
        self._open_action.triggered.connect(self.open_web_ui)
        self._quit_stop_action = QAction("Quit and stop LocalAI stack", self)
        self._quit_stop_action.triggered.connect(self.quit_and_stop)
        self._exit_action = QAction("Exit tray (leave services running)", self)
        self._exit_action.triggered.connect(self._app.quit)

        menu = QMenu()
        menu.addAction(self._status_action)
        menu.addSeparator()
        menu.addAction(self._start_action)
        menu.addAction(self._stop_action)
        menu.addAction(self._open_action)
        menu.addSeparator()
        menu.addAction(self._quit_stop_action)
        menu.addAction(self._exit_action)
        self.setContextMenu(menu)

        self._poll_timer = QTimer(self)
        self._poll_timer.setInterval(2500)
        self._poll_timer.timeout.connect(self.refresh)
        self._poll_timer.start()
        self.show()
        QTimer.singleShot(0, self.refresh)

    def _set_status(self, status: dict[str, object] | None) -> None:
        self._status = status
        if status is None:
            text = "Backend: unavailable · TLS: unavailable · HTTPS: unavailable"
            healthy = False
            endpoint_text = "configuration unavailable"
            access_hint = ""
        else:
            backend = display_state(status.get("backend", "unknown"))
            tls = display_state(status.get("tls_compose", "disabled"))
            socket = display_state(status.get("https_socket", "disabled"))
            text = f"Backend: {backend} · TLS: {tls} · HTTPS: {socket}"
            healthy = stack_healthy(status)
            endpoint_text = str(status.get("endpoint", "unavailable"))
            access_hint = ""
            if has_unavailable_manager(status):
                access_hint = (
                    f"\nService-manager status is unavailable to the tray. "
                    f"Run {self._controller.control} status --elevated in a terminal for details."
                )
        self._status_action.setText(text)
        self.setToolTip(f"LocalAI — {text}\n{endpoint_text}{access_hint}")
        self._start_action.setEnabled(not self._controller.busy and not healthy)
        self._stop_action.setEnabled(not self._controller.busy and status is not None)
        self._quit_stop_action.setEnabled(not self._controller.busy)

    def refresh(self) -> None:
        if not self._controller.busy:
            self._controller.run("status")

    def start_service(self) -> None:
        if self._controller.run("start"):
            self._start_requested = False

    def stop_service(self) -> None:
        self._controller.run("stop")

    def quit_and_stop(self) -> None:
        if self._controller.busy:
            return
        self._start_requested = False
        self._quit_after_stop = True
        self.stop_service()

    def open_web_ui(self) -> None:
        try:
            url = endpoint(self._status or {})
        except ValueError as error:
            self._show_error("LocalAI endpoint unavailable", str(error))
            return
        QDesktopServices.openUrl(QUrl(url))

    def handle_message(self, message: bytes) -> None:
        if message.strip() == b"start":
            self._start_requested = True
            if not self._controller.busy:
                self.refresh()

    def _command_finished(self, operation: str, ok: bool, status: object, output: str) -> None:
        if operation == "status":
            parsed = status if isinstance(status, dict) else None
            self._set_status(parsed)
            if self._start_requested and parsed is not None and not stack_healthy(parsed):
                self._start_requested = False
                self.start_service()
            return
        if ok:
            if operation == "stop" and getattr(self, "_quit_after_stop", False):
                self._app.quit()
            self.refresh()
            return
        self._set_status(self._status)
        self._show_error(f"Could not {operation} LocalAI stack", output or "The control command failed.")

    def _show_error(self, title: str, detail: str) -> None:
        QMessageBox.critical(None, title, detail)


def signal_existing(name: str, command: bytes) -> bool:
    probe = QLocalSocket()
    probe.connectToServer(name)
    if not probe.waitForConnected(100):
        return False
    if command:
        probe.write(command)
        probe.waitForBytesWritten(250)
    probe.disconnectFromServer()
    return True


def single_instance(name: str, command: bytes) -> QLocalServer | None:
    if signal_existing(name, command):
        return None
    QLocalServer.removeServer(name)
    server = QLocalServer()
    if not server.listen(name):
        return None
    return server


def main() -> int:
    parser = argparse.ArgumentParser(description="Control the configured LocalAI stack from the system tray.")
    parser.add_argument("--start", action="store_true", help="start the LocalAI stack after the tray appears")
    args = parser.parse_args()

    app = QApplication(sys.argv)
    app.setApplicationName("LocalAI Tray")
    app.setQuitOnLastWindowClosed(False)
    if not QSystemTrayIcon.isSystemTrayAvailable():
        QMessageBox.critical(None, "LocalAI", "No system tray is available in this desktop session.")
        return 1

    name = f"localai-tray-{os.getuid()}"
    server = single_instance(name, b"start\n" if args.start else b"")
    if server is None:
        return 0
    try:
        tray = LocalAITray(app, args.start)
    except (OSError, RuntimeError) as error:
        QMessageBox.critical(None, "LocalAI", str(error))
        return 1

    def receive_message() -> None:
        connection = server.nextPendingConnection()
        if connection is None:
            return
        connection.readyRead.connect(lambda: tray.handle_message(bytes(connection.readAll())))

    server.newConnection.connect(receive_message)
    tray._instance_server = server
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
