"""
ACE-Step Model Downloader — Qt edition.

Replaces huggingface_hub's noisy multi-bar tqdm output with a single clean
progress dialog showing aggregate %, bytes, speed, ETA, and per-file state.

Design notes:
  - We pre-list every file via list_repo_files() so we know total bytes upfront.
  - Downloads are sequential (not parallel) for predictable progress and to
    avoid hammering HF's CDN with concurrent connections from one host.
  - Each file is fetched via urllib with 64 KiB chunks; per-chunk we emit
    a Qt signal carrying current/total byte counts.
  - Files download to <name>.partial then rename atomically when complete.
    If the user cancels mid-download, the partial sticks around and we
    resume on next launch with HTTP Range headers.
  - All HF API calls go through huggingface_hub when available (handles
    LFS pointers, revisions, etc) and fall back to the CDN URL pattern.

Usage from ace-step.sh's download_models step:
  python3 download_models_qt.py \
    --models-dir /home/user/.local/share/ace-step/data/models \
    --repo ACE-Step/ACE-Step-v1-3.5B:acestep-v15-turbo \
    --repo ACE-Step/ACE-Step-v1-LM-0.6B:acestep-5Hz-lm-0.6B \
    --repo ACE-Step/ACE-Step-v1-LM-1.7B:acestep-5Hz-lm-1.7B
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from PySide6.QtCore import (
    Qt, QObject, QThread, Signal, QTimer, QSize
)
from PySide6.QtGui import QPainter, QColor, QBrush, QFont, QIcon
from PySide6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QProgressBar,
    QPushButton, QFrame, QListWidget, QListWidgetItem, QMessageBox,
    QSizePolicy, QStyle
)


# ============================================================================
# THEME (matches launcher.py)
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
    "success":       "#3fb950",
    "danger":        "#f85149",
    "warning":       "#d29922",
}

QSS = f"""
QWidget#root {{
    background-color: {THEME['bg']};
    color: {THEME['fg']};
}}

QLabel {{
    color: {THEME['fg']};
    background: transparent;
}}

QLabel#title {{
    font-size: 16px;
    font-weight: 600;
    color: {THEME['fg']};
}}

QLabel#subtitle {{
    font-size: 11px;
    color: {THEME['fg_dim']};
}}

QLabel#bigPercent {{
    font-size: 32px;
    font-weight: 700;
    color: {THEME['accent']};
}}

QLabel#stats {{
    font-size: 11px;
    color: {THEME['fg_dim']};
}}

QLabel#currentFile {{
    font-size: 11px;
    color: {THEME['fg']};
    font-family: "DejaVu Sans Mono", "Liberation Mono", monospace;
}}

QFrame#card {{
    background-color: {THEME['bg_elevated']};
    border: 1px solid {THEME['border']};
    border-radius: 8px;
}}

QProgressBar {{
    background-color: {THEME['bg_elevated']};
    border: 1px solid {THEME['border']};
    border-radius: 6px;
    height: 14px;
    text-align: center;
    color: transparent;
}}

QProgressBar::chunk {{
    background-color: {THEME['accent']};
    border-radius: 5px;
}}

QPushButton {{
    background-color: {THEME['bg_elevated']};
    color: {THEME['fg']};
    border: 1px solid {THEME['border']};
    border-radius: 6px;
    padding: 8px 18px;
    font-size: 11px;
    font-weight: 500;
}}

QPushButton:hover {{
    background-color: {THEME['bg_hover']};
    border-color: {THEME['accent']};
}}

QPushButton#danger:hover {{
    border-color: {THEME['danger']};
    color: {THEME['danger']};
}}

QListWidget {{
    background-color: {THEME['bg_elevated']};
    border: 1px solid {THEME['border']};
    border-radius: 6px;
    color: {THEME['fg_dim']};
    font-size: 10px;
    font-family: "DejaVu Sans Mono", "Liberation Mono", monospace;
    padding: 4px;
}}

