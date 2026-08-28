import json
import os
import time

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QCursor, QKeySequence, QShortcut
from PyQt6.QtWidgets import (
    QApplication,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from core.utils.utilities import PopupWidget, refresh_widget_style
from core.validation.widgets.yasb.shortcut_guide import ShortcutGuideConfig
from core.widgets.base import BaseWidget
from core.widgets.yasb.power_menu import PowerMenuWidget
from core.widgets.yasb.quick_launch import QuickLaunchWidget
from core.widgets.yasb.wallpapers import WallpapersWidget


class ShortcutGuideWidget(BaseWidget):
    """Frameless, searchable shortcut reference backed by our own JSON data."""

    validation_schema = ShortcutGuideConfig

    def __init__(self, config: ShortcutGuideConfig):
        super().__init__(class_name="shortcut-guide-widget")
        self.config = config
        self._menu = None
        self._rows = []
        self._init_container()
        self.build_widget_label(self.config.label, None)
        self.register_callback("toggle_shortcut_guide", self._toggle_popup)
        self.callback_left = "toggle_shortcut_guide"

    def _load_sections(self):
        path = os.path.expandvars(os.path.expanduser(self.config.data_path))
        with open(path, encoding="utf-8") as stream:
            return json.load(stream)["sections"]

    def _toggle_popup(self):
        if self._menu is not None:
            try:
                if self._menu.isVisible():
                    self._menu.close()
                else:
                    self._menu.show()
                    self._menu.activateWindow()
                return
            except RuntimeError:
                self._menu = None

        popup = self.config.popup
        self._menu = PopupWidget(
            self,
            blur=popup.blur,
            round_corners=popup.round_corners,
            round_corners_type=popup.round_corners_type,
            border_color=popup.border_color,
            dark_mode=popup.dark_mode,
            persistent=True,
        )
        self._menu.setProperty("class", "shortcut-guide-popup")
        self._menu.setFixedSize(popup.width, popup.height)

        root = QVBoxLayout(self._menu)
        root.setContentsMargins(12, 10, 12, 10)
        root.setSpacing(7)

        search = QLineEdit()
        search.setProperty("class", "shortcut-search")
        search.setPlaceholderText("Type to filter shortcuts...")
        root.addWidget(search)

        scroll = QScrollArea()
        scroll.setProperty("class", "shortcut-scroll")
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        root.addWidget(scroll)

        contents = QWidget()
        contents.setProperty("class", "shortcut-contents")
        content_layout = QVBoxLayout(contents)
        content_layout.setContentsMargins(0, 0, 0, 0)
        content_layout.setSpacing(4)
        content_layout.setAlignment(Qt.AlignmentFlag.AlignTop)
        scroll.setWidget(contents)

        self._rows = []
        for section in self._load_sections():
            header = QLabel(section["title"])
            header.setProperty("class", "shortcut-section")
            content_layout.addWidget(header)
            section_rows = []
            for item in section["items"]:
                row = self._build_row(item["keys"], item["description"])
                content_layout.addWidget(row)
                section_rows.append((row, item))
            self._rows.append((header, section_rows))

        search.textChanged.connect(self._filter_rows)
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self._menu).activated.connect(self._menu.close)

        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        area = screen.availableGeometry()
        x = area.x() + (area.width() - popup.width) // 2
        y = area.y() + (area.height() - popup.height) // 2
        self._menu.move(x, y)
        self._menu.show()
        self._menu.activateWindow()
        search.setFocus()

    def _build_row(self, keys, description):
        row = QFrame()
        row.setProperty("class", "shortcut-row")
        layout = QHBoxLayout(row)
        layout.setContentsMargins(6, 3, 7, 3)
        layout.setSpacing(4)

        keys_frame = QFrame()
        keys_frame.setProperty("class", "shortcut-keys")
        keys_layout = QHBoxLayout(keys_frame)
        keys_layout.setContentsMargins(0, 0, 0, 0)
        keys_layout.setSpacing(3)
        for index, key in enumerate(keys):
            button = QPushButton(key)
            button.setProperty("class", "shortcut-key special" if key in ("Caps", "Win") else "shortcut-key")
            button.setEnabled(False)
            keys_layout.addWidget(button)
            if index < len(keys) - 1:
                plus = QLabel("+")
                plus.setProperty("class", "shortcut-plus")
                keys_layout.addWidget(plus)
        keys_layout.addStretch()
        keys_frame.setFixedWidth(205)

        command = QLabel(description)
        command.setProperty("class", "shortcut-description")
        layout.addWidget(keys_frame)
        layout.addWidget(command, 1)
        refresh_widget_style(row)
        return row

    def _filter_rows(self, text):
        query = text.strip().lower()
        for header, rows in self._rows:
            visible = False
            for row, item in rows:
                haystack = " ".join(item["keys"] + [item["description"]]).lower()
                match = not query or query in haystack
                row.setVisible(match)
                visible = visible or match
            header.setVisible(visible)


