"""
ACE-Step 1.5 Launcher -- V5.1
One window. One big button. Everything else is automatic.

Drop this file inside ACE-Step-1.5/ next to pyproject.toml.
Installer should place it there and build the shortcut to it.

V5.1 Changes:
- Added: Update Backend button (git pull with auto-stash for local changes)

V5.0 Changes:
- Removed: Entire heartbeat system (kill launcher = kill server)
- Fixed: Library persistence (no more random temp files breaking IndexedDB)
- Changed: API button is now a red/green toggle switch
- Added: Collapsible Settings panel
- Added: Skip LLM toggle (DiT-only mode for low-RAM systems)
- Added: Show terminal windows toggle
- Port rewrite now uses fixed path (_active.html) instead of random tempfile
"""

import sys
import os
import subprocess
import threading
import time
import json
import socket
import webbrowser
from pathlib import Path

import psutil
import tkinter as tk

# --- CROSS-PLATFORM UTILITIES ---
import platform
IS_WINDOWS = platform.system() == 'Windows'
IS_MAC     = platform.system() == 'Darwin'
IS_LINUX   = platform.system() == 'Linux'

def open_path(path):
    path = str(path)
    if IS_WINDOWS:
        os.startfile(path)
    elif IS_MAC:
        subprocess.Popen(['open', path])
    else:
        subprocess.Popen(['xdg-open', path])

if IS_WINDOWS:
    import customtkinter as ctk
    import pystray
    from PIL import Image, ImageDraw
else:
    try:
        import customtkinter as ctk
    except ImportError:
        ctk = None
    try:
        import pystray
        from PIL import Image, ImageDraw
    except ImportError:
        pystray = None


# --- TOOLTIP ---
class Tip:
    def __init__(self, widget, text, delay=650):
        self._w, self._text, self._delay = widget, text, delay
        self._id = self._win = None
        widget.bind('<Enter>', lambda e: self._schedule())
        widget.bind('<Leave>', lambda e: self._cancel())

    def _schedule(self):
        self._id = self._w.after(self._delay, self._show)

    def _cancel(self):
        if self._id:
            self._w.after_cancel(self._id)
            self._id = None
        if self._win:
            self._win.destroy()
            self._win = None

    def _show(self):
        x = self._w.winfo_rootx() + 10
        y = self._w.winfo_rooty() + self._w.winfo_height() + 4
        self._win = w = tk.Toplevel(self._w)
        w.wm_overrideredirect(True)
        w.wm_geometry(f'+{x}+{y}')
        tk.Label(w, text=self._text,
                 bg='#1a1e2e', fg='#e8eaf0',
                 font=('Segoe UI', 9),
                 padx=10, pady=6,
                 justify='left',
                 relief='flat').pack()


# --- INSTALL PATH DETECTION ---
def _find_install_path() -> Path:
    if getattr(sys, 'frozen', False):
        return Path(sys.executable).parent
    here = Path(__file__).parent
    if (here / 'pyproject.toml').exists():
        return here
    for candidate in [
        Path.home() / 'ACE-Step-1.5',
        Path('C:/ACE-Step-1.5'),
        Path.home() / 'Desktop' / 'ACE-Step-1.5',
    ]:
        if (candidate / 'pyproject.toml').exists():
            return candidate
    return here

INSTALL_PATH = _find_install_path()
WEBUI_DIR    = INSTALL_PATH / 'webui'
SETTINGS_FILE = INSTALL_PATH / '.launcher_settings.json'

API_PORT    = 8001
GRADIO_PORT = 7860

# --- GLOBAL STATE ---
api_process      = None
api_actual_port  = API_PORT
tray_icon        = None
status_var       = None


# --- SETTINGS PERSISTENCE ---
_DEFAULT_SETTINGS = {
    'skip_llm': False,
    'show_terminal': False,
}

def load_settings() -> dict:
    try:
        if SETTINGS_FILE.exists():
            with open(SETTINGS_FILE, 'r') as f:
                saved = json.load(f)
            merged = dict(_DEFAULT_SETTINGS)
            merged.update(saved)
            return merged
    except Exception:
        pass
    return dict(_DEFAULT_SETTINGS)

