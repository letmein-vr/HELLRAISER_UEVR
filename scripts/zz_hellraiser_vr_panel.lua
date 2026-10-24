-- Builds the single user-facing "Hellraiser VR" panel in the UEVR overlay (same pattern as the OW2 profile's
-- zz_ow2_vr_panel.lua).
--
-- Every game script registers its settings as a section in _G.HR_SECTIONS ({ order, label, layout }) instead of
-- creating its own panel; this file loads LAST (UEVR loads scripts in case-insensitive name order, hence zz_) and
-- turns the sections into one panel with a collapsible tree node per section. Widget ids are global in configui,
-- so the owning scripts use configui.getValue / onUpdate / setLabel directly. Values are saved together in
-- data/hellraiser_vr_config.json. configui.getValue returns nil until this panel exists (first tick only), so
-- every reader treats nil as the widget's initial value.

local configui = require('libs/configui')

local PANEL_LABEL = "Hellraiser VR"
local SAVE_FILE   = "hellraiser_vr_config"

local sections = _G.HR_SECTIONS or {}
table.sort(sections, function(a, b) return (a.order or 99) < (b.order or 99) end)

-- Main panel vs "Dev Config" (2026-10-12). The main sections show what a normal player needs; the detailed tuning of
-- each feature sits in one collapsed "Dev Config" node at the bottom, with a sub-node per section. Keyed by section
-- label: true = the whole section is dev; a list = the widget ids that STAY in the main section (everything else of
-- that section, including its texts and spacers, goes to dev). Sections not listed here stay entirely in the main panel.
local DEV_RULES = {
    ["IK Arms + Body"]    = true,
    ["Player Capsule"]    = true,
    ["Inspected Items"]   = true,
    ["Keypads"]           = true,
    ["Menus"]             = true,
    ["Cutscenes & Videos"] = true,
    ["Hands"]             = { "hands_mode" },
    ["Two-Handed Aiming"] = { "th_enabled" },
    ["Holsters"]          = { "hz_enabled" },
    ["Physical Melee"]    = { "pm_enabled", "pm_contact_speed", "pm_hit_buffer", "pm_reach" },
    ["Genesis Cube"]      = { "gc_target_yaw", "gc_target_pitch", "gc_throw_yaw", "gc_throw_pitch" },
    ["Throwables"]        = { "thr_enabled" },
    ["Manual Reload"]     = { "mr_enabled", "mr_rack" },
}

-- Sections whose main part is shown without a collapsible header: plain toggles together at the top of the panel
-- (their dev part still gets its own node under Dev Config).
local FLAT_SECTIONS = {
    ["Hands"]             = true,
    ["Two-Handed Aiming"] = true,
    ["Holsters"]          = true,
    ["Controls"]          = true,
    ["Throwables"]        = true,
    ["Manual Reload"]     = true,
}

local function splitSection(section)
    local rule = DEV_RULES[section.label]
    local items = section.layout or {}
    if rule == nil then return items, {} end
    if rule == true then return {}, items end
    local keep = {}
    for _, id in ipairs(rule) do keep[id] = true end
    local main, dev = {}, {}
    for _, item in ipairs(items) do
        table.insert((item.id ~= nil and keep[item.id]) and main or dev, item)
    end
    return main, dev
end

local function addNode(target, id, label, items, open)
    table.insert(target, { widgetType = "tree_node", id = id, label = label, initialOpen = open })
    for _, item in ipairs(items) do table.insert(target, item) end
    table.insert(target, { widgetType = "spacing" })
    table.insert(target, { widgetType = "tree_pop" })
end

local layout, devLayout, flatLayout = {}, {}, {}
if #sections == 0 then
    table.insert(layout, { widgetType = "text", label = "No sections registered (scripts/*.lua load order?)" })
end
local mainCount = 0
for i, section in ipairs(sections) do
    local label = section.label or ("Section " .. i)
    local main, dev = splitSection(section)
    if #main > 0 and FLAT_SECTIONS[label] then
        for _, item in ipairs(main) do table.insert(flatLayout, item) end
    elseif #main > 0 then
        mainCount = mainCount + 1
        addNode(layout, "hr_section_" .. i, label, main, mainCount == 1)
    end
    if #dev > 0 then addNode(devLayout, "hr_dev_section_" .. i, label, dev, false) end
end
if #flatLayout > 0 then
    table.insert(flatLayout, { widgetType = "spacing" })
    for i = #flatLayout, 1, -1 do table.insert(layout, 1, flatLayout[i]) end
end
if #devLayout > 0 then
    table.insert(layout, { widgetType = "tree_node", id = "hr_dev_config", label = "Dev Config", initialOpen = false })
    for _, item in ipairs(devLayout) do table.insert(layout, item) end
    table.insert(layout, { widgetType = "tree_pop" })
end

configui.create({
    {
        panelLabel = PANEL_LABEL,
        saveFile = SAVE_FILE,
        layout = layout,
    }
})

print("[hellraiser panel] '" .. PANEL_LABEL .. "' built with " .. #sections .. " sections")