QListWidget::item {{
    border: none;
    padding: 3px 8px;
}}
"""


# ============================================================================
# DATA
# ============================================================================
@dataclass
class FileEntry:
    repo: str          # e.g. "ACE-Step/ACE-Step-v1-3.5B"
    rel_path: str      # path within the repo, e.g. "music_vocoder/model.safetensors"
    local_dir: str     # local subdir name we map this repo to
    size: int = 0      # total size in bytes (filled in pre-flight)
    downloaded: int = 0
    state: str = "pending"  # pending | active | done | error
    error_msg: str = ""

    @property
    def display_path(self) -> str:
        return f"{self.local_dir}/{self.rel_path}"

    @property
    def local_path(self) -> Path:
        # filled in by caller, but compute here as helper
        return Path(self.local_dir) / self.rel_path


@dataclass
class DownloadPlan:
    files: list[FileEntry] = field(default_factory=list)

    @property
    def total_bytes(self) -> int:
        return sum(f.size for f in self.files)

    @property
    def downloaded_bytes(self) -> int:
        return sum(f.downloaded for f in self.files)


# ============================================================================
# WORKER THREAD
# ============================================================================
class DownloadWorker(QObject):
    """Runs the download on a background thread; emits Qt signals to UI."""

    plan_ready = Signal(object)              # DownloadPlan
    file_started = Signal(int)               # file index
    file_progress = Signal(int, int, int)    # idx, downloaded, total
    file_done = Signal(int)                  # idx
    file_error = Signal(int, str)            # idx, error
    overall_progress = Signal(int, int, float)  # downloaded, total, speed_bps
    finished = Signal(bool, str)             # success, message

    def __init__(self, models_dir: Path, repos: list[tuple[str, str]]):
        """
        repos: list of (huggingface_repo_id, local_subdir_name)
        """
        super().__init__()
        self.models_dir = Path(models_dir)
        self.repos = repos
        self._cancel = False
        self._plan: Optional[DownloadPlan] = None

    def cancel(self):
        self._cancel = True

    def run(self):
        try:
            self._do_run()
        except Exception as e:
            self.finished.emit(False, f"Unexpected error: {e}")

    def _do_run(self):
        # Step 1: Pre-flight — list all files in all repos.
        self._plan = DownloadPlan()

        try:
            from huggingface_hub import HfApi
            api = HfApi()
        except ImportError:
            self.finished.emit(False, "huggingface_hub not installed in venv")
            return

        for repo_id, local_subdir in self.repos:
            if self._cancel:
                self.finished.emit(False, "Cancelled before listing")
                return
            try:
                # repo_info has size info; list_repo_files only gives names
                info = api.repo_info(repo_id=repo_id, files_metadata=True)
            except Exception as e:
                self.finished.emit(False, f"Failed to query {repo_id}: {e}")
                return

            for sib in info.siblings:
                size = getattr(sib, "size", None) or 0
                # Skip enormous files we don't need? No — bundle everything,
                # snapshot_download equivalent.
                self._plan.files.append(FileEntry(
                    repo=repo_id,
                    rel_path=sib.rfilename,
                    local_dir=local_subdir,
                    size=size,
                ))

        # If sizes are zero (some HF endpoints don't return them), do a HEAD
        # to fill them in. Otherwise our progress will be wrong.
        for f in self._plan.files:
            if f.size == 0 and not self._cancel:
                f.size = self._head_size(f) or 0

        # Account for already-downloaded files (resume support)
        for f in self._plan.files:
            target = self.models_dir / f.local_dir / f.rel_path
            partial = target.with_suffix(target.suffix + ".partial")
            if target.exists() and target.stat().st_size == f.size:
                f.downloaded = f.size
                f.state = "done"
            elif partial.exists():
                f.downloaded = partial.stat().st_size
                # Keep state=pending; we'll resume

        self.plan_ready.emit(self._plan)

        # Step 2: Download each file sequentially.
        speed_window: list[tuple[float, int]] = []  # (timestamp, total_downloaded)
        last_overall_emit = 0.0

        for idx, f in enumerate(self._plan.files):
            if self._cancel:
                self.finished.emit(False, "Cancelled by user")
                return

            if f.state == "done":
                # Already complete from previous run
                self.file_done.emit(idx)
                continue

            f.state = "active"
            self.file_started.emit(idx)

            try:
                self._download_file(f, idx, speed_window)
            except _CancelledError:
                self.finished.emit(False, "Cancelled by user")
                return
            except Exception as e:
                f.state = "error"
                f.error_msg = str(e)
                self.file_error.emit(idx, str(e))
                self.finished.emit(False, f"Failed: {f.display_path}: {e}")
                return

            f.state = "done"
            self.file_done.emit(idx)

        # Mark this set of repos as complete
        marker = self.models_dir / ".populated"
        marker.touch()

        self.finished.emit(True, "All models downloaded successfully.")

    def _head_size(self, f: FileEntry) -> Optional[int]:
        url = self._url_for(f)
        try:
            req = Request(url, method="HEAD")
            with urlopen(req, timeout=15) as resp:
                cl = resp.headers.get("Content-Length")
                if cl:
                    return int(cl)
        except Exception:
            pass
        return None

    @staticmethod
    def _url_for(f: FileEntry) -> str:
        # Standard HF resolver URL. Branch defaults to "main".
        # Format: https://huggingface.co/<repo>/resolve/main/<path>
        return f"https://huggingface.co/{f.repo}/resolve/main/{f.rel_path}"

    def _download_file(self, f: FileEntry, idx: int, speed_window: list):
        target = self.models_dir / f.local_dir / f.rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_suffix(target.suffix + ".partial")

        # Determine resume offset
        existing = partial.stat().st_size if partial.exists() else 0
        if existing > f.size > 0:
            # Partial is somehow bigger than expected — discard
            partial.unlink()
            existing = 0

        url = self._url_for(f)
        headers = {}
        mode = "ab"
        if existing > 0 and f.size > 0 and existing < f.size:
            headers["Range"] = f"bytes={existing}-"
        else:
            mode = "wb"
            existing = 0

        f.downloaded = existing

        req = Request(url, headers=headers)
        try:
            resp = urlopen(req, timeout=30)
        except HTTPError as e:
            if e.code == 416 and existing == f.size:
                # Already complete; just rename
                partial.rename(target)
                return
            raise

        # Stream to disk
        chunk = 64 * 1024
        last_emit = 0.0

        with open(partial, mode) as out:
            while True:
                if self._cancel:
                    out.flush()
                    raise _CancelledError()
                buf = resp.read(chunk)
                if not buf:
                    break
                out.write(buf)
                f.downloaded += len(buf)

                now = time.time()
                # Throttle UI updates to ~20 Hz
                if now - last_emit >= 0.05:
                    self.file_progress.emit(idx, f.downloaded, f.size)
                    self._emit_overall(speed_window)
                    last_emit = now

        # Atomic rename
        partial.rename(target)

        # Final emit
        self.file_progress.emit(idx, f.downloaded, f.size)
        self._emit_overall(speed_window)

    def _emit_overall(self, speed_window: list):
        if self._plan is None:
            return
        downloaded = self._plan.downloaded_bytes
        total = self._plan.total_bytes
        now = time.time()
        speed_window.append((now, downloaded))
        # Keep only the last ~3 seconds
        cutoff = now - 3.0
        while len(speed_window) > 1 and speed_window[0][0] < cutoff:
            speed_window.pop(0)
        speed_bps = 0.0
        if len(speed_window) >= 2:
            dt = speed_window[-1][0] - speed_window[0][0]
            db = speed_window[-1][1] - speed_window[0][1]
            if dt > 0:
                speed_bps = db / dt
        self.overall_progress.emit(downloaded, total, speed_bps)


class _CancelledError(Exception):
    pass


# ============================================================================
# UI HELPERS
# ============================================================================
def fmt_bytes(n: int) -> str:
    if n < 1024: return f"{n} B"
    if n < 1024 ** 2: return f"{n/1024:.1f} KB"
    if n < 1024 ** 3: return f"{n/1024**2:.1f} MB"
    return f"{n/1024**3:.2f} GB"


def fmt_speed(bps: float) -> str:
    if bps <= 0: return "—"
    if bps < 1024: return f"{bps:.0f} B/s"
    if bps < 1024 ** 2: return f"{bps/1024:.1f} KB/s"
    if bps < 1024 ** 3: return f"{bps/1024**2:.1f} MB/s"
    return f"{bps/1024**3:.2f} GB/s"


def fmt_eta(remaining_bytes: int, bps: float) -> str:
    if bps <= 0 or remaining_bytes <= 0: return "—"
    secs = int(remaining_bytes / bps)
    if secs < 60: return f"{secs}s"
    if secs < 3600: return f"{secs//60}m {secs%60}s"
    h = secs // 3600
    m = (secs % 3600) // 60
    return f"{h}h {m}m"


# ============================================================================
# MAIN WINDOW
# ============================================================================
class DownloadWindow(QWidget):
    def __init__(self, models_dir: Path, repos: list[tuple[str, str]]):
        super().__init__()
        self.models_dir = models_dir
        self.repos = repos
        self.plan: Optional[DownloadPlan] = None
        self.exit_code = 1  # default to failure unless we explicitly succeed

        self._build_ui()
        self._start_worker()

    def _build_ui(self):
        self.setObjectName("root")
        self.setWindowTitle("ACE-Step — Downloading Models")
        self.setStyleSheet(QSS)
        self.setFixedSize(560, 480)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 22, 28, 22)
        layout.setSpacing(14)

        # Header
        title = QLabel("Downloading AI Models")
        title.setObjectName("title")
        layout.addWidget(title)

        self.subtitle = QLabel("Preparing…")
        self.subtitle.setObjectName("subtitle")
        layout.addWidget(self.subtitle)

        # Big percentage card
        card = QFrame()
        card.setObjectName("card")
        card_lay = QVBoxLayout(card)
        card_lay.setContentsMargins(20, 16, 20, 16)
        card_lay.setSpacing(8)

        # Top row: big percentage + stats column
        top = QHBoxLayout()
        top.setSpacing(20)

        self.percent_lbl = QLabel("0%")
        self.percent_lbl.setObjectName("bigPercent")
        self.percent_lbl.setMinimumWidth(110)
        top.addWidget(self.percent_lbl)

        stats_col = QVBoxLayout()
        stats_col.setSpacing(2)
        self.bytes_lbl = QLabel("0 B / —")
        self.bytes_lbl.setObjectName("stats")
        self.speed_lbl = QLabel("Speed: — • ETA: —")
        self.speed_lbl.setObjectName("stats")
        self.current_lbl = QLabel("Listing files from Hugging Face…")
        self.current_lbl.setObjectName("currentFile")
        self.current_lbl.setWordWrap(False)
        # Truncate long paths visually
        self.current_lbl.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
        stats_col.addWidget(self.bytes_lbl)
        stats_col.addWidget(self.speed_lbl)
        stats_col.addStretch(1)
        stats_col.addWidget(self.current_lbl)
        top.addLayout(stats_col, 1)

        card_lay.addLayout(top)

        # Progress bar
        self.bar = QProgressBar()
        self.bar.setRange(0, 1000)  # finer than 100 so animation is smooth
        self.bar.setValue(0)
        card_lay.addWidget(self.bar)

        layout.addWidget(card)

        # File list
        list_label = QLabel("Files")
        list_label.setObjectName("subtitle")
        layout.addWidget(list_label)

        self.file_list = QListWidget()
        self.file_list.setSelectionMode(QListWidget.NoSelection)
        self.file_list.setVerticalScrollMode(QListWidget.ScrollPerPixel)
        layout.addWidget(self.file_list, 1)

        # Bottom buttons
        btn_row = QHBoxLayout()
        btn_row.addStretch(1)
        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.setObjectName("danger")
        self.cancel_btn.clicked.connect(self._on_cancel)
        btn_row.addWidget(self.cancel_btn)
        layout.addLayout(btn_row)

    def _start_worker(self):
        self.thread = QThread()
        self.worker = DownloadWorker(self.models_dir, self.repos)
        self.worker.moveToThread(self.thread)

        self.worker.plan_ready.connect(self._on_plan_ready)
        self.worker.file_started.connect(self._on_file_started)
        self.worker.file_progress.connect(self._on_file_progress)
        self.worker.file_done.connect(self._on_file_done)
        self.worker.file_error.connect(self._on_file_error)
        self.worker.overall_progress.connect(self._on_overall)
        self.worker.finished.connect(self._on_finished)

        self.thread.started.connect(self.worker.run)
        self.thread.start()

    # ----- worker signal handlers -----

    def _on_plan_ready(self, plan: DownloadPlan):
        self.plan = plan
        total_str = fmt_bytes(plan.total_bytes) if plan.total_bytes > 0 else "—"
        self.subtitle.setText(f"{len(plan.files)} files • {total_str} total")
        self.bytes_lbl.setText(f"0 B / {total_str}")

        # Populate the file list
        self.file_list.clear()
        for f in plan.files:
            label = f.display_path
            if f.size > 0:
                label += f"  ({fmt_bytes(f.size)})"
            item = QListWidgetItem(f"  ○  {label}")
            if f.state == "done":
                item.setText(f"  ✓  {label}")
                item.setForeground(QColor(THEME["success"]))
            else:
                item.setForeground(QColor(THEME["fg_dim"]))
            self.file_list.addItem(item)

        # If everything is already done from a prior run, fast-path success
        if plan.total_bytes > 0:
            initial_pct = plan.downloaded_bytes / plan.total_bytes
            self.bar.setValue(int(initial_pct * 1000))
            self.percent_lbl.setText(f"{int(initial_pct*100)}%")

    def _on_file_started(self, idx: int):
        if not self.plan: return
        f = self.plan.files[idx]
        label = f.display_path
        if f.size > 0:
            label += f"  ({fmt_bytes(f.size)})"
        item = self.file_list.item(idx)
        if item:
            item.setText(f"  ●  {label}")
            item.setForeground(QColor(THEME["accent"]))
            self.file_list.scrollToItem(item)
        # Truncate the current-file label to fit
        self._set_current_file_label(f.display_path)

    def _on_file_progress(self, idx: int, downloaded: int, total: int):
        # We don't update the file list per-chunk — only the current_lbl
        # gets a per-file %, which avoids redrawing the whole list 20x/sec.
        if not self.plan: return
        f = self.plan.files[idx]
        if total > 0:
            pct = int(100 * downloaded / total)
            self._set_current_file_label(f"{f.display_path}  ({pct}%)")

    def _on_file_done(self, idx: int):
        if not self.plan: return
        f = self.plan.files[idx]
        label = f.display_path
        if f.size > 0:
            label += f"  ({fmt_bytes(f.size)})"
        item = self.file_list.item(idx)
        if item:
            item.setText(f"  ✓  {label}")
            item.setForeground(QColor(THEME["success"]))

    def _on_file_error(self, idx: int, msg: str):
        if not self.plan: return
        f = self.plan.files[idx]
        item = self.file_list.item(idx)
        if item:
            item.setText(f"  ✗  {f.display_path}  ({msg})")
            item.setForeground(QColor(THEME["danger"]))

    def _on_overall(self, downloaded: int, total: int, speed_bps: float):
        if total > 0:
            ratio = downloaded / total
            self.bar.setValue(int(ratio * 1000))
            self.percent_lbl.setText(f"{int(ratio*100)}%")
        self.bytes_lbl.setText(f"{fmt_bytes(downloaded)} / {fmt_bytes(total)}")
        eta = fmt_eta(max(0, total - downloaded), speed_bps)
        self.speed_lbl.setText(f"Speed: {fmt_speed(speed_bps)}  •  ETA: {eta}")

    def _on_finished(self, success: bool, message: str):
        self.thread.quit()
        self.thread.wait(2000)
        if success:
            self.exit_code = 0
            self.bar.setValue(1000)
            self.percent_lbl.setText("100%")
            self.subtitle.setText("✓ Complete")
            self.cancel_btn.setText("Done")
            self.cancel_btn.setObjectName("")  # remove danger styling
            self.cancel_btn.setStyleSheet("")
            self.cancel_btn.clicked.disconnect()
            self.cancel_btn.clicked.connect(self.close)
            QTimer.singleShot(800, self.close)
        else:
            self.exit_code = 1
            self.subtitle.setText(f"✗ {message}")
            self.cancel_btn.setText("Close")
            self.cancel_btn.clicked.disconnect()
            self.cancel_btn.clicked.connect(self.close)

    def _on_cancel(self):
        if hasattr(self, "worker"):
            self.worker.cancel()
        self.cancel_btn.setEnabled(False)
        self.cancel_btn.setText("Cancelling…")

    def _set_current_file_label(self, text: str):
        # Visual truncation for long paths
        max_chars = 60
        if len(text) > max_chars:
            text = "…" + text[-(max_chars - 1):]
        self.current_lbl.setText(text)

    def closeEvent(self, event):
        if hasattr(self, "worker"):
            self.worker.cancel()
        if hasattr(self, "thread") and self.thread.isRunning():
            self.thread.quit()
            self.thread.wait(2000)
        super().closeEvent(event)


# ============================================================================
# MAIN
# ============================================================================
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-dir", required=True,
                        help="Where to download models (e.g. ~/.local/share/ace-step/data/models)")
    parser.add_argument("--repo", action="append", required=True,
                        help="repo:local_subdir, e.g. 'ACE-Step/ACE-Step-v1-3.5B:acestep-v15-turbo'")
    args = parser.parse_args()

    repos = []
    for r in args.repo:
        if ":" not in r:
            print(f"ERROR: --repo expects 'repo_id:local_dir', got: {r}", file=sys.stderr)
            sys.exit(2)
        repo_id, local = r.split(":", 1)
        repos.append((repo_id, local))

    models_dir = Path(args.models_dir).expanduser().resolve()
    models_dir.mkdir(parents=True, exist_ok=True)

    app = QApplication(sys.argv)
    app.setApplicationName("ACE-Step Downloader")
    app.setApplicationDisplayName("ACE-Step Model Downloader")
    app.setStyle("Fusion")

    win = DownloadWindow(models_dir, repos)
    win.show()
    app.exec()
    sys.exit(win.exit_code)


if __name__ == "__main__":
    main()