class _OverlayCoordinator:
    """Keep the configured full-size YASB overlays mutually exclusive."""

    _active = None
    _pending = None
    _generation = 0
    _busy_until = 0.0

    @classmethod
    def toggle(cls, key, is_visible, hide, show, fade_out_ms):
        cls._generation += 1
        generation = cls._generation

        if cls._pending and cls._pending[0] == key:
            cls._pending = None
            return

        if cls._active and cls._active[0] == key and is_visible():
            hide()
            cls._active = None
            cls._pending = None
            cls._busy_until = time.monotonic() + fade_out_ms / 1000
            return

        if cls._active:
            _, active_visible, active_hide, active_fade_ms = cls._active
            if active_visible():
                active_hide()
                cls._busy_until = time.monotonic() + active_fade_ms / 1000
            cls._active = None

        cls._pending = (key, is_visible, hide, show, fade_out_ms)
        remaining_ms = max(0, round((cls._busy_until - time.monotonic()) * 1000))
        QTimer.singleShot(remaining_ms, lambda: cls._show_pending(generation))

    @classmethod
    def _show_pending(cls, generation):
        if generation != cls._generation or not cls._pending:
            return
        entry = cls._pending
        cls._pending = None
        entry[3]()
        cls._active = (entry[0], entry[1], entry[2], entry[4])


class CoordinatedQuickLaunchWidget(QuickLaunchWidget):
    def _toggle_quick_launch(self):
        _OverlayCoordinator.toggle(
            "quick_launch", self._is_overlay_visible, self._hide_popup, self._show_popup, 50
        )

    def _is_overlay_visible(self):
        return bool(
            self._popup
            and self._popup.isVisible()
            and not getattr(self._popup, "_is_closing", False)
        )


class CoordinatedShortcutGuideWidget(ShortcutGuideWidget):
    def _toggle_popup(self):
        _OverlayCoordinator.toggle(
            "shortcut_guide", self._is_overlay_visible, self._hide_overlay, self._show_overlay, 180
        )

    def _is_overlay_visible(self):
        return bool(
            self._menu
            and self._menu.isVisible()
            and not getattr(self._menu, "_is_closing", False)
        )

    def _hide_overlay(self):
        if self._menu:
            self._menu.hide_animated()

    def _show_overlay(self):
        ShortcutGuideWidget._toggle_popup(self)


class CoordinatedWallpapersWidget(WallpapersWidget):
    def _toggle_widget(self):
        _OverlayCoordinator.toggle(
            "wallpapers", self._is_overlay_visible, self._hide_overlay, self._show_overlay, 120
        )

    def _is_overlay_visible(self):
        return bool(self._image_gallery and self._image_gallery.isVisible())

    def _hide_overlay(self):
        if self._image_gallery:
            self._image_gallery.fade_out_and_close_gallery()

    def _show_overlay(self):
        WallpapersWidget._toggle_widget(self)


class CoordinatedPowerMenuWidget(PowerMenuWidget):
    def _show_main_window(self):
        _OverlayCoordinator.toggle(
            "power_menu",
            self._is_overlay_visible,
            self._hide_overlay,
            self._show_overlay,
            self.config.animation_duration,
        )

    def _is_overlay_visible(self):
        if self.config.menu_style == "popup":
            return bool(
                self._popup
                and self._popup.isVisible()
                and not getattr(self._popup, "_is_closing", False)
            )
        return bool(self.main_window and self.main_window.isVisible())

    def _hide_overlay(self):
        if self.config.menu_style == "popup":
            if self._popup:
                self._popup.hide_animated()
            return
        if self.main_window and self.main_window.isVisible():
            self.main_window.fade_out()
            self.main_window.overlay.fade_out()

    def _show_overlay(self):
        PowerMenuWidget._show_main_window(self)