def save_settings(settings: dict):
    try:
        with open(SETTINGS_FILE, 'w') as f:
            json.dump(settings, f, indent=2)
    except Exception:
        pass

# --- PORT UTILITIES ---
def port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.4)
        return s.connect_ex(('127.0.0.1', port)) == 0

def find_free_port(preferred: int) -> int:
    if not port_in_use(preferred):
        return preferred
    for p in range(preferred + 1, preferred + 20):
        if not port_in_use(p):
            return p
    return preferred


# --- HTML REWRITING (port fix only, fixed output path) ---

def _rewrite_api_port(content: str, api_port: int) -> str:
    if api_port != API_PORT:
        for old in [f'127.0.0.1:{API_PORT}', f'localhost:{API_PORT}']:
            content = content.replace(old, f'127.0.0.1:{api_port}')
    return content


def _prepare_html(html_path: Path, api_port: int) -> Path:
    """Prepare HTML for opening. Returns original path when possible,
    or a FIXED path (_active.html) when port rewrite is needed.
    Fixed path = same browser origin = IndexedDB library persists.
    """
    if api_port == API_PORT:
        return html_path  # No rewrite needed -- open original directly

    content = html_path.read_text(encoding='utf-8', errors='replace')
    content = _rewrite_api_port(content, api_port)

    # Write to fixed path so browser origin stays consistent
    active_path = WEBUI_DIR / '_active.html'
    active_path.write_text(content, encoding='utf-8')
    return active_path


# --- API MANAGEMENT ---
def start_api(skip_llm=False, show_terminal=False) -> bool:
    global api_process, api_actual_port
    if api_process and api_process.poll() is None:
        return True

    api_actual_port = find_free_port(API_PORT)
    if api_actual_port != API_PORT:
        show_status(f'Port {API_PORT} busy -- using {api_actual_port}')

    env = os.environ.copy()
    if skip_llm:
        env['ACESTEP_INIT_LLM'] = 'false'

    try:
        kwargs = {'cwd': str(INSTALL_PATH), 'env': env}
        if IS_WINDOWS:
            if show_terminal:
                # Let the terminal window be visible
                kwargs['creationflags'] = subprocess.CREATE_NEW_CONSOLE
            else:
                si = subprocess.STARTUPINFO()
                si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                si.wShowWindow = 0
                kwargs['startupinfo'] = si
                kwargs['creationflags'] = (
                    subprocess.CREATE_NO_WINDOW | subprocess.DETACHED_PROCESS)
        else:
            kwargs['start_new_session'] = True
        api_process = subprocess.Popen(
            ['uv', 'run', 'acestep-api', '--port', str(api_actual_port)],
            **kwargs)
        return True
    except Exception as exc:
        show_status(f'Failed to start API: {exc}')
        return False


def kill_orphaned_acestep_procs(silent=False):
    killed = []
    try:
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                if proc.info['name'] and 'python' in proc.info['name'].lower():
                    cmdline = ' '.join(proc.info['cmdline'] or [])
                    if 'acestep-api' in cmdline or 'acestep_api' in cmdline:
                        if proc.pid != os.getpid():
                            if api_process is None or proc.pid != api_process.pid:
                                proc.kill()
                                killed.append(proc.pid)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
    except Exception:
        pass
    if killed and not silent:
        show_status(f'Cleaned up {len(killed)} orphaned process(es)')
    return killed


def stop_api():
    global api_process, api_actual_port
    if api_process:
        try:
            api_process.terminate()
            api_process.wait(timeout=5)
        except Exception:
            try:
                api_process.kill()
            except Exception:
                pass
        api_process = None
    kill_orphaned_acestep_procs(silent=True)
    api_actual_port = API_PORT
    show_status('API server stopped.')


def is_api_running() -> bool:
    if api_process and api_process.poll() is None:
        return True
    return port_in_use(api_actual_port)


def wait_for_api(port: int, timeout: int = 180) -> bool:
    deadline = time.time() + timeout
    start = time.time()
    while time.time() < deadline:
        if port_in_use(port):
            return True
        elapsed = int(time.time() - start)
        remaining = timeout - elapsed
        show_status(f'Loading models... {elapsed}s ({remaining}s left)')
        time.sleep(1)
    return False


