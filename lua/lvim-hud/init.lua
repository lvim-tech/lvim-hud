-- lvim-hud: the editor-periphery plugin — everything on screen that is NOT the text buffer:
--   chrome  – the statusline, winbar, tabline and statuscolumn components (+ the transient finder/echo overlay)
--   cmdline – a self-rendered command-line (own float + buffer, driven by ext_cmdline)
--   notify  – the notification hub (per-level toast panels + the :Messages history)
--   input   – a vim.ui.input dispatcher (routes each prompt to the cmdline or a popup)
--
-- setup() merges the user's `{ chrome, cmdline, notify, input }` opts into the live lvim-hud.config IN PLACE
-- (via lvim-utils.utils.merge) and activates each component. notify + chrome are ON by default (pass
-- `notify = false` / `chrome = false` to opt out); cmdline + input are opt-in via their own `enable` flag.
--
-- The submodules are also re-exported (`require("lvim-hud").notify`, `.chrome`, …) so callers reach them
-- through the aggregate. The message-zone integrations (unified cmdline dock, :Messages in the zone) are
-- provided by lvim-msgarea, which registers itself with cmdline/notify — lvim-hud never depends on it.
--
---@module "lvim-hud"

local config = require("lvim-hud.config")
local merge = require("lvim-utils.utils").merge

local chrome = require("lvim-hud.chrome")
local cmdline = require("lvim-hud.cmdline")
local notify = require("lvim-hud.notify")
local input = require("lvim-hud.input")

local M = {}

-- Re-export the submodules + live config so `require("lvim-hud").notify` / `.config.notify` etc. resolve
-- through the aggregate (parity with how lvim-utils exposed them before the split).
M.config = config
M.chrome = chrome
M.cmdline = cmdline
M.notify = notify
M.input = input

---@class LvimHudOpts
---@field chrome?  LvimHudChromeConfig|false  editor chrome (default on; false = off)
---@field cmdline? LvimHudCmdlineConfig|false  self-rendered command-line (opt-in via cmdline.enable; false = off)
---@field notify?  LvimHudNotifyConfig|false   notification hub (default on; false = off)
---@field input?   LvimHudInputConfig|false    vim.ui.input dispatcher (opt-in via input.enable; false = off)

--- Merge opts into the live lvim-hud.config and activate the periphery. A component set to `false` opts out
--- entirely; a table merges into that component's config; nil activates it with defaults (subject to the
--- component's own `enable` flag for cmdline/input).
---@param opts? LvimHudOpts
function M.setup(opts)
    opts = opts or {}

    -- Merge each component's opts into its live config table IN PLACE, so every reader
    -- `require("lvim-hud.config").<mod>` sees the effective values (a shorter override list REPLACES the
    -- default wholesale, per lvim-utils.utils.merge).
    if type(opts.chrome) == "table" then
        merge(config.chrome, opts.chrome)
    end
    if type(opts.cmdline) == "table" then
        merge(config.cmdline, opts.cmdline)
    end
    if type(opts.notify) == "table" then
        merge(config.notify, opts.notify)
    end
    if type(opts.input) == "table" then
        merge(config.input, opts.input)
    end

    -- notify = false opts out entirely; any other value (including nil) activates with defaults. setup() also
    -- merges opts.notify into its live config internally (idempotent with the merge above).
    if opts.notify ~= false then
        notify.setup(opts.notify or {})
    end

    -- cmdline is opt-in (config default enable = false); setup() no-ops unless enabled. It CONSUMES the live
    -- config table (already merged above), so pass config.cmdline.
    if opts.cmdline ~= false then
        cmdline.setup(config.cmdline)
    end

    -- input dispatcher (vim.ui.input → cmdline/popup); opt-in, no-ops unless enabled.
    if opts.input ~= false then
        input.setup(config.input)
    end

    -- editor chrome: statusline / winbar / tabline / statuscolumn + the folded transient finder/echo overlay.
    -- chrome.setup() reads its live config internally and self-themes its groups.
    if opts.chrome ~= false then
        chrome.setup()
    end
end

return M
