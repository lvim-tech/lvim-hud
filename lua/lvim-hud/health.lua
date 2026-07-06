-- lvim-hud.health: `:checkhealth lvim-hud` — reports that the periphery modules are loadable, their required
-- deps (lvim-ui toolkit, lvim-utils base) are present, which components are active, and which optional
-- integrations exist (lvim-msgarea for the unified cmdline dock + :Messages zone).
--
---@module "lvim-hud.health"

local M = {}

local health = vim.health
local start = health.start
local ok = health.ok
local err = health.error
local info = health.info

---@param mod string
---@return boolean
local function has(mod)
    return (pcall(require, mod))
end

function M.check()
    start("lvim-hud")

    if vim.fn.has("nvim-0.12") == 1 then
        ok("Neovim >= 0.12")
    else
        err("Neovim >= 0.12 required")
    end

    if has("lvim-utils.utils") then
        ok("lvim-utils (base) is available")
    else
        err("lvim-utils not found — lvim-hud requires it (utils / colors / highlight)")
    end

    if has("lvim-ui.surface") then
        ok("lvim-ui toolkit is available")
    else
        err("lvim-ui not found — lvim-hud's notify toasts / input popup build on it")
    end

    if has("lvim-hud") and has("lvim-hud.chrome") and has("lvim-hud.notify") then
        ok("lvim-hud loaded (chrome + cmdline + notify + input)")
    else
        err("lvim-hud modules failed to load")
    end

    -- Effective component state (reads the live config).
    local cfg = require("lvim-hud.config")
    start("lvim-hud · components")
    for _, comp in ipairs({ "statusline", "winbar", "tabline", "statuscolumn" }) do
        if (cfg.chrome[comp] or {}).enabled then
            ok("chrome." .. comp .. " enabled")
        else
            info("chrome." .. comp .. " disabled")
        end
    end
    if cfg.chrome.overlay.enabled then
        ok("chrome.overlay (finder/echo statusline) enabled")
    else
        info("chrome.overlay disabled")
    end
    if cfg.cmdline.enable then
        ok("cmdline (self-rendered command-line) enabled")
    else
        info("cmdline disabled (opt-in: cmdline.enable = true)")
    end
    if cfg.input.enable then
        ok("input dispatcher enabled (default target: " .. tostring(cfg.input.default) .. ")")
    else
        info("input dispatcher disabled (opt-in: input.enable = true)")
    end
    if cfg.notify.ext_messages then
        ok("notify intercepts Neovim messages (ext_messages)")
    else
        info("notify ext_messages off (vim.notify still routed)")
    end

    -- Optional integrations.
    start("lvim-hud · optional")
    if has("lvim-msgarea") then
        ok("lvim-msgarea present — the unified cmdline dock + the :Messages zone are available")
    else
        info(
            "lvim-msgarea not installed — the cmdline anchors to the editor bottom and :Messages uses the cmdline pager (optional)"
        )
    end
end

return M
