-- lvim-hud.chrome.statuscolumn: the statuscolumn GLUE — it ships NO predefined sections (like the
-- statusline). All gutter sections live in the user's config; this module only resolves that segment list and
-- runs it through the shared engine PER LINE (a `%!`-evaluated `statuscolumn`, drawn for every screen line with
-- `v:lnum` / `v:relnum` / `v:virtnum`). The instance is `volatile` (no caching — each line differs) and uses a
-- bare `%=` gap (`fill = false`) so the native gutter background shows through. Clicks go through the engine's
-- `click` model (the config's `click.run` resolves the clicked line via chrome.gutter). Building blocks: the
-- helpers in chrome.gutter + chrome.parts — never reimplemented here.
--
-- The segment list is `config.chrome.statuscolumn.segments`: a LIST of segment specs, OR a FUNCTION returning
-- one. Each section's `content = fn(ctx)` gets ctx = { buf, win, lnum, relnum, virtnum }.
--
---@module "lvim-hud.chrome.statuscolumn"

local api = vim.api
local engine = require("lvim-hud.chrome.engine")
local config = require("lvim-hud.config")

local M = {}

--- This component's engine instance — per-line, so never cache (`volatile`); bare `%=` gap (native gutter bg).
---@type LvimChromeEngine
local inst = engine.new({ volatile = true, fill = false })

--- The configured gutter section list — a LIST of specs, or a FUNCTION returning one (resolved here). No
--- predefined sections: unset / empty / failing config yields a blank gutter.
---@return LvimChromeSegment[]
local function active_segments()
    local segs = (config.chrome.statuscolumn or {}).segments
    if type(segs) == "function" then
        local ok, res = pcall(segs)
        segs = ok and res or nil
    end
    return type(segs) == "table" and segs or {}
end

--- The `%!`-evaluated statuscolumn string for the line being drawn. The engine renders the config's sections
--- with a per-line context.
---@return string
function M.render()
    local win = vim.g.statusline_winid
    if not win or win == 0 or not api.nvim_win_is_valid(win) then
        win = api.nvim_get_current_win()
    end
    ---@type LvimChromeCtx
    local ctx = {
        buf = api.nvim_win_get_buf(win),
        win = win,
        lnum = vim.v.lnum,
        relnum = vim.v.relnum,
        virtnum = vim.v.virtnum,
    }
    return inst.render(active_segments(), ctx)
end

return M
