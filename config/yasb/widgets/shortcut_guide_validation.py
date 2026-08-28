from pydantic import Field

from core.validation.widgets.base_model import CustomBaseModel, KeybindingConfig


class ShortcutGuidePopupConfig(CustomBaseModel):
    width: int = Field(default=450, ge=400, le=1800)
    height: int = Field(default=325, ge=280, le=1000)
    blur: bool = True
    round_corners: bool = True
    round_corners_type: str = "normal"
    border_color: str = "#294454"
    dark_mode: bool = True


class ShortcutGuideConfig(CustomBaseModel):
    label: str = ""
    data_path: str
    popup: ShortcutGuidePopupConfig = ShortcutGuidePopupConfig()
    keybindings: list[KeybindingConfig] = []
