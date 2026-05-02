#!/usr/bin/env python3
"""
z13rgb — RGB control GUI for the ASUS ROG Flow Z13 (GZ302).

Independent control over the keyboard backlight and rear lightbar via z13ctl.
Live preview: any change applies immediately (debounced).

Modes:        static, breathe, color cycle, rainbow, strobe
Brightness:   off / low / medium / high
Speed:        slow / normal / fast (animated modes)

Requires:  z13ctl on PATH, PyQt6
Project:   GZ302 Kali KDE setup kit
"""

from __future__ import annotations

import shutil
import subprocess
import sys

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QColor, QFont, QIcon, QFontDatabase
from PyQt6.QtWidgets import (
    QApplication,
    QColorDialog,
    QComboBox,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QStatusBar,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)


# ---------- z13ctl interface constants ----------
MODE_DISPLAY_TO_FLAG = {
    "Static": "static",
    "Breathe": "breathe",
    "Color Cycle": "cycle",
    "Rainbow": "rainbow",
    "Strobe": "strobe",
}
BRIGHTNESS_DISPLAY_TO_FLAG = {
    "Off": "off",
    "Low": "low",
    "Medium": "medium",
    "High": "high",
}
SPEED_DISPLAY_TO_FLAG = {
    "Slow": "slow",
    "Normal": "normal",
    "Fast": "fast",
}

# Modes that accept a primary color
COLORED_MODES = {"static", "breathe", "strobe"}
# Modes that accept a secondary color (--color2)
TWO_COLOR_MODES = {"breathe"}
# Modes that accept --speed
ANIMATED_MODES = {"breathe", "cycle", "rainbow", "strobe"}


# ---------- theme ----------
THEME_QSS = """
QMainWindow, QWidget#root {
    background-color: #0d0e12;
}

QLabel#header {
    font-size: 18px;
    font-weight: 900;
    letter-spacing: 6px;
    color: #00d4ff;
    padding: 16px 0;
    background: qlineargradient(x1:0, y1:0, x2:0, y2:1,
        stop:0 #14171f, stop:1 #0d0e12);
    border-bottom: 1px solid #2a2e38;
}

QLabel#subheader {
    color: #5b6270;
    font-size: 9px;
    letter-spacing: 2px;
    font-weight: 600;
    padding-bottom: 14px;
    background: #0d0e12;
}

QTabWidget::pane {
    background: #12141a;
    border: 1px solid #2a2e38;
    top: -1px;
}

QTabBar::tab {
    background: #0d0e12;
    color: #6b7280;
    padding: 11px 32px;
    border: 1px solid #2a2e38;
    border-bottom: none;
    font-weight: 700;
    letter-spacing: 2px;
    font-size: 10px;
    margin-right: 1px;
}

QTabBar::tab:selected {
    background: #12141a;
    color: #00d4ff;
    border-bottom: 2px solid #00d4ff;
}

QTabBar::tab:hover:!selected {
    color: #c8cdd5;
}

QGroupBox {
    background: #181b23;
    border: 1px solid #2a2e38;
    border-radius: 3px;
    margin-top: 14px;
    padding: 18px 14px 14px 14px;
    font-weight: 700;
}

QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    left: 10px;
    padding: 0 6px;
    color: #00d4ff;
    background: #181b23;
    font-size: 9px;
    letter-spacing: 2px;
}

QGroupBox:disabled {
    color: #44485258;
}
QGroupBox:disabled::title {
    color: #44485288;
}

QLabel {
    color: #c8cdd5;
    font-size: 11px;
}

QLabel#fieldLabel {
    color: #8b9098;
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 1.5px;
}

QComboBox {
    background: #0d0e12;
    color: #e8eaed;
    border: 1px solid #2a2e38;
    border-radius: 2px;
    padding: 8px 12px;
    min-height: 22px;
    font-size: 11px;
}
QComboBox:hover  { border-color: #00d4ff; }
QComboBox:focus  { border-color: #00d4ff; }
QComboBox::drop-down { border: none; width: 22px; }
QComboBox::down-arrow {
    image: none;
    border-left: 4px solid transparent;
    border-right: 4px solid transparent;
    border-top: 4px solid #00d4ff;
    margin-right: 8px;
}
QComboBox QAbstractItemView {
    background: #181b23;
    color: #e8eaed;
    border: 1px solid #00d4ff;
    selection-background-color: #00d4ff;
    selection-color: #0d0e12;
    outline: none;
    padding: 2px;
}

QPushButton {
    background: #181b23;
    color: #e8eaed;
    border: 1px solid #2a2e38;
    border-radius: 2px;
    padding: 9px 18px;
    font-weight: 600;
    letter-spacing: 0.5px;
    font-size: 11px;
}
QPushButton:hover  { background: #1f232c; border-color: #00d4ff; }
QPushButton:pressed { background: #00d4ff; color: #0d0e12; }
QPushButton:disabled {
    color: #44485270;
    background: #14161c;
    border-color: #1c1f26;
}

QPushButton#alloff {
    background: transparent;
    color: #ff5c5c;
    border: 1px solid #ff5c5c;
    padding: 13px;
    font-weight: 800;
    letter-spacing: 4px;
    font-size: 10px;
}
QPushButton#alloff:hover {
    background: #ff5c5c;
    color: #0d0e12;
}
QPushButton#alloff:pressed {
    background: #cc4040;
    color: #0d0e12;
}

QPushButton#deviceOff {
    border-color: #6b3030;
    color: #c87070;
}
QPushButton#deviceOff:hover {
    background: #2a1a1a;
    border-color: #ff5c5c;
    color: #ff5c5c;
}

QStatusBar {
    background: #0d0e12;
    color: #5b6270;
    border-top: 1px solid #2a2e38;
    font-family: "JetBrains Mono", "Fira Code", "DejaVu Sans Mono", monospace;
    font-size: 10px;
    padding: 4px 12px;
}
"""


