#!/usr/bin/env python3
"""Small KDE-friendly tray controller for the configured LocalAI stack."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from PyQt6.QtCore import QObject, QProcess, QStandardPaths, QTimer, QUrl, pyqtSignal
from PyQt6.QtGui import QAction, QDesktopServices, QIcon
from PyQt6.QtNetwork import QLocalServer, QLocalSocket
from PyQt6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from adapter import (
    command_args,
    display_state,
    doctor_summary,
    endpoint,
    has_unavailable_manager,
    log_terminal_args,
    LOG_TERMINALS,
    menu_entries,
    open_logs_after_confirmation,
    parse_start_requested,
    parse_status,
    should_start_after_status,
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
        except ValueError:
            self._finish(False, None, "Unsupported LocalAI control action.")
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
            except (ValueError, TypeError):
                self._finish(False, None, "The LocalAI control command returned invalid status data.")
            else:
                # status intentionally remains usable when localaictl exits 1
                # because a component is unhealthy; its JSON is still useful.
                self._finish(True, parsed, "")
            return
        if self._operation == "doctor":
            # doctor output can include the effective endpoint. Reduce it to
            # a small classification before it reaches any tray presentation.
            self._finish(exit_code == 0, None, doctor_summary(output))
            return
        self._finish(exit_code == 0, None, "ok" if exit_code == 0 else "The LocalAI control command failed.")

    def _error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.ProcessError.FailedToStart:
            self._finish(False, None, "Could not start the LocalAI control command.")

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
        self._manager_action = QAction("", self)
        self._manager_action.setEnabled(False)
        self._manager_action.setVisible(False)
        self._doctor_action = QAction("Run endpoint health check", self)
        self._doctor_action.triggered.connect(self.run_doctor)
        self._open_action = QAction("Open LocalAI Web UI", self)
        self._open_action.triggered.connect(self.open_web_ui)
        self._copy_action = QAction("Copy effective endpoint", self)
        self._copy_action.triggered.connect(self.copy_endpoint)
        self._backend_logs_action = QAction("View backend logs…", self)
        self._backend_logs_action.triggered.connect(lambda: self.open_logs("backend"))
        self._tls_logs_action = QAction("View TLS logs…", self)
        self._tls_logs_action.triggered.connect(lambda: self.open_logs("tls"))
        self._start_action = QAction("Start LocalAI stack", self)
        self._start_action.triggered.connect(self.start_service)
        self._stop_action = QAction("Stop LocalAI stack", self)
        self._stop_action.triggered.connect(self.stop_service)
        self._quit_stop_action = QAction("Quit and stop LocalAI stack", self)
        self._quit_stop_action.triggered.connect(self.quit_and_stop)
        self._exit_action = QAction("Exit tray (leave services running)", self)
        self._exit_action.triggered.connect(self._app.quit)

        menu = QMenu()
        actions = {
            "status": self._status_action,
            "manager_help": self._manager_action,
            "doctor": self._doctor_action,
            "open_endpoint": self._open_action,
            "copy_endpoint": self._copy_action,
            "backend_logs": self._backend_logs_action,
            "tls_logs": self._tls_logs_action,
            "start": self._start_action,
            "stop": self._stop_action,
            "quit_stop": self._quit_stop_action,
            "exit": self._exit_action,
        }
        for item in menu_entries(actions):
            if item is None:
                menu.addSeparator()
            else:
                menu.addAction(item)
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
            self._manager_action.setVisible(False)
        else:
            backend = display_state(status.get("backend", "unknown"))
            tls = display_state(status.get("tls_compose", "disabled"))
            socket = display_state(status.get("https_socket", "disabled"))
            text = f"Backend: {backend} · TLS: {tls} · HTTPS: {socket}"
            healthy = stack_healthy(status)
            try:
                endpoint_text = endpoint(status)
            except ValueError:
                endpoint_text = "configuration unavailable"
            access_hint = ""
            if has_unavailable_manager(status):
                access_hint = "\nRun localaictl status --elevated in a terminal for manager details."
                self._manager_action.setText("Manager status unavailable · run localaictl status --elevated in a terminal")
                self._manager_action.setVisible(True)
            else:
                self._manager_action.setVisible(False)
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

    def copy_endpoint(self) -> None:
        try:
            url = endpoint(self._status or {})
        except ValueError:
            self._show_error("LocalAI endpoint unavailable", "The configured endpoint is not safe to display or copy.")
            return
        self._app.clipboard().setText(url)

    def run_doctor(self) -> None:
        self._controller.run("doctor")

    def open_logs(self, component: str) -> None:
        def confirm() -> bool:
            answer = QMessageBox.warning(
                None,
                f"Open {component} logs?",
                "Logs may contain secrets. They will be opened in a terminal and will not be shown in the tray. Review and sanitize them before sharing.",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel,
                QMessageBox.StandardButton.Cancel,
            )
            return answer == QMessageBox.StandardButton.Yes

        open_logs_after_confirmation(component, confirm, self._launch_logs_in_terminal)

    def _launch_logs_in_terminal(self, component: str) -> None:
        for terminal in LOG_TERMINALS:
            executable = QStandardPaths.findExecutable(terminal)
            if not executable:
                continue
            args = log_terminal_args(terminal, self._controller.control, component)
            started = QProcess.startDetached(executable, args)
            if isinstance(started, tuple):
                started = started[0]
            if started:
                return
        self._show_error("No terminal available", "Install or configure a supported terminal to view LocalAI logs.")

    def handle_message(self, message: bytes) -> None:
        if message.strip() == b"start":
            self._start_requested = True
            if not self._controller.busy:
                self.refresh()

    def _command_finished(self, operation: str, ok: bool, status: object, output: str) -> None:
        if operation == "status":
            parsed = status if isinstance(status, dict) else None
            self._set_status(parsed)
            if should_start_after_status(self._start_requested, parsed):
                self._start_requested = False
                self.start_service()
            return
        if operation == "doctor":
            self._show_information("LocalAI endpoint health", output)
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

    def _show_information(self, title: str, detail: str) -> None:
        QMessageBox.information(None, title, detail)


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
    start_requested = parse_start_requested(sys.argv[1:])

    app = QApplication(sys.argv)
    app.setApplicationName("LocalAI Tray")
    app.setQuitOnLastWindowClosed(False)
    if not QSystemTrayIcon.isSystemTrayAvailable():
        QMessageBox.critical(None, "LocalAI", "No system tray is available in this desktop session.")
        return 1

    name = f"localai-tray-{os.getuid()}"
    server = single_instance(name, b"start\n" if start_requested else b"")
    if server is None:
        return 0
    try:
        tray = LocalAITray(app, start_requested)
    except (OSError, RuntimeError):
        QMessageBox.critical(None, "LocalAI", "The LocalAI tray could not be initialized.")
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