# --- LAUNCH ACTIONS ---
def action_launch_webui(settings: dict):
    htmls = sorted(WEBUI_DIR.glob('*.html')) if WEBUI_DIR.exists() else []
    # Filter out the _active.html rewrite file
    htmls = [h for h in htmls if h.name != '_active.html']
    if not htmls:
        fallback = INSTALL_PATH / 'webui.html'
        if fallback.exists():
            htmls = [fallback]
    if not htmls:
        show_status('No HTML files found -- check /webui/ folder.')
        return

    show_status('Starting API server...')
    if not start_api(skip_llm=settings.get('skip_llm', False),
                     show_terminal=settings.get('show_terminal', False)):
        return

    def _go():
        show_status(f'Waiting for API on :{api_actual_port}...')
        if not wait_for_api(api_actual_port):
            show_status('API timed out -- models may still be loading.')
            return
        for html in htmls:
            prepared = _prepare_html(html, api_actual_port)
            webbrowser.open(prepared.as_uri())
        show_status(f'{len(htmls)} UI(s) open  |  API :{api_actual_port}')

    threading.Thread(target=_go, daemon=True).start()


def action_toggle_api(settings: dict, update_indicator_fn=None):
    """Toggle API server on/off."""
    if is_api_running():
        stop_api()
        if update_indicator_fn:
            update_indicator_fn(False)
    else:
        def _go():
            show_status('Starting API server...')
            if not start_api(skip_llm=settings.get('skip_llm', False),
                             show_terminal=settings.get('show_terminal', False)):
                return
            if wait_for_api(api_actual_port):
                show_status(f'API running on :{api_actual_port}')
            else:
                show_status('API started -- still loading.')
            if update_indicator_fn:
                update_indicator_fn(True)
        threading.Thread(target=_go, daemon=True).start()


def action_launch_gradio():
    def _go():
        port = find_free_port(GRADIO_PORT)
        show_status(f'Starting Gradio on :{port}...')
        kwargs = {'cwd': str(INSTALL_PATH)}
        if IS_WINDOWS:
            kwargs['creationflags'] = subprocess.CREATE_NO_WINDOW
        else:
            kwargs['start_new_session'] = True
        subprocess.Popen(['uv', 'run', 'acestep', '--port', str(port)],
                         **kwargs)
        time.sleep(10)
        webbrowser.open(f'http://127.0.0.1:{port}')
        show_status(f'Gradio open at :{port}')
    threading.Thread(target=_go, daemon=True).start()


def action_open_webui_folder():
    WEBUI_DIR.mkdir(parents=True, exist_ok=True)
    open_path(str(WEBUI_DIR))


def action_update_backend():
    """Pull latest ACE-Step code from origin. Handles dirty worktrees."""

    def _run_git(*args):
        """Run a git command in INSTALL_PATH, return (returncode, stdout, stderr)."""
        try:
            result = subprocess.run(
                ['git'] + list(args),
                cwd=str(INSTALL_PATH),
                capture_output=True, text=True, timeout=60)
            return result.returncode, result.stdout.strip(), result.stderr.strip()
        except FileNotFoundError:
            return -1, '', 'git not found'
        except subprocess.TimeoutExpired:
            return -2, '', 'git command timed out'
        except Exception as exc:
            return -3, '', str(exc)

    def _do_update():
        # Sanity checks
        if not (INSTALL_PATH / '.git').exists():
            show_status('Update failed: not a git repository. Re-run installer.')
            return

        rc, _, err = _run_git('--version')
        if rc != 0:
            show_status('Update failed: git is not installed.')
            return

        show_status('Checking for updates...')

        # Fetch latest
        rc, _, err = _run_git('fetch', 'origin')
        if rc != 0:
            show_status(f'Fetch failed: {err[:80]}')
            return

        # Check current branch
        rc, branch, _ = _run_git('rev-parse', '--abbrev-ref', 'HEAD')
        if rc != 0 or not branch:
            branch = 'main'

        # Check if behind
        rc, status_out, _ = _run_git('status', '-uno')
        if 'Your branch is up to date' in status_out:
            show_status('Already up to date!')
            return

        # Check for local changes that would block pull
        rc, diff_out, _ = _run_git('diff', '--stat')
        stashed = False
        if diff_out:
            show_status('Stashing local changes...')
            rc, _, err = _run_git('stash', 'push', '-m', 'launcher-auto-stash')
            if rc != 0:
                show_status(f'Stash failed: {err[:80]}')
                return
            stashed = True

        # Pull
        show_status(f'Pulling updates on {branch}...')
        rc, pull_out, err = _run_git('pull', 'origin', branch)
        if rc != 0:
            show_status(f'Pull failed: {err[:80]}')
            if stashed:
                _run_git('stash', 'pop')
            return

        # Restore stashed changes
        if stashed:
            show_status('Restoring local changes...')
            _run_git('stash', 'pop')

        show_status('Backend updated successfully!')

    threading.Thread(target=_do_update, daemon=True).start()