def contrast_text_color(qcolor: QColor) -> str:
    """Return #000 or #fff for legible text on the given background."""
    yiq = (qcolor.red() * 299 + qcolor.green() * 587 + qcolor.blue() * 114) / 1000
    return "#000000" if yiq > 128 else "#FFFFFF"


def hex_no_hash(qcolor: QColor) -> str:
    """Return RRGGBB without leading #."""
    return qcolor.name().lstrip("#").upper()


class DeviceControl(QWidget):
    """Independent RGB controls for one device (keyboard or lightbar)."""

    def __init__(self, device: str, parent=None) -> None:
        super().__init__(parent)
        self.device = device  # "keyboard" or "lightbar"

        # State
        self.color = QColor("#FF0000")
        self.color2 = QColor("#0066FF")
        # Tracks brightness right before user clicks "Turn off" so we can
        # restore the same level when they click "Turn on" again.
        self._last_on_brightness: str = "High"

        # Debounce timer for live-apply
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self.apply_now)

        self._build_ui()
        self._wire()
        self._refresh_color_btn(self.color_btn, self.color)
        self._refresh_color_btn(self.color2_btn, self.color2)
        self._update_enabled_states()

    # ---------- UI construction ----------
    def _build_ui(self) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(20, 20, 20, 12)
        outer.setSpacing(14)

        # Mode
        mode_box = QGroupBox("MODE")
        mode_layout = QVBoxLayout(mode_box)
        self.mode_combo = QComboBox()
        self.mode_combo.addItems(list(MODE_DISPLAY_TO_FLAG.keys()))
        mode_layout.addWidget(self.mode_combo)
        outer.addWidget(mode_box)

        # Colors
        self.color_box = QGroupBox("COLOR")
        cl = QGridLayout(self.color_box)
        cl.setHorizontalSpacing(10)
        cl.setVerticalSpacing(8)
        cl.setColumnStretch(1, 1)

        primary_label = QLabel("PRIMARY")
        primary_label.setObjectName("fieldLabel")
        cl.addWidget(primary_label, 0, 0)
        self.color_btn = QPushButton()
        self.color_btn.setMinimumHeight(36)
        cl.addWidget(self.color_btn, 0, 1)

        self.secondary_label = QLabel("SECONDARY")
        self.secondary_label.setObjectName("fieldLabel")
        cl.addWidget(self.secondary_label, 1, 0)
        self.color2_btn = QPushButton()
        self.color2_btn.setMinimumHeight(36)
        cl.addWidget(self.color2_btn, 1, 1)

        outer.addWidget(self.color_box)

        # Brightness + speed in a row
        bs_row = QHBoxLayout()
        bs_row.setSpacing(12)

        bright_box = QGroupBox("BRIGHTNESS")
        bl = QVBoxLayout(bright_box)
        self.bright_combo = QComboBox()
        self.bright_combo.addItems(list(BRIGHTNESS_DISPLAY_TO_FLAG.keys()))
        self.bright_combo.setCurrentText("High")
        bl.addWidget(self.bright_combo)
        bs_row.addWidget(bright_box, 1)

        self.speed_box = QGroupBox("SPEED")
        sl = QVBoxLayout(self.speed_box)
        self.speed_combo = QComboBox()
        self.speed_combo.addItems(list(SPEED_DISPLAY_TO_FLAG.keys()))
        self.speed_combo.setCurrentText("Normal")
        sl.addWidget(self.speed_combo)
        bs_row.addWidget(self.speed_box, 1)

        outer.addLayout(bs_row)

        outer.addStretch(1)

        # Bottom buttons: per-device off + identify
        btn_row = QHBoxLayout()
        btn_row.setSpacing(8)
        self.off_btn = QPushButton(f"TURN {self.device.upper()} OFF")
        self.off_btn.setObjectName("deviceOff")
        btn_row.addWidget(self.off_btn)
        outer.addLayout(btn_row)

    def _wire(self) -> None:
        self.mode_combo.currentTextChanged.connect(self._on_mode_changed)
        self.bright_combo.currentTextChanged.connect(self._on_brightness_changed)
        self.speed_combo.currentTextChanged.connect(self._schedule)
        self.color_btn.clicked.connect(lambda: self._pick_color(primary=True))
        self.color2_btn.clicked.connect(lambda: self._pick_color(primary=False))
        self.off_btn.clicked.connect(self._turn_off)

    def _on_brightness_changed(self, _text: str) -> None:
        self._refresh_off_btn_label()
        self._schedule()

    # ---------- behavior ----------
    def _on_mode_changed(self, _text: str) -> None:
        self._update_enabled_states()
        self._schedule()

    def _update_enabled_states(self) -> None:
        mode = MODE_DISPLAY_TO_FLAG[self.mode_combo.currentText()]
        self.color_btn.setEnabled(mode in COLORED_MODES)
        self.color2_btn.setEnabled(mode in TWO_COLOR_MODES)
        self.secondary_label.setEnabled(mode in TWO_COLOR_MODES)
        self.speed_box.setEnabled(mode in ANIMATED_MODES)

    def _refresh_color_btn(self, btn: QPushButton, color: QColor) -> None:
        hex_str = "#" + hex_no_hash(color)
        text_col = contrast_text_color(color)
        btn.setText(hex_str)
        # Stylesheet here overrides the global QPushButton style for this widget.
        btn.setStyleSheet(
            f"QPushButton {{"
            f"  background: {hex_str};"
            f"  color: {text_col};"
            f"  font-weight: 800;"
            f"  letter-spacing: 2px;"
            f"  border: 1px solid #2a2e38;"
            f"  border-radius: 2px;"
            f"  padding: 9px 18px;"
            f"  font-size: 11px;"
            f"}}"
            f"QPushButton:hover {{ border: 2px solid #00d4ff; }}"
            f"QPushButton:disabled {{"
            f"  background: #1a1d24; color: #44485270; border-color: #1c1f26;"
            f"}}"
        )

    def _pick_color(self, *, primary: bool) -> None:
        target_color = self.color if primary else self.color2
        title = (
            f"{self.device.title()} — "
            f"{'primary' if primary else 'secondary'} color"
        )
        # Use ShowAlphaChannel = false (z13ctl doesn't support alpha)
        new_color = QColorDialog.getColor(target_color, self, title)
        if not new_color.isValid():
            return
        if primary:
            self.color = new_color
            self._refresh_color_btn(self.color_btn, self.color)
        else:
            self.color2 = new_color
            self._refresh_color_btn(self.color2_btn, self.color2)
        self._schedule()

    def _schedule(self) -> None:
        """Debounce 250ms before applying — avoids hidraw spam on rapid changes."""
        self._timer.start(250)

    def apply_now(self) -> None:
        self._timer.stop()
        cmd = self._build_command()
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=8, check=False
            )
            if result.returncode == 0:
                stdout = (result.stdout or "").strip().splitlines()
                summary = stdout[-1] if stdout else " ".join(cmd)
                self._set_status(f"{self.device}: {summary}")
            else:
                err = (result.stderr or result.stdout or "unknown").strip()
                self._set_status(f"{self.device} ERROR: {err}", error=True)
        except subprocess.TimeoutExpired:
            self._set_status(f"{self.device} ERROR: timeout", error=True)
        except FileNotFoundError:
            self._set_status("z13ctl not found on PATH", error=True)
        except Exception as e:  # pragma: no cover  (defensive)
            self._set_status(f"{self.device} ERROR: {e}", error=True)

    def _build_command(self) -> list[str]:
        mode = MODE_DISPLAY_TO_FLAG[self.mode_combo.currentText()]
        brightness = BRIGHTNESS_DISPLAY_TO_FLAG[self.bright_combo.currentText()]
        speed = SPEED_DISPLAY_TO_FLAG[self.speed_combo.currentText()]
        cmd = [
            "z13ctl", "apply",
            "--device", self.device,
            "--mode", mode,
            "--brightness", brightness,
        ]
        if mode in COLORED_MODES:
            cmd += ["--color", hex_no_hash(self.color)]
        if mode in TWO_COLOR_MODES:
            cmd += ["--color2", hex_no_hash(self.color2)]
        if mode in ANIMATED_MODES:
            cmd += ["--speed", speed]
        return cmd

    def _turn_off(self) -> None:
        """Toggle the device off ↔ back on.

        When 'on': sends --brightness off, remembers the last brightness
        choice, flips the button label to 'TURN ON'.
        When 'off': re-applies whatever the GUI currently shows (which may
        be the dropdown back at 'High' or whatever the user just chose).
        """
        currently_off = self.bright_combo.currentText() == "Off"

        if currently_off:
            # Restore: use saved brightness if we have one, else High
            restore_to = self._last_on_brightness or "High"
            self.bright_combo.blockSignals(True)
            self.bright_combo.setCurrentText(restore_to)
            self.bright_combo.blockSignals(False)
            self.apply_now()
            self._refresh_off_btn_label()
            self._set_status(f"{self.device}: on ({restore_to.lower()})")
            return

        # Going off: remember what brightness we were at
        self._last_on_brightness = self.bright_combo.currentText()
        try:
            result = subprocess.run(
                ["z13ctl", "apply", "--device", self.device, "--brightness", "off"],
                capture_output=True, text=True, timeout=5, check=False,
            )
            if result.returncode == 0:
                self._set_status(f"{self.device}: off")
                self.bright_combo.blockSignals(True)
                self.bright_combo.setCurrentText("Off")
                self.bright_combo.blockSignals(False)
                self._refresh_off_btn_label()
            else:
                self._set_status(
                    f"{self.device} OFF ERROR: {(result.stderr or '').strip()}",
                    error=True,
                )
        except Exception as e:
            self._set_status(f"{self.device} OFF ERROR: {e}", error=True)

    def _refresh_off_btn_label(self) -> None:
        """Flip the button label between 'TURN OFF' and 'TURN ON'."""
        if self.bright_combo.currentText() == "Off":
            self.off_btn.setText(f"TURN {self.device.upper()} ON")
        else:
            self.off_btn.setText(f"TURN {self.device.upper()} OFF")

    def _set_status(self, msg: str, *, error: bool = False) -> None:
        win = self.window()
        if isinstance(win, MainWindow):
            win.set_status(msg, error=error)


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Z13 RGB Control")
        self.setMinimumSize(540, 600)
        self.resize(560, 640)

        if not shutil.which("z13ctl"):
            QMessageBox.critical(
                self,
                "z13ctl not found",
                "Could not find <b>z13ctl</b> on PATH.\n\n"
                "This GUI requires z13ctl to be installed and accessible. "
                "Install it via the GZ302 Kali setup script.",
            )
            sys.exit(2)

        self._build_ui()

    def _build_ui(self) -> None:
        root = QWidget()
        root.setObjectName("root")
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Header
        header = QLabel("Z13   RGB   CONTROL")
        header.setObjectName("header")
        header.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(header)

        sub = QLabel("ASUS  ROG  FLOW  Z13   ·   GZ302   ·   STRIX  HALO")
        sub.setObjectName("subheader")
        sub.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(sub)

        # Tabs
        self.tabs = QTabWidget()
        self.kbd = DeviceControl("keyboard")
        self.bar = DeviceControl("lightbar")
        self.tabs.addTab(self.kbd, "  KEYBOARD  ")
        self.tabs.addTab(self.bar, "  LIGHTBAR  ")
        layout.addWidget(self.tabs, 1)

        # All-off bar
        all_off_row = QHBoxLayout()
        all_off_row.setContentsMargins(20, 12, 20, 12)
        self.all_off_btn = QPushButton("ALL  LIGHTING  OFF")
        self.all_off_btn.setObjectName("alloff")
        self.all_off_btn.clicked.connect(self._all_off)
        all_off_row.addWidget(self.all_off_btn)
        layout.addLayout(all_off_row)

        # Status bar
        self.sb = QStatusBar()
        self.setStatusBar(self.sb)
        self.set_status("ready")

    def set_status(self, msg: str, *, error: bool = False) -> None:
        prefix = "× " if error else "› "
        self.sb.showMessage(prefix + msg, 6000)

    def _all_off(self) -> None:
        try:
            result = subprocess.run(
                ["z13ctl", "off"],
                capture_output=True, text=True, timeout=5, check=False,
            )
            if result.returncode == 0:
                self.set_status("all lighting off")
                self.kbd.bright_combo.setCurrentText("Off")
                self.bar.bright_combo.setCurrentText("Off")
            else:
                self.set_status(
                    f"OFF ERROR: {(result.stderr or '').strip()}", error=True
                )
        except Exception as e:
            self.set_status(f"OFF ERROR: {e}", error=True)


def _setup_fonts(app: QApplication) -> None:
    """Try to use a nicer default font if available, else fall back gracefully."""
    db_families = set(QFontDatabase.families())
    candidates = [
        "Inter", "IBM Plex Sans", "Cantarell", "Noto Sans",
        "DejaVu Sans", "Liberation Sans",
    ]
    for name in candidates:
        if name in db_families:
            f = QFont(name, 10)
            app.setFont(f)
            return


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("z13rgb")
    app.setApplicationDisplayName("Z13 RGB Control")
    app.setDesktopFileName("z13rgb")
    app.setStyleSheet(THEME_QSS)

    _setup_fonts(app)

    win = MainWindow()
    # Try a sensible icon
    icon = QIcon.fromTheme("preferences-desktop-color")
    if not icon.isNull():
        win.setWindowIcon(icon)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
