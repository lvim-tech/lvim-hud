-- lvim-hud.chrome.tabline: the top tabline GLUE — it ships NO predefined sections (like the statusline).
-- All sections live in the user's config; this module only resolves that segment list and runs it through the
-- shared engine (a `%!`-evaluated, GLOBAL `tabline`). The instance is `volatile` (the tabline is redrawn on
-- window / tab / buffer changes by the chrome autocmds via `redrawtabline`, and each redraw recomputes). The
-- sections compose from the helpers — chrome.parts (seg / icons / excluded / unique_name) — never reimplemented
-- here.
--
-- The segment list is `config.chrome.tabline.segments`: a LIST of segment specs, OR a FUNCTION returning one.
--
---@module "lvim-hud.chrome.tabline"

local api = vim.api
local engine = require("lvim-hud.chrome.engine")
local config = require("lvim-hud.config")

local M = {}

--- This component's engine instance — `volatile` (recomputed each redraw, since the tabline is per-tab state);
--- the gap wears the bar fill (LvimUiChromeFill), like the statusline.
---@type LvimChromeEngine
local inst = engine.new({ volatile = true, fill = "LvimUiChromeFill" })

--- The configured tabline section list — a LIST of specs, or a FUNCTION returning one (resolved here). No
--- predefined sections: unset / empty / failing config yields a blank tabline.
---@return LvimChromeSegment[]
local function active_segments()
    local segs = (config.chrome.tabline or {}).segments
    if type(segs) == "function" then
        local ok, res = pcall(segs)
        segs = ok and res or nil
    end
    return type(segs) == "table" and segs or {}
end

-- The last bar STRING we actually showed, and a candidate awaiting confirmation. The tabline is a global
-- `%!`-expression nvim re-evaluates synchronously on every redraw, so we cannot defer the call itself — but
-- we can WAIT to SHOW a change: a new value is only committed once it survives TWO consecutive evaluations.
-- A one-frame transient (e.g. the editor/file focused for a single frame while a picker closes and the panel
-- re-opens) never survives twice, so it is never painted; we keep showing the last committed bar and force a
-- re-evaluation next tick via `redrawtabline`.
---@type string?
local _shown = nil
---@type string?
local _cand = nil

--- The `%!`-evaluated tabline string. The engine renders the config's sections.
---@return string
function M.render()
    local win = api.nvim_get_current_win()
    ---@type LvimChromeCtx
    local ctx = { buf = api.nvim_win_get_buf(win), win = win }
    local fresh = inst.render(active_segments(), ctx)
    if _shown == nil or fresh == _shown then
        _shown, _cand = fresh, nil
        return fresh
    end
    if fresh == _cand then
        _shown, _cand = fresh, nil -- stable across two evals → commit the change
        return fresh
    end
    -- changed, possibly a transient: keep the last committed bar, re-check next tick.
    _cand = fresh
    vim.schedule(function()
        pcall(vim.cmd, "redrawtabline")
    end)
    return _shown
end

return M
