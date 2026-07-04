-- lvim-hud.chrome.statusline: the statusline GLUE — it ships NO predefined segments (exactly like heirline).
-- All segments live in the user's config; this module only: resolves that segment list, runs it through the
-- shared engine (lvim-hud.chrome.engine), and handles the two non-segment render modes — the transient
-- OVERLAY (a finder / cmdline title+counter) and the float GUARD (keep showing the last real file while a UI
-- float is focused). The building blocks the config composes from are the helpers (chrome.parts / chrome.utils
-- / chrome.git) — never reimplemented here.
--
-- The segment list is `config.chrome.statusline.segments`: a LIST of segment specs, OR a FUNCTION returning
-- one (resolved lazily at render time, so the config needs no eager require). Empty / unset ⇒ a blank line.
--
---@module "lvim-hud.chrome.statusline"

local api = vim.api
local utils = require("lvim-hud.chrome.utils")
local engine = require("lvim-hud.chrome.engine")
local git_poller = require("lvim-hud.chrome.git")
local parts = require("lvim-hud.chrome.parts")
local config = require("lvim-hud.config")

local is_ui_float = utils.is_ui_float

local M = {}

--- This component's engine instance — its own per-segment cache (invalidate-only; the native redraw repaints).
---@type LvimChromeEngine
local inst = engine.new({ fill = "LvimUiChromeFill" })

-- ── float guard ───────────────────────────────────────────────────────────────
---@type integer?  the last REAL file window (not a float / scratch)
local last_regular = nil

--- Track the last REAL file window (not a float, not a scratch / special buffer). Called from the chrome
--- autocmds. The float guard renders for this window, so it must never be a "[No Name]" scratch.
function M.track_window()
    local w = api.nvim_get_current_win()
    if api.nvim_win_get_config(w).relative == "" and vim.bo[api.nvim_win_get_buf(w)].buftype == "" then
        last_regular = w
    end
end

--- The configured segment list — a LIST of specs, or a FUNCTION returning one (resolved here). No predefined
--- segments: an unset / empty / failing config yields a blank line.
---@return LvimChromeSegment[]
local function active_segments()
    local segs = (config.chrome.statusline or {}).segments
    if type(segs) == "function" then
        local ok, res = pcall(segs)
        segs = ok and res or nil
    end
    return type(segs) == "table" and segs or {}
end

-- ── render ───────────────────────────────────────────────────────────────────────────────────────────────
--- The `%!`-evaluated statusline string: the OVERLAY, then the float GUARD, else the engine renders the
--- configured segment list for the current buffer.
---@return string
function M.render()
    local overlay = require("lvim-hud.chrome.overlay")
    if overlay.is_enabled() and overlay.is_active() then
        return overlay.line()
    end
    -- While a UI float (picker / area / popup) is focused, render for the LAST REAL file window instead of the
    -- float's scratch buffer — so the styled line stays put (no bare "[No Name]" / native-looking fallback).
    local cur = api.nvim_get_current_win()
    local win = cur
    if is_ui_float(cur) and last_regular and api.nvim_win_is_valid(last_regular) then
        win = last_regular
    end
    ---@type LvimChromeCtx
    local ctx = {
        buf = api.nvim_win_get_buf(win),
        win = win,
        mode = vim.fn.mode(1):sub(1, 1),
        active = win == cur,
    }
    -- the statusline's OWN blacklist (e.g. the start dashboard): render NOTHING for an excluded buffer.
    if parts.excluded(ctx.buf, "statusline") then
        return ""
    end
    return inst.render(active_segments(), ctx)
end

-- ── invalidation + autocmds (delegated to the shared engine) ─────────────────────────────────────────────

--- Mark statusline segments for rebuild (`nil` = all). Delegates to this component's engine instance.
M.invalidate = inst.invalidate

--- Install the statusline's autocmds. The engine derives the per-segment invalidation (+ forced redraw) from
--- each segment's `events`; here we add the side effects the segments rely on: restart the git poller on a cwd
--- change (it fires `User LvimUiChromeGit` → the git/hunks segments invalidate) and reset the engine's
--- dynamic-hl cache on a theme change.
---@param grp integer  the chrome augroup id
function M.install_autocmds(grp)
    inst.install_autocmds(grp, active_segments())
    api.nvim_create_autocmd("DirChanged", {
        group = grp,
        callback = function()
            git_poller.start((config.chrome.git or {}).poll_ms or 1000)
            pcall(vim.cmd, "redrawstatus")
        end,
    })
    api.nvim_create_autocmd("ColorScheme", { group = grp, callback = engine.clear_hl_cache })
end

return M
