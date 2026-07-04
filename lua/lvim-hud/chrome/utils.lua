-- lvim-hud.chrome.utils: small helpers reused across the chrome components (statusline, winbar, tabline,
-- statuscolumn) — kept here so no component re-implements them. Pure functions; no state.
--
---@module "lvim-hud.chrome.utils"

local api = vim.api

local M = {}

--- The bar background hex (bar-bg dark), for inline devicon / dynamic groups that must sit on the bar.
---@return string
function M.bar_bg()
    return require("lvim-utils.colors").bg_dark
end

--- Human-readable byte size, e.g. "12.3 KB".
---@param bytes integer
---@return string
function M.size_str(bytes)
    local units = { "B", "KB", "MB", "GB" }
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return (i == 1 and "%d %s" or "%.1f %s"):format(bytes, units[i])
end

--- True when `win` is a UI float — a floating window over a special (non-file) buffer (a picker / the msgarea
--- zone / a popup). Used to keep the chrome showing the last real buffer instead of the float's scratch state.
---@param win integer
---@return boolean
function M.is_ui_float(win)
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative == "" then
        return false
    end
    return vim.bo[api.nvim_win_get_buf(win)].buftype ~= ""
end

return M