# --- STATUS HELPER ---
def show_status(msg: str):
    if status_var:
        try:
            status_var.set(msg)
        except Exception:
            pass


# --- SYSTEM TRAY ---
def _make_tray_icon_image() -> Image.Image:
    img  = Image.new('RGB', (64, 64), (12, 15, 25))
    draw = ImageDraw.Draw(img)
    draw.ellipse([4, 4, 60, 60], fill=(0, 90, 210))
    draw.polygon([(20, 17), (20, 47), (50, 32)], fill=(240, 245, 255))
    return img


def build_tray(app_window) -> pystray.Icon:
    def on_show(icon, item):
        app_window.after(0, lambda: (app_window.deiconify(), app_window.lift()))
    def on_stop(icon, item):
        stop_api()
    def on_quit(icon, item):
        stop_api()
        icon.stop()
        app_window.after(0, app_window.destroy)
    menu = pystray.Menu(
        pystray.MenuItem('Show Launcher', on_show, default=True),
        pystray.MenuItem('Stop API Server', on_stop),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem('Quit', on_quit))
    return pystray.Icon('acestep', _make_tray_icon_image(), 'ACE-Step 1.5', menu)


# --- MAIN UI ---
def main():
    global status_var, tray_icon

    WEBUI_DIR.mkdir(parents=True, exist_ok=True)
    kill_orphaned_acestep_procs(silent=True)

    settings = load_settings()

    ctk.set_appearance_mode('dark')
    ctk.set_default_color_theme('blue')

    ACCENT    = '#1a6fff'
    ACCENT_HV = '#3d85ff'
    BTN2_BG   = '#252a3d'
    BTN2_HV   = '#2f3650'
    BG        = '#12151e'
    BG2       = '#1a1e2e'
    FG        = '#e8eaf0'
    FG_DIM    = '#8b90a8'
    FG_RDY    = '#3ddc84'
    RED       = '#e53935'
    RED_HV    = '#ff5252'
    GREEN     = '#3ddc84'
    GREEN_HV  = '#69f0ae'

    app = ctk.CTk()
    app.title('ACE-Step 1.5')
    app.geometry('440x440')
    app.resizable(False, False)
    app.configure(fg_color=BG)

    status_var = tk.StringVar(value='Ready.')
    skip_llm_var = tk.BooleanVar(value=settings.get('skip_llm', False))
    show_term_var = tk.BooleanVar(value=settings.get('show_terminal', False))
    settings_open = tk.BooleanVar(value=False)
    tray_icon = build_tray(app)

    def _get_settings():
        return {
            'skip_llm': skip_llm_var.get(),
            'show_terminal': show_term_var.get(),
        }

    def _save_current():
        save_settings(_get_settings())

    def on_close():
        app.withdraw()
        threading.Thread(target=tray_icon.run, daemon=True).start()

    app.protocol('WM_DELETE_WINDOW', on_close)

    outer = ctk.CTkFrame(app, fg_color=BG, corner_radius=0)
    outer.pack(fill='both', expand=True, padx=28, pady=20)

    # -- Title --
    title_lbl = ctk.CTkLabel(outer,
                              text='ACE-Step  1.5',
                              font=ctk.CTkFont('Segoe UI', 18, 'bold'),
                              text_color=ACCENT,
                              cursor='hand2')
    title_lbl.pack(anchor='w')
    title_lbl.bind('<Button-1>',
                   lambda e: webbrowser.open('https://ace-step.github.io'))
    Tip(title_lbl, 'ace-step.github.io')

    ctk.CTkLabel(outer,
                 text='AI Music Generation',
                 font=ctk.CTkFont('Segoe UI', 9),
                 text_color=FG_DIM).pack(anchor='w', pady=(0, 14))

    # -- Big Launch Button --
    big_btn = ctk.CTkButton(
        outer,
        text='>>   Launch WebUI',
        font=ctk.CTkFont('Segoe UI', 11, 'bold'),
        fg_color=ACCENT, hover_color=ACCENT_HV,
        text_color=FG,
        height=46, corner_radius=6,
        command=lambda: action_launch_webui(_get_settings()))
    big_btn.pack(fill='x', pady=(0, 10))
    Tip(big_btn, 'Starts API + opens every HTML in /webui/.\n'
                 'Drop custom UIs in the folder, they all launch.')

    # -- API Toggle + Gradio Row --
    row = ctk.CTkFrame(outer, fg_color=BG)
    row.pack(fill='x', pady=(0, 8))
    row.columnconfigure(0, weight=1)
    row.columnconfigure(1, weight=1)

    # API indicator dot (canvas circle that changes color)
    api_indicator = ctk.CTkCanvas(row, width=12, height=12,
                                   bg=BG, highlightthickness=0)
    api_dot = api_indicator.create_oval(1, 1, 11, 11, fill=RED, outline='')

    def update_api_indicator(running):
        """Update the dot color from any thread."""
        color = GREEN if running else RED
        try:
            app.after(0, lambda: api_indicator.itemconfig(api_dot, fill=color))
        except Exception:
            pass

    # API toggle button
    api_frame = ctk.CTkFrame(row, fg_color='transparent')
    api_frame.grid(row=0, column=0, sticky='ew', padx=(0, 5))

    api_indicator.pack(in_=api_frame, side='left', padx=(0, 6))
    api_btn = ctk.CTkButton(
        api_frame,
        text='API Server',
        font=ctk.CTkFont('Segoe UI', 10),
        fg_color=BTN2_BG, hover_color=BTN2_HV,
        text_color=FG,
        height=36, corner_radius=6,
        command=lambda: action_toggle_api(_get_settings(), update_api_indicator))
    api_btn.pack(side='left', fill='x', expand=True)
    Tip(api_btn, 'Toggle the API server on/off.\n'
                 'Green dot = running. Red dot = stopped.')

    grad_btn = ctk.CTkButton(
        row,
        text='*  Gradio UI',
        font=ctk.CTkFont('Segoe UI', 10),
        fg_color=BTN2_BG, hover_color=BTN2_HV,
        text_color=FG,
        height=36, corner_radius=6,
        command=action_launch_gradio)
    grad_btn.grid(row=0, column=1, sticky='ew', padx=(5, 0))
    Tip(grad_btn, 'Gradio UI. Self-contained, no separate API needed.')

    # -- Poll API state every 3s to keep indicator honest --
    def _poll_api_state():
        try:
            running = is_api_running()
            update_api_indicator(running)
        except Exception:
            pass
        app.after(3000, _poll_api_state)
    app.after(3000, _poll_api_state)

    # -- Folder + Settings Row --
    row2 = ctk.CTkFrame(outer, fg_color=BG)
    row2.pack(fill='x', pady=(0, 8))
    row2.columnconfigure(0, weight=1)
    row2.columnconfigure(1, weight=0)

    folder_btn = ctk.CTkButton(
        row2,
        text='>>  WebUI Folder',
        font=ctk.CTkFont('Segoe UI', 10),
        fg_color=BTN2_BG, hover_color=BTN2_HV,
        text_color=FG,
        height=30, corner_radius=6,
        command=action_open_webui_folder)
    folder_btn.grid(row=0, column=0, sticky='ew', padx=(0, 5))
    Tip(folder_btn, 'Opens /webui/ folder.\nDrop .html files in here.')

    rick_btn = ctk.CTkButton(
        row2,
        text='?',
        font=ctk.CTkFont('Segoe UI', 9),
        fg_color=BG2, hover_color='#c00020',
        text_color='#3a3e52',
        width=40, height=30, corner_radius=6,
        command=lambda: webbrowser.open(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ'))
    rick_btn.grid(row=0, column=1, sticky='e')
    Tip(rick_btn, 'The tutorial.')

    # -- Update Backend Button --
    update_btn = ctk.CTkButton(
        outer,
        text='>>  Update ACE-Step Backend',
        font=ctk.CTkFont('Segoe UI', 10),
        fg_color=BTN2_BG, hover_color=BTN2_HV,
        text_color=FG,
        height=30, corner_radius=6,
        command=action_update_backend)
    update_btn.pack(fill='x', pady=(0, 8))
    Tip(update_btn, 'Pull latest ACE-Step code from GitHub.\nHandles local changes automatically.')

    # -- Collapsible Settings Panel --
    settings_header = ctk.CTkFrame(outer, fg_color=BG)
    settings_header.pack(fill='x', pady=(4, 0))

    settings_arrow = ctk.CTkLabel(
        settings_header, text='>>',
        font=ctk.CTkFont('Segoe UI', 9),
        text_color=FG_DIM, width=16)
    settings_arrow.pack(side='left')

    settings_toggle_lbl = ctk.CTkLabel(
        settings_header, text='Settings',
        font=ctk.CTkFont('Segoe UI', 10),
        text_color=FG_DIM, cursor='hand2')
    settings_toggle_lbl.pack(side='left', padx=(4, 0))

    settings_panel = ctk.CTkFrame(outer, fg_color=BG2, corner_radius=6)
    # Start hidden

    def toggle_settings(*_):
        if settings_open.get():
            settings_panel.pack_forget()
            settings_arrow.configure(text='>>')
            settings_open.set(False)
            app.geometry('440x380')
        else:
            settings_panel.pack(fill='x', pady=(4, 0), before=status_lbl)
            settings_arrow.configure(text='v')
            settings_open.set(True)
            app.geometry('440x460')

    settings_header.bind('<Button-1>', toggle_settings)
    settings_toggle_lbl.bind('<Button-1>', toggle_settings)
    settings_arrow.bind('<Button-1>', toggle_settings)

    # Settings content
    skip_llm_cb = ctk.CTkCheckBox(
        settings_panel,
        text='Skip LLM  (DiT-only mode)',
        font=ctk.CTkFont('Segoe UI', 10),
        variable=skip_llm_var,
        text_color=FG,
        fg_color=ACCENT, hover_color=ACCENT_HV,
        checkmark_color=FG,
        border_color=BTN2_HV,
        command=_save_current)
    skip_llm_cb.pack(anchor='w', padx=12, pady=(10, 4))
    Tip(skip_llm_cb,
        'Starts API without loading the LLM planner.\n'
        'DiT-only mode -- faster startup, lower RAM.\n'
        'Good for low-VRAM systems or quick tests.')

    show_term_cb = ctk.CTkCheckBox(
        settings_panel,
        text='Show terminal windows',
        font=ctk.CTkFont('Segoe UI', 10),
        variable=show_term_var,
        text_color=FG,
        fg_color=ACCENT, hover_color=ACCENT_HV,
        checkmark_color=FG,
        border_color=BTN2_HV,
        command=_save_current)
    show_term_cb.pack(anchor='w', padx=12, pady=(4, 10))
    Tip(show_term_cb,
        'Show the API server terminal window.\n'
        'Useful for debugging. Off by default.')

    # -- Status Bar --
    def _color_update(*_):
        status_lbl.configure(
            text_color=FG_RDY if status_var.get() == 'Ready.' else FG_DIM)

    status_lbl = ctk.CTkLabel(
        outer,
        textvariable=status_var,
        font=ctk.CTkFont('Segoe UI', 8),
        text_color=FG_RDY,
        anchor='w')
    status_lbl.pack(fill='x', pady=(8, 0))
    status_var.trace_add('write', _color_update)

    app.mainloop()
    # On exit: kill API and clean up
    stop_api()


if __name__ == '__main__':
    main()
