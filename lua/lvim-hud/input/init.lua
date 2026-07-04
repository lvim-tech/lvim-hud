-- lvim-hud.input: input dispatcher — installs a vim.ui.input that routes each prompt to either the
-- self-rendered command-line (lvim-hud.cmdline) or a popup (lvim-ui), so every
-- input can be steered individually. Resolution order: route_next() one-shot →
-- opts.ui ("cmdline"|"popup") → config default.
--
---@module "lvim-hud.input"

local ui_mod = require("lvim-ui")
local cmdline = require("lvim-hud.cmdline")
local M = {}

local _cfg ---@type table
local _route ---@type string?

--- Force the target of the *next* vim.ui.input call only (for built-ins like LSP
--- rename that do not pass an `ui` option). Cleared once consumed.
---@param ui "cmdline"|"popup"
---@return nil
function M.route_next(ui)
    _route = ui
end

--- Popup prompt via lvim-ui (the styled floating input).
---@param opts table
---@param on_confirm fun(input: string?)
local function popup(opts, on_confirm)
    local ui = ui_mod
    local prompt = (opts.prompt and opts.prompt:gsub("\n", "")) or "Input"
    if prompt:sub(-1) == ":" then
        prompt = " " .. prompt:sub(1, -2) .. " "
    end
    local default = opts.default and tostring(opts.default):gsub("\n", "") or ""
    ui.input({
        title = prompt,
        placeholder = default,
        position = "cursor",
        width = math.max(40, #prompt + 40, #default + 40),
        callback = function(confirmed, value)
            on_confirm(confirmed and value or nil)
        end,
    })
end

--- Install the dispatcher as vim.ui.input.
---@param cfg table  the merged lvim-hud.config.input
---@return nil
function M.setup(cfg)
    cfg = cfg or {}
    _cfg = cfg
    if not cfg.enable then
        return
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(opts, on_confirm)
        assert(type(on_confirm) == "function", "vim.ui.input: missing on_confirm")
        opts = opts or {}
        local target = _route or opts.ui or _cfg.default or "popup"
        _route = nil
        if target == "cmdline" then
            cmdline.input(opts, on_confirm)
        else
            popup(opts, on_confirm)
        end
    end
end

return M
