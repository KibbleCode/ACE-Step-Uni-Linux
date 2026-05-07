"""
ACE-Step Launcher — PySide6 edition (V7)

A Qt-based replacement for the tkinter launcher. Same functionality, but uses
Qt6 which has proper threading and doesn't fight libxcb on modern distros.

Features:
  - Launch WebUI button (starts API + opens HTML files in browser)
  - API server toggle with live status indicator
  - Gradio UI launch
  - Folder shortcuts (WebUI dir, generations dir)
  - Settings panel (skip LLM, terminal output)
  - Local HTTP config server (with CSRF token defense)
  - Cross-thread-safe via Qt signals/slots
"""

import sys
import os
import subprocess
import threading
import time
import json
import http.server
import socketserver
import socket
import secrets
import webbrowser
import urllib.request
import shutil
import struct
import platform
import signal
from pathlib import Path

import psutil

from PySide6.QtCore import (
    Qt, QTimer, QThread, Signal, QObject, QSize, QPropertyAnimation, QEasingCurve, QPoint
)
from PySide6.QtGui import (
    QIcon, QPixmap, QPainter, QColor, QPalette, QFont, QFontDatabase,
    QLinearGradient, QBrush, QCursor, QAction
)
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QPushButton, QLabel, QCheckBox, QFrame, QStatusBar, QSizePolicy,
    QGraphicsDropShadowEffect, QStyle, QStyleOption, QToolTip, QMessageBox
)

IS_LINUX = platform.system() == "Linux"
IS_MAC = platform.system() == "Darwin"
IS_WINDOWS = platform.system() == "Windows"


# ============================================================================
# PATHS
# ============================================================================
def _resolve_dirs():
    """Locate install dir + XDG dirs. Install dir is passed via env from ace-step.sh."""
    home = Path.home()
    install_dir = Path(os.environ.get("ACESTEP_INSTALL_DIR", home / ".local/share/ace-step"))
    data_dir = Path(os.environ.get("ACESTEP_DATA_DIR", install_dir / "data"))
    config_dir = Path(os.environ.get("ACESTEP_CONFIG_DIR", install_dir / "config"))
    cache_dir = Path(os.environ.get("ACESTEP_CACHE_DIR", install_dir / "cache"))
    for d in (data_dir, config_dir, cache_dir):
        d.mkdir(parents=True, exist_ok=True)
    return install_dir, data_dir, config_dir, cache_dir


INSTALL_DIR, DATA_DIR, CONFIG_DIR, CACHE_DIR = _resolve_dirs()
REPO_DIR = INSTALL_DIR / "repo"
VENV_DIR = INSTALL_DIR / "venv"
WEBUI_DIR = INSTALL_DIR / "webui"
GENERATIONS_DIR = DATA_DIR / "generations"
SETTINGS_FILE = CONFIG_DIR / "launcher_settings.json"
UI_CONFIG_FILE = CONFIG_DIR / "ui_config.json"

API_PORT = 8001
GRADIO_PORT = 7860
CONFIG_PORT = 8765

LAUNCHER_TOKEN = secrets.token_urlsafe(32)


# ============================================================================
# THEME — modern dark with blue accent
# ============================================================================
THEME = {
    "bg":            "#0e1117",
    "bg_elevated":   "#161b22",
    "bg_hover":      "#1f262f",
    "border":        "#30363d",
    "fg":            "#e6edf3",
    "fg_dim":        "#7d8590",
    "accent":        "#2f81f7",
    "accent_hover":  "#3a94ff",
    "accent_press":  "#1f6feb",
    "success":       "#3fb950",
    "danger":        "#f85149",
    "warning":       "#d29922",
}

