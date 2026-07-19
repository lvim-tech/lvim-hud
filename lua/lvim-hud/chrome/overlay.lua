-- lvim-hud.chrome.overlay: the transient "echo / info" publisher for the chrome statusline. A navigator
-- (a finder) or the command-line sets a title + match counter + free-form action here, and the statusline
-- DISPLAYS it instead of the file segments while it is active — so the bottom line acts as the Emacs
-- echo/info area for whatever is happening.
--
-- Folded out of the old `lvim-utils.status` module: this is now PURE STATE + a `line()` renderer. The chrome
-- statusline owns `vim.o.statusline` and calls `overlay.line()` when `overlay.is_active()` — so the overlay
-- no longer touches `vim.o.statusline`, has no native/component backend, and no save/restore of the option.
--
---@module "lvim-hud.chrome.overlay"

local colors = require("lvim-utils.colors")
local config = require("lvim-hud.config")

local M = {}

-- ─── highlight (tint canon) ────────────────────────────────────────────────────
--- The overlay segment highlights, recomputed from the live palette (bound on first use, re-applied on theme
--- change). Each segment is its accent fg on a light blend of that accent — the cmdline / msgarea tint canon.
---@return table<string, table>
local function build()
    local c = colors
    local b, bg = c.blend, c.bg
    local g = {}
    local function pair(name, col)
        g[name] = { fg = col, bg = b(col, bg, 0.1) }
        g[name .. "Icon"] = { fg = col, bg = b(col, bg, 0.2), bold = true }
    end
    pair("LvimUiStatusTitle", c.blue)
    pair("LvimUiStatusCount", c.green)
    pair("LvimUiStatusAction", c.yellow)
    g.LvimUiStatusSubtitle = { fg = c.cyan, bg = b(c.cyan, bg, 0.1), bold = true }
    return g
end

---@class LvimChromeOverlayState
---@field active boolean
---@field title string?
---@field title_hl string?
---@field icon string?
---@field icon_hl string?
---@field current integer
---@field total integer
---@field action string?
---@field subtitle string?

---@type LvimChromeOverlayState
local state = {
    active = false,
    title = nil,
    title_hl = nil,
    icon = nil,
    icon_hl = nil,
    current = 0,
    total = 0,
    action = nil,
    subtitle = nil,
}

---@type boolean
local hl_bound = false

local function ensure_hl()
    if hl_bound then
        return
    end
    hl_bound = true
    local ok, hl = pcall(require, "lvim-utils.highlight")
    if ok then
        hl.bind(build) -- apply now + re-apply on palette / ColorScheme change
    end
end

local function repaint()
    pcall(vim.cmd, "redrawstatus!")
end

--- Whether a transient action currently owns the line.
---@return boolean
function M.is_active()
    return state.active
end

--- The overlay segment string (no active check — the statusline gates on `is_active()`). Built from
--- `%#Group#<lpad>text<rpad>%*` segments in the tint canon: a title badge (icon stronger), the right-aligned
--- counter, then the action / query. All padding is read from `config.chrome.overlay`.
---@return string
function M.line()
    local cfg = config.chrome.overlay or {}
    local function seg(group, text, l, r)
        -- `text` is RUNTIME display text (a publisher's title, the live typed cmdline/search string, a
        -- subtitle, the counter) — escape every `%` to `%%` so it is drawn LITERALLY. Without this a typed
        -- `%{expr}` / `%=` / `%%` would be parsed as a statusline item (the line is `%!`-evaluated), so a
        -- `%{…}` in the query would EVALUATE a VimL expression. The surrounding `%#…#`/`%*` are ours.
        text = tostring(text or ""):gsub("%%", "%%%%")
        return ("%%#%s#%s%s%s%%*"):format(group, string.rep(" ", l or 0), text, string.rep(" ", r or 0))
    end
    local parts = {}
    if state.icon and state.icon ~= "" then
        parts[#parts + 1] =
            seg(state.icon_hl or "LvimUiStatusTitleIcon", state.icon, cfg.icon_pad_left or 0, cfg.icon_pad_right or 1)
    end
    if state.title and state.title ~= "" then
        parts[#parts + 1] =
            seg(state.title_hl or "LvimUiStatusTitle", state.title, cfg.title_pad_left or 1, cfg.title_pad_right or 1)
    end
    local gp = cfg.segment_pad or 1
    if state.subtitle and state.subtitle ~= "" then
        parts[#parts + 1] = seg("LvimUiStatusSubtitle", state.subtitle, gp, gp)
    end
    if cfg.show_action and state.action and state.action ~= "" then
        parts[#parts + 1] = seg("LvimUiStatusAction", state.action, gp, gp)
    end
    if cfg.show_counter ~= false and state.total > 0 then
        local txt = state.current > 0 and ("%d/%d"):format(state.current, state.total) or tostring(state.total)
        parts[#parts + 1] = "%=" .. seg("LvimUiStatusCount", txt, gp, gp)
    end
    return table.concat(parts)
end

--- Publish (merge) the current action's status; mark the line active and repaint.
---@param s { title?: string, title_hl?: string, icon?: string, icon_hl?: string, current?: integer, total?: integer, action?: string, subtitle?: string }
function M.set(s)
    s = s or {}
    ensure_hl()
    state.active = true
    -- Copy the present fields by key. `s` and `state` share the same field shape, but a DYNAMIC key defeats the
    -- per-field type check, so read through an `any`-typed view (the access is genuinely dynamic, not a suppress).
    local src = s --[[@as table<string, any>]]
    for _, k in ipairs({ "title", "title_hl", "icon", "icon_hl", "current", "total", "action", "subtitle" }) do
        if src[k] ~= nil then
            state[k] = src[k]
        end
    end
    repaint()
end

--- Clear the status and repaint (the statusline falls back to its file segments).
function M.clear()
    state.active = false
    state.title, state.title_hl, state.icon, state.icon_hl, state.action = nil, nil, nil, nil, nil
    state.subtitle = nil
    state.current, state.total = 0, 0
    repaint()
end

--- The live state.
---@return LvimChromeOverlayState
function M.get()
    return state
end

--- Snapshot the current status (nil when inactive) so a transient owner (the command-line over a finder) can
--- overlay its own and put the previous one back on close. Pair with `M.restore`.
---@return LvimChromeOverlayState?
function M.save()
    return state.active and vim.deepcopy(state) or nil
end

--- Re-apply a snapshot from `M.save` (or clear when nil). Assigns every field explicitly so a field the
--- snapshot left nil is CLEARED, not kept from the transient owner that just released the line.
---@param snap LvimChromeOverlayState?
function M.restore(snap)
    if not (snap and snap.active) then
        M.clear()
        return
    end
    state.active = true
    state.title, state.title_hl = snap.title, snap.title_hl
    state.icon, state.icon_hl = snap.icon, snap.icon_hl
    state.current, state.total = snap.current or 0, snap.total or 0
    state.action, state.subtitle = snap.action, snap.subtitle
    repaint()
end

--- The master switch — true when the echo/info overlay model is enabled (`config.chrome.overlay.enabled`).
---@return boolean
function M.is_enabled()
    local cfg = config.chrome.overlay or {}
    return cfg.enabled ~= false
end

return M
