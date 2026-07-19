-- lvim-hud.chrome.winbar: the per-window top line GLUE — it ships NO predefined sections (like the
-- statusline). All sections live in the user's config; this module only resolves that segment list and runs it
-- through the shared engine PER WINDOW (a `%!`-evaluated `winbar`, drawn for the window in
-- `vim.g.statusline_winid`). The instance is `volatile` (per-window, each window differs — no caching). The
-- sections gate themselves with `when` (terminal vs file, active vs inactive); they compose from the helpers
-- (chrome.parts) — never reimplemented here.
--
-- The segment list is `config.chrome.winbar.segments`: a LIST of segment specs, OR a FUNCTION returning one.
-- Each section's `content = fn(ctx)` gets ctx = { buf, win, active }.
--
---@module "lvim-hud.chrome.winbar"

local api = vim.api
local engine = require("lvim-hud.chrome.engine")
local config = require("lvim-hud.config")

local M = {}

--- This component's engine instance — per-window, so never cache (`volatile`); no align gap (`fill = false`).
---@type LvimChromeEngine
local inst = engine.new({ volatile = true, fill = false })

--- While a surface TRANSITION is in progress (a picker→panel swap etc.) the winbar renders NO window as active.
--- Tearing a finder down makes focus fall to the editor for a beat mid-swap (synchronously, while the swap's
--- backdrop hold is still on) — reading the live current window there rendered the EDITOR active for one frame,
--- so the breadcrumb flashed the file. Gating `active` off `lvim-utils.dim.transition_active` suppresses that:
--- the breadcrumb hides for the (brief) duration of the swap, then normal focus-driven active resumes.
---@type fun(): boolean
local transition_active
do
    local ok_dim, dim = pcall(require, "lvim-utils.dim")
    transition_active = (ok_dim and type(dim.transition_active) == "function") and dim.transition_active
        or function()
            return false
        end
end

--- The configured winbar section list — a LIST of specs, or a FUNCTION returning one (resolved here). No
--- predefined sections: unset / empty / failing config yields a blank winbar.
---@return LvimChromeSegment[]
local function active_segments()
    local segs = (config.chrome.winbar or {}).segments
    if type(segs) == "function" then
        local ok, res = pcall(segs)
        segs = ok and res or nil
    end
    return type(segs) == "table" and segs or {}
end

--- The `%!`-evaluated winbar string for the window being drawn. The engine renders the config's sections.
---@return string
function M.render()
    local win = vim.g.statusline_winid
    if win == nil or win == 0 or not api.nvim_win_is_valid(win) then
        win = api.nvim_get_current_win()
    end
    -- `active` is the live current window — EXCEPT during a surface transition, when it is forced false so a
    -- window momentarily focused mid-swap (the editor while a finder tears down) never renders active and the
    -- breadcrumb never flashes. Normal focus is unaffected (transition_active is only true across a swap).
    ---@type LvimChromeCtx
    local ctx = {
        buf = api.nvim_win_get_buf(win),
        win = win,
        active = (win == api.nvim_get_current_win()) and not transition_active(),
    }
    return inst.render(active_segments(), ctx)
end

return M