QSS = f"""
QMainWindow, QWidget#central {{
    background-color: {THEME['bg']};
    color: {THEME['fg']};
}}

QLabel {{
    color: {THEME['fg']};
    background: transparent;
}}

QLabel#title {{
    color: {THEME['accent']};
    font-size: 22px;
    font-weight: 600;
}}

QLabel#subtitle {{
    color: {THEME['fg_dim']};
    font-size: 11px;
}}

QLabel#status {{
    color: {THEME['fg_dim']};
    font-size: 10px;
    padding: 6px 12px;
}}

QFrame#card {{
    background-color: {THEME['bg_elevated']};
    border: 1px solid {THEME['border']};
    border-radius: 8px;
}}

QPushButton {{
    background-color: {THEME['bg_elevated']};
    color: {THEME['fg']};
    border: 1px solid {THEME['border']};
    border-radius: 6px;
    padding: 8px 14px;
    font-size: 11px;
    font-weight: 500;
}}

QPushButton:hover {{
    background-color: {THEME['bg_hover']};
    border-color: {THEME['accent']};
}}

QPushButton:pressed {{
    background-color: {THEME['accent_press']};
}}

QPushButton#primary {{
    background-color: {THEME['accent']};
    color: white;
    border: none;
    padding: 14px;
    font-size: 13px;
    font-weight: 600;
}}

QPushButton#primary:hover {{
    background-color: {THEME['accent_hover']};
}}

QPushButton#primary:pressed {{
    background-color: {THEME['accent_press']};
}}

QCheckBox {{
    color: {THEME['fg_dim']};
    spacing: 8px;
    font-size: 11px;
}}

QCheckBox::indicator {{
    width: 16px;
    height: 16px;
    border: 1px solid {THEME['border']};
    border-radius: 3px;
    background-color: {THEME['bg']};
}}

QCheckBox::indicator:hover {{
    border-color: {THEME['accent']};
}}

QCheckBox::indicator:checked {{
    background-color: {THEME['accent']};
    border-color: {THEME['accent']};
    image: none;
}}

QStatusBar {{
    background-color: {THEME['bg_elevated']};
    color: {THEME['fg_dim']};
    border-top: 1px solid {THEME['border']};
}}

QToolTip {{
    background-color: {THEME['bg_elevated']};
    color: {THEME['fg']};
    border: 1px solid {THEME['border']};
    padding: 6px 10px;
    border-radius: 4px;
}}
"""


# ============================================================================
# STATE & SETTINGS
# ============================================================================
api_process = None
api_actual_port = API_PORT


def open_path(path):
    path = str(path)
    if IS_WINDOWS:
        os.startfile(path)
    elif IS_MAC:
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


_DEFAULT_SETTINGS = {"skip_llm": False, "show_terminal": False}


def load_settings():
    try:
        if SETTINGS_FILE.exists():
            with open(SETTINGS_FILE) as f:
                saved = json.load(f)
            merged = dict(_DEFAULT_SETTINGS)
            merged.update(saved)
            return merged
    except Exception as e:
        print(f"Warning: failed to load settings: {e}", file=sys.stderr)
    return dict(_DEFAULT_SETTINGS)


def save_settings(settings):
    try:
        with open(SETTINGS_FILE, "w") as f:
            json.dump(settings, f, indent=2)
    except Exception as e:
        print(f"Warning: failed to save settings: {e}", file=sys.stderr)


# ============================================================================
# PORT UTILITIES
# ============================================================================
def port_in_use(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.2)
        try:
            return s.connect_ex(("127.0.0.1", port)) == 0
        except (socket.timeout, OSError):
            return False


def find_free_port(preferred):
    if not port_in_use(preferred):
        return preferred
    for p in range(preferred + 1, preferred + 20):
        if not port_in_use(p):
            return p
    return preferred


def is_api_running():
    global api_actual_port
    if api_actual_port > 0 and port_in_use(api_actual_port):
        return True
    if api_actual_port != API_PORT and port_in_use(API_PORT):
        api_actual_port = API_PORT
        return True
    if api_process is not None and api_process.poll() is None:
        return True
    return False


# ============================================================================
# CONFIG / LIBRARY HTTP SERVER (with CSRF defense)
# ============================================================================
_AUDIO_EXTS = {".wav", ".flac", ".mp3", ".ogg", ".opus", ".m4a", ".aac"}
_MIME_MAP = {
    ".wav": "audio/wav", ".flac": "audio/flac", ".mp3": "audio/mpeg",
    ".ogg": "audio/ogg", ".opus": "audio/opus", ".m4a": "audio/mp4", ".aac": "audio/aac",
}
_MUTATING_ENDPOINTS = {
    "/ui_config", "/save_generation", "/library/mkdir", "/library/rename",
    "/library/move", "/library/delete", "/open_music_folder",
}


