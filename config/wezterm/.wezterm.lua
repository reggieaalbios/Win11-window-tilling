local wezterm = require("wezterm")

local config = wezterm.config_builder()

-- Start Windows PowerShell instead of Command Prompt.
config.default_prog = { "powershell.exe", "-NoLogo" }

-- Preserve the native resize frame from HWND creation so Komorebi can assign
-- the correct tile and rounded border. Caps+Enter removes caption controls
-- only after that initial placement has completed.
config.window_decorations = "RESIZE"
config.enable_tab_bar = false
config.pane_focus_follows_mouse = true

-- Match the prompt with Catppuccin Mocha and use WezTerm's bundled Nerd Font
-- symbols as a fallback for every Oh My Posh icon.
config.color_scheme = "Catppuccin Mocha"
config.colors = {
  background = "#020a19",
}
config.window_background_opacity = 0.50
config.win32_system_backdrop = "Acrylic"

-- The wallpaper theme engine owns colors only. Geometry, Acrylic, the native
-- resize frame, and every keybinding remain in this stable configuration.
local theme_ok, generated_theme = pcall(dofile, wezterm.config_dir .. "\\wwt-theme.lua")
if theme_ok and generated_theme then
  config.colors = generated_theme.colors
  config.window_background_opacity = generated_theme.window_background_opacity or 0.50
end
config.font = wezterm.font_with_fallback({
  "JetBrains Mono",
  "Symbols Nerd Font Mono",
})

-- Match the native startup grid to a full Komorebi workspace tile at the
-- current 144-DPI display scale.  This minimizes the resize Komorebi needs
-- to apply after WezTerm creates its first visible frame.
config.initial_cols = 133
config.initial_rows = 30

-- Rebuild a two-pane split around the active pane while preserving both
-- running terminal processes.  WezTerm's CLI can move an existing pane into
-- a new split; no shell is closed or restarted.
local function orient_two_panes(active_pane, direction)
  local tab = active_pane:tab()
  local other_pane

  for _, candidate in ipairs(tab:panes()) do
    if candidate:pane_id() ~= active_pane:pane_id() then
      other_pane = candidate
      break
    end
  end

  if not other_pane then
    return
  end

  local active_id = tostring(active_pane:pane_id())
  local other_id = tostring(other_pane:pane_id())

  -- Put the other live pane in a temporary tab, then move it back into a
  -- newly oriented split.  The temporary tab disappears automatically.
  other_pane:move_to_new_tab()
  wezterm.background_child_process({
    wezterm.executable_dir .. "\\wezterm.exe",
    "cli",
    "split-pane",
    "--pane-id",
    active_id,
    direction,
    "--percent",
    "50",
    "--move-pane-id",
    other_id,
  })
end

local cycle_two_pane_layout = wezterm.action_callback(function(window, pane)
  local tab = pane:tab()
  local pane_info = tab:panes_with_info()

  if #pane_info ~= 2 then
    window:toast_notification(
      "WezTerm layout",
      "Ctrl+Shift+L requires exactly two panes",
      nil,
      2500
    )
    return
  end

  local is_zoomed = false
  for _, info in ipairs(pane_info) do
    if info.is_zoomed then
      is_zoomed = true
      break
    end
  end

  if is_zoomed then
    -- Focused -> top/bottom, completing the three-state cycle.
    tab:set_zoomed(false)
    orient_two_panes(pane, "--bottom")
    return
  end

  local side_by_side = pane_info[1].top == pane_info[2].top
  if side_by_side then
    -- Left/right -> focused pane only.
    tab:set_zoomed(true)
  else
    -- Top/bottom -> left/right.
    orient_two_panes(pane, "--right")
  end
end)

config.keys = {
  -- Split into top and bottom panes, with a new PowerShell session below.
  {
    key = "Enter",
    mods = "CTRL|SHIFT",
    action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }),
  },

  -- Cycle: top/bottom -> left/right -> focused pane -> top/bottom.
  {
    key = "L",
    mods = "CTRL|SHIFT",
    action = cycle_two_pane_layout,
  },

  -- Move between panes without touching the mouse.
  {
    key = "UpArrow",
    mods = "CTRL|SHIFT",
    action = wezterm.action.ActivatePaneDirection("Up"),
  },
  {
    key = "DownArrow",
    mods = "CTRL|SHIFT",
    action = wezterm.action.ActivatePaneDirection("Down"),
  },
  {
    key = "LeftArrow",
    mods = "CTRL|SHIFT",
    action = wezterm.action.ActivatePaneDirection("Left"),
  },
  {
    key = "RightArrow",
    mods = "CTRL|SHIFT",
    action = wezterm.action.ActivatePaneDirection("Right"),
  },
}

return config
