-- HUD tool (libs/hud.lua): hides game HUD pieces or shows them as world widgets on the controllers, HMD,
-- hand bones or pawn sockets. Guide: 0. HUD Tool\HUD_TOOL_GUIDE.md
--   "HUD Dev" tab: build elements (pick a game widget / part, mode, target, placement); its Save button writes
--                  data/hud_parameters.json, which ships with the mod. Hidden unless DEVELOPER_MODE is true.
--   "HUD" tab:     players' on/off, size and opacity per element (data/hud_player_config.json).
-- "Immersive HUD" in the Hellraiser VR panel switches every element on (the saved attachments) or off (the game's
-- own flat HUD, untouched).
-- Exposure: Hellraiser pins auto-exposure in its post-process volumes, so the "postprocess" source compensates
-- world panels exactly (confirmed 2026-10-13).

local configui = require("libs/configui")
local hud = require("libs/hud")

local DEVELOPER_MODE = false -- true shows the HUD Dev tab for building / editing elements; false for release
local PLAYER_TAB = false     -- "HUD" shows the per-element player tab; false hides it (elements use their saved defaults)

hud.setup({
    developerMode = DEVELOPER_MODE,
    playerTab = PLAYER_TAB,
    exposure = "postprocess",
    logFile = "hud_log.txt",
    logLevel = LogLevel.Warning,
})

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 2.7, label = "Immersive HUD", layout = {
    { widgetType = "checkbox", id = "hr_immersive_hud", label = "Immersive HUD (HUD elements on the hands / in view instead of the flat HUD)", initialValue = true },
}})

-- configui.getValue is nil until the panel exists (zz_hellraiser_vr_panel.lua), so nil = the initial value (on)
configui.onCreateOrUpdate("hr_immersive_hud", function(value)
    hud.setEnabled(value ~= false)
end)