def _safe_library_path(relative):
    GENERATIONS_DIR.mkdir(parents=True, exist_ok=True)
    base = GENERATIONS_DIR.resolve()
    try:
        target = (GENERATIONS_DIR / relative).resolve()
        target.relative_to(base)
    except (ValueError, OSError):
        return None
    return target


def load_ui_config():
    try:
        if UI_CONFIG_FILE.exists():
            with open(UI_CONFIG_FILE) as f:
                return json.load(f)
    except Exception:
        pass
    return {}


def save_ui_config(data):
    try:
        with open(UI_CONFIG_FILE, "w") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        print(f"Config save failed: {e}", file=sys.stderr)


class _ConfigHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Launcher-Token")

    def _check_token(self):
        provided = self.headers.get("X-Launcher-Token", "")
        return secrets.compare_digest(provided, LAUNCHER_TOKEN)

    def _reject(self, code=403, msg=b"forbidden"):
        self.send_response(code); self._cors(); self.end_headers(); self.wfile.write(msg)

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    def do_GET(self):
        if self.path == "/ui_config":
            body = json.dumps(load_ui_config()).encode()
            self.send_response(200); self._cors()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        elif self.path == "/launcher_token":
            origin = self.headers.get("Origin", "")
            if origin and origin not in ("null", f"http://127.0.0.1:{CONFIG_PORT}", f"http://localhost:{CONFIG_PORT}"):
                self._reject(403, b"cross-origin denied"); return
            body = LAUNCHER_TOKEN.encode()
            self.send_response(200); self._cors()
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        elif self.path == "/generations_path":
            body = str(GENERATIONS_DIR).encode()
            self.send_response(200); self._cors()
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        else:
            self._reject(404, b"not found")

    def do_POST(self):
        if self.path in _MUTATING_ENDPOINTS and not self._check_token():
            self._reject(403, b"invalid X-Launcher-Token"); return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        if self.path == "/heartbeat":
            self.send_response(200); self._cors(); self.end_headers(); self.wfile.write(b"ok")
        elif self.path == "/open_music_folder":
            GENERATIONS_DIR.mkdir(parents=True, exist_ok=True)
            open_path(str(GENERATIONS_DIR))
            self.send_response(200); self._cors(); self.end_headers()
        elif self.path == "/ui_config":
            try:
                save_ui_config(json.loads(body))
                self.send_response(200); self._cors(); self.end_headers(); self.wfile.write(b"ok")
            except Exception as e:
                self._reject(500, str(e).encode())
        else:
            self._reject(404, b"not found")


def start_config_server():
    class _ThreadedHTTP(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    def _run():
        try:
            srv = _ThreadedHTTP(("127.0.0.1", CONFIG_PORT), _ConfigHandler)
            srv.serve_forever()
        except OSError as e:
            print(f"Config server failed: {e}", file=sys.stderr)

    threading.Thread(target=_run, daemon=True).start()


# ============================================================================
# API MANAGEMENT
# ============================================================================
def _venv_bin(name):
    return str(VENV_DIR / "bin" / name)


def start_api(skip_llm=False, show_terminal=False):
    global api_process, api_actual_port

    if api_process and api_process.poll() is None:
        return True
    if port_in_use(api_actual_port):
        return True

    api_actual_port = find_free_port(API_PORT)
    env = os.environ.copy()
    if skip_llm:
        env["ACESTEP_INIT_LLM"] = "false"

    # Try the console-script first (acestep-api), fall back to python -m
    acestep_api_bin = _venv_bin("acestep-api")
    python_bin = _venv_bin("python")

    if Path(acestep_api_bin).exists():
        cmd = [acestep_api_bin, "--port", str(api_actual_port)]
    else:
        cmd = [python_bin, "-m", "acestep.api", "--port", str(api_actual_port)]

    kwargs = {"cwd": str(REPO_DIR), "env": env, "start_new_session": True,
              "stdin": subprocess.DEVNULL}

    try:
        if show_terminal and IS_LINUX:
            term = _find_terminal()
            if term:
                shell_cmd = (f'cd "{REPO_DIR}" && '
                             f'{" ".join(repr(c) for c in cmd)}; '
                             f'echo; echo "API exited. Press Enter to close."; read')
                if term == "gnome-terminal":
                    api_process = subprocess.Popen([term, "--", "bash", "-c", shell_cmd], **kwargs)
                elif term == "konsole":
                    api_process = subprocess.Popen([term, "--noclose", "-e", "bash", "-c", shell_cmd], **kwargs)
                else:
                    api_process = subprocess.Popen([term, "-e", "bash", "-c", shell_cmd], **kwargs)
                return True

        # Headless
        log_path = CACHE_DIR / "api.log"
        log_file = open(log_path, "a", buffering=1)
        kwargs["stdout"] = log_file
        kwargs["stderr"] = subprocess.STDOUT
        api_process = subprocess.Popen(cmd, **kwargs)
        return True

    except Exception as exc:
        print(f"Failed to start API: {exc}", file=sys.stderr)
        return False


def _find_terminal():
    for t in ["x-terminal-emulator", "gnome-terminal", "konsole",
              "xfce4-terminal", "mate-terminal", "lxterminal",
              "alacritty", "kitty", "wezterm", "foot", "xterm"]:
        if shutil.which(t):
            return t
    return None


def stop_api():
    global api_process, api_actual_port
    if api_process:
        try:
            if not IS_WINDOWS and api_process.poll() is None:
                try:
                    os.killpg(os.getpgid(api_process.pid), signal.SIGTERM)
                    api_process.wait(timeout=5)
                except (ProcessLookupError, PermissionError, subprocess.TimeoutExpired):
                    try:
                        os.killpg(os.getpgid(api_process.pid), signal.SIGKILL)
                    except Exception:
                        pass
            else:
                api_process.terminate()
                api_process.wait(timeout=5)
        except Exception:
            try: api_process.kill()
            except Exception: pass
        api_process = None
    kill_orphaned_acestep_procs(silent=True)
    api_actual_port = API_PORT


def kill_orphaned_acestep_procs(silent=False):
    killed = []
    try:
        for proc in psutil.process_iter(["pid", "name", "cmdline"]):
            try:
                if not proc.info["name"] or "python" not in proc.info["name"].lower():
                    continue
                cmdline_list = proc.info["cmdline"] or []
                is_acestep = any(
                    arg == "acestep.api" or arg == "acestep-api" or
                    arg.endswith("/acestep-api") or arg.endswith("acestep/api.py")
                    for arg in cmdline_list
                )
                if not is_acestep or proc.pid == os.getpid():
                    continue
                if api_process is not None and proc.pid == api_process.pid:
                    continue
                proc.kill()
                killed.append(proc.pid)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
    except Exception:
        pass
    return killed


# ============================================================================
# HTML PREP
# ============================================================================
def list_webuis():
    if not WEBUI_DIR.exists():
        return []
    return [p for p in sorted(WEBUI_DIR.glob("*.html")) if not p.name.startswith("_active_")]


def _rewrite_html(content, port):
    if port != API_PORT:
        for old in [f"127.0.0.1:{API_PORT}", f"localhost:{API_PORT}"]:
            content = content.replace(old, f"127.0.0.1:{port}")
    if "__LAUNCHER_TOKEN__" in content:
        content = content.replace("__LAUNCHER_TOKEN__", LAUNCHER_TOKEN)
    else:
        meta = f'<meta name="launcher-token" content="{LAUNCHER_TOKEN}">'
        if "<head>" in content.lower():
            idx = content.lower().find("<head>") + len("<head>")
            content = content[:idx] + "\n" + meta + content[idx:]
        else:
            content = meta + "\n" + content
    return content


def _prepare_html(html_path, port):
    content = html_path.read_text(encoding="utf-8", errors="replace")
    content = _rewrite_html(content, port)
    active = CACHE_DIR / f"_active_{html_path.stem}.html"
    active.write_text(content, encoding="utf-8")
    return active


# ============================================================================
# QT WORKER (background API operations)
# ============================================================================
class APIWorker(QObject):
    """Runs API start + wait_for_api on a worker thread; emits signals.

    Critical: NEVER touch GUI widgets here. Only emit signals; the main
    thread connects to them and updates UI.
    """
    status_update = Signal(str)
    api_started = Signal(bool)
    webui_ready = Signal(list)

    def __init__(self):
        super().__init__()
        self._cancel = False

    def start_api_only(self, settings):
        if not start_api(settings.get("skip_llm", False),
                         settings.get("show_terminal", False)):
            self.status_update.emit("Failed to start API")
            self.api_started.emit(False)
            return
        self._wait_for_api()

    def launch_webui(self, settings):
        htmls = list_webuis()
        if not htmls:
            self.status_update.emit(f"No HTML files in {WEBUI_DIR}")
            return
        self.status_update.emit("Starting API server...")
        if not start_api(settings.get("skip_llm", False),
                         settings.get("show_terminal", False)):
            self.status_update.emit("Failed to start API")
            return
        if self._wait_for_api():
            prepared = []
            for h in htmls:
                try:
                    p = _prepare_html(h, api_actual_port)
                    prepared.append(p)
                except Exception as e:
                    print(f"Failed to prepare {h}: {e}", file=sys.stderr)
            self.webui_ready.emit(prepared)
            self.status_update.emit(f"{len(prepared)} UI(s) open  |  API :{api_actual_port}")

    def _wait_for_api(self, timeout=180):
        deadline = time.time() + timeout
        start = time.time()
        while time.time() < deadline:
            if port_in_use(api_actual_port):
                self.api_started.emit(True)
                return True
            elapsed = int(time.time() - start)
            self.status_update.emit(f"Loading models... {elapsed}s ({timeout - elapsed}s left)")
            time.sleep(1)
        self.status_update.emit("API timed out")
        self.api_started.emit(False)
        return False


# ============================================================================
# CUSTOM WIDGETS
# ============================================================================
class StatusDot(QWidget):
    """Small colored circle indicating API state."""
    def __init__(self, size=10, parent=None):
        super().__init__(parent)
        self._size = size
        self._color = QColor(THEME["danger"])
        self.setFixedSize(size + 2, size + 2)

    def set_running(self, running):
        self._color = QColor(THEME["success"] if running else THEME["danger"])
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        p.setBrush(QBrush(self._color))
        p.drawEllipse(1, 1, self._size, self._size)


class IconButton(QPushButton):
    """A QPushButton that lets us add a leading dot widget."""
    pass


# ============================================================================
# MAIN WINDOW
# ============================================================================
class LauncherWindow(QMainWindow):
    request_launch_webui = Signal(dict)
    request_toggle_api = Signal(dict)

    def __init__(self):
        super().__init__()
        self.settings = load_settings()
        self._build_ui()
        self._setup_workers()
        self._setup_polling()
        self._setup_lifecycle()

    def _build_ui(self):
        self.setWindowTitle("ACE-Step 1.5")
        self.setFixedSize(460, 480)
        self.setStyleSheet(QSS)

        # Central widget with vertical layout
        central = QWidget()
        central.setObjectName("central")
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setContentsMargins(28, 22, 28, 14)
        layout.setSpacing(10)

        # Title (clickable -> opens website)
        title = QLabel("ACE-Step  1.5")
        title.setObjectName("title")
        title.setCursor(QCursor(Qt.PointingHandCursor))
        title.mousePressEvent = lambda _: webbrowser.open("https://ace-step.github.io")
        layout.addWidget(title)

        # Subtitle with GPU info
        gpu_name = os.environ.get("GPU_NAME", "")
        subtitle_text = f"AI Music Generation  •  {gpu_name}" if gpu_name else "AI Music Generation"
        subtitle = QLabel(subtitle_text)
        subtitle.setObjectName("subtitle")
        layout.addWidget(subtitle)

        layout.addSpacing(8)

        # Big launch button
        self.launch_btn = QPushButton("▶  Launch WebUI")
        self.launch_btn.setObjectName("primary")
        self.launch_btn.setMinimumHeight(50)
        self.launch_btn.setCursor(QCursor(Qt.PointingHandCursor))
        self.launch_btn.setToolTip("Starts API + opens every HTML in webui/")
        self.launch_btn.clicked.connect(self._on_launch_clicked)
        layout.addWidget(self.launch_btn)

        # API + Gradio row
        row = QHBoxLayout()
        row.setSpacing(10)

        api_box = QHBoxLayout()
        api_box.setSpacing(8)
        api_box.setContentsMargins(0, 0, 0, 0)
        self.api_dot = StatusDot(size=10)
        api_box.addWidget(self.api_dot)
        self.api_btn = QPushButton("API Server")
        self.api_btn.setMinimumHeight(36)
        self.api_btn.setCursor(QCursor(Qt.PointingHandCursor))
        self.api_btn.setToolTip("Toggle the API server on/off")
        self.api_btn.clicked.connect(self._on_toggle_api_clicked)
        api_box.addWidget(self.api_btn, 1)
        api_wrap = QWidget()
        api_wrap.setLayout(api_box)

        self.gradio_btn = QPushButton("✦  Gradio UI")
        self.gradio_btn.setMinimumHeight(36)
        self.gradio_btn.setCursor(QCursor(Qt.PointingHandCursor))
        self.gradio_btn.setToolTip("Launch ACE-Step's built-in Gradio interface")
        self.gradio_btn.clicked.connect(self._on_gradio_clicked)

        row.addWidget(api_wrap, 1)
        row.addWidget(self.gradio_btn, 1)
        layout.addLayout(row)

        # Folder shortcuts row
        row2 = QHBoxLayout()
        row2.setSpacing(10)
        self.webui_folder_btn = QPushButton("📁  WebUI Folder")
        self.webui_folder_btn.setMinimumHeight(32)
        self.webui_folder_btn.setCursor(QCursor(Qt.PointingHandCursor))
        self.webui_folder_btn.clicked.connect(lambda: open_path(WEBUI_DIR))
        self.gen_folder_btn = QPushButton("🎵  Generations")
        self.gen_folder_btn.setMinimumHeight(32)
        self.gen_folder_btn.setCursor(QCursor(Qt.PointingHandCursor))
        self.gen_folder_btn.clicked.connect(lambda: open_path(GENERATIONS_DIR))
        row2.addWidget(self.webui_folder_btn, 1)
        row2.addWidget(self.gen_folder_btn, 1)
        layout.addLayout(row2)

        layout.addSpacing(6)

        # Settings card
        card = QFrame()
        card.setObjectName("card")
        card_lay = QVBoxLayout(card)
        card_lay.setContentsMargins(14, 12, 14, 12)
        card_lay.setSpacing(8)

        settings_title = QLabel("Settings")
        settings_title.setStyleSheet(f"color: {THEME['fg']}; font-weight: 600; font-size: 11px;")
        card_lay.addWidget(settings_title)

        self.skip_llm_cb = QCheckBox("Skip LLM (DiT-only mode)")
        self.skip_llm_cb.setChecked(self.settings.get("skip_llm", False))
        self.skip_llm_cb.toggled.connect(self._save_settings)
        card_lay.addWidget(self.skip_llm_cb)

        self.show_term_cb = QCheckBox("Show terminal window (API output)")
        self.show_term_cb.setChecked(self.settings.get("show_terminal", False))
        self.show_term_cb.toggled.connect(self._save_settings)
        card_lay.addWidget(self.show_term_cb)

        layout.addWidget(card)
        layout.addStretch(1)

        # Status bar
        self.status = QStatusBar()
        self.status.setSizeGripEnabled(False)
        self.status_label = QLabel("Ready.")
        self.status_label.setObjectName("status")
        self.status.addWidget(self.status_label, 1)
        self.setStatusBar(self.status)

    def _save_settings(self):
        self.settings["skip_llm"] = self.skip_llm_cb.isChecked()
        self.settings["show_terminal"] = self.show_term_cb.isChecked()
        save_settings(self.settings)

    def _setup_workers(self):
        self.api_thread = QThread()
        self.api_worker = APIWorker()
        self.api_worker.moveToThread(self.api_thread)

        # Wire signals (cross-thread, automatically marshaled by Qt)
        self.api_worker.status_update.connect(self._set_status)
        self.api_worker.api_started.connect(self.api_dot.set_running)
        self.api_worker.webui_ready.connect(self._open_webuis)

        self.request_launch_webui.connect(self.api_worker.launch_webui)
        self.request_toggle_api.connect(self.api_worker.start_api_only)

        self.api_thread.start()

    def _setup_polling(self):
        # Poll API state every 2s ON THE MAIN THREAD (port_in_use is fast).
        # Qt's QTimer is single-threaded; no XInitThreads concerns.
        self.poll_timer = QTimer(self)
        self.poll_timer.setInterval(2000)
        self.poll_timer.timeout.connect(self._poll_api_state)
        self.poll_timer.start()

    def _setup_lifecycle(self):
        kill_orphaned_acestep_procs(silent=True)
        start_config_server()

    def _poll_api_state(self):
        running = is_api_running()
        self.api_dot.set_running(running)

    def _set_status(self, msg):
        self.status_label.setText(msg)

    def _on_launch_clicked(self):
        self._set_status("Starting API server...")
        self.request_launch_webui.emit(dict(self.settings))

    def _on_toggle_api_clicked(self):
        if is_api_running():
            stop_api()
            self.api_dot.set_running(False)
            self._set_status("API server stopped.")
        else:
            self._set_status("Starting API server...")
            self.request_toggle_api.emit(dict(self.settings))

    def _on_gradio_clicked(self):
        def _go():
            port = find_free_port(GRADIO_PORT)
            self.api_worker.status_update.emit(f"Starting Gradio on :{port}...")
            python_bin = _venv_bin("python")
            try:
                subprocess.Popen(
                    [python_bin, "-m", "acestep.gradio_app", "--port", str(port)],
                    cwd=str(REPO_DIR), start_new_session=True,
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except Exception as exc:
                self.api_worker.status_update.emit(f"Gradio launch failed: {exc}")
                return
            time.sleep(10)
            webbrowser.open(f"http://127.0.0.1:{port}")
            self.api_worker.status_update.emit(f"Gradio open at :{port}")
        threading.Thread(target=_go, daemon=True).start()

    def _open_webuis(self, paths):
        for p in paths:
            try:
                webbrowser.open(p.as_uri())
            except Exception as e:
                print(f"Failed to open {p}: {e}", file=sys.stderr)

    def closeEvent(self, event):
        stop_api()
        if self.api_thread.isRunning():
            self.api_thread.quit()
            self.api_thread.wait(2000)
        super().closeEvent(event)


# ============================================================================
# MAIN
# ============================================================================
def main():
    # On Linux, try to set the application's window class so DEs group taskbar
    # entries correctly.
    if IS_LINUX:
        os.environ.setdefault("QT_QPA_PLATFORMTHEME", "")  # don't try to read distro theme

    app = QApplication(sys.argv)
    app.setApplicationName("ACE-Step")
    app.setApplicationDisplayName("ACE-Step 1.5")
    app.setOrganizationName("ACE-Step")

    # Force fusion style for consistent dark look across desktops
    app.setStyle("Fusion")

    # Print env info to stderr
    gpu_name = os.environ.get("GPU_NAME", "unknown")
    gpu_vendor = os.environ.get("GPU_VENDOR", "unknown")
    print(f"GPU:     {gpu_name} ({gpu_vendor})", file=sys.stderr)
    print(f"Install: {INSTALL_DIR}", file=sys.stderr)
    print(f"Venv:    {VENV_DIR}", file=sys.stderr)

    WEBUI_DIR.mkdir(parents=True, exist_ok=True)
    GENERATIONS_DIR.mkdir(parents=True, exist_ok=True)

    win = LauncherWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
