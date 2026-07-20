-- lvim-hud.chrome.parts: the building blocks shared across the chrome components (statusline / winbar /
-- tabline / statuscolumn).
--
-- Holds the vi-mode tables, the highlight-group `seg` wrapper, the devicon resolver (per-extension group),
-- a self-contained filename uniquifier (replacing the tabby.filename dependency), the buffer/filetype
-- exclusion check, and small helpers. All highlight groups are `LvimUiChrome<suffix>`, defined by the
-- factory in `chrome/init.lua` and recomputed on theme change.
--
---@module "lvim-hud.chrome.parts"

local api = vim.api
local config = require("lvim-hud.config")
local iconlib = require("lvim-utils.icons")

local M = {}

--- the current vi-mode's first character — set by the statusline's mode segment, read by file_name so its
--- colour tracks the mode (as the heirline statusline did).
---@type string
M.mode = "n"

-- ── vi-mode tables (ported 1:1) ──────────────────────────────────────────────
--- full mode string → short label
---@type table<string, string>
M.MODE_LABEL = {
    n = "N",
    no = "N?",
    nov = "N?",
    noV = "N?",
    ["no\22"] = "N?",
    niI = "Ni",
    niR = "Nr",
    niV = "Nv",
    nt = "Nt",
    v = "V",
    vs = "Vs",
    V = "V_",
    Vs = "Vs",
    ["\22"] = "^V",
    ["\22s"] = "^V",
    s = "S",
    S = "S_",
    ["\19"] = "^S",
    i = "I",
    ic = "Ic",
    ix = "Ix",
    R = "R",
    Rc = "Rc",
    Rx = "Rx",
    Rv = "Rv",
    Rvc = "Rv",
    Rvx = "Rv",
    c = "C",
    cv = "Ex",
    r = "...",
    rm = "M",
    ["r?"] = "?",
    ["!"] = "!",
    t = "T",
}

--- mode first-char → the mode-pill highlight-group suffix (bg-coloured pill)
---@type table<string, string>
M.MODE_GROUP = {
    n = "ModeN",
    i = "ModeI",
    v = "ModeV",
    V = "ModeV",
    ["\22"] = "ModeV",
    c = "ModeC",
    s = "ModeC",
    S = "ModeC",
    ["\19"] = "ModeC",
    R = "ModeR",
    r = "ModeR",
    ["!"] = "ModeR",
    t = "ModeT",
}

--- mode first-char → an accent fg-group suffix (so file_name's fg follows the mode)
---@type table<string, string>
M.MODE_ACCENT = {
    n = "Green",
    i = "Red",
    v = "Orange",
    V = "Orange",
    ["\22"] = "Orange",
    c = "Purple",
    s = "Purple",
    S = "Purple",
    ["\19"] = "Purple",
    R = "Cyan",
    r = "Cyan",
    ["!"] = "Cyan",
    t = "Blue",
}

--- Wrap `text` in a `LvimUiChrome<suffix>` highlight, terminated with `%*` (reset to the line's own group).
---@param suffix string  e.g. "Blue", "ModeN", "GitAdd"
---@param text string
---@return string
function M.seg(suffix, text)
    return "%#LvimUiChrome" .. suffix .. "#" .. text .. "%*"
end

--- The live chrome config.
---@return table
function M.cfg()
    return config.chrome
end

--- The live chrome icon set.
---@return table
function M.icons()
    return M.cfg().icons
end

--- True when `buf`'s buftype or filetype is in the given COMPONENT's chrome exclusion list (no chrome there).
---@param buf? integer
---@param kind? "statusline"|"winbar"|"tabline"|"statuscolumn"  which component's blacklist to check
---@return boolean
function M.excluded(buf, kind)
    buf = buf or 0
    local cfg = M.cfg()
    -- each component owns its OWN `exclude = { buftype, filetype }` blacklist; pass `kind` to check that one.
    local ex = (kind and cfg[kind] and cfg[kind].exclude) or {}
    return vim.tbl_contains(ex.buftype or {}, vim.bo[buf].buftype)
        or vim.tbl_contains(ex.filetype or {}, vim.bo[buf].filetype)
end

--- True when `buf` deserves a CELL in a window/buffer bar (the tabline's window list).
---
--- A NAMED buffer always does — it is a file, and the component's own `exclude` blacklist decides the rest.
--- An UNNAMED one only does when it is a genuine unsaved DRAFT: a normal buffer (`buftype == ""`, so never a
--- panel / terminal / help / quickfix scratch) that already holds content not yet written to a file. That is
--- the whole rule — without it every panel with an unnamed scratch buffer, and the empty startup buffer,
--- claimed an indistinguishable "[No Name]" cell, and the bar filled up with them.
---@param buf? integer
---@return boolean
function M.listable(buf)
    buf = buf or 0
    if api.nvim_buf_get_name(buf) ~= "" then
        return true
    end
    return vim.bo[buf].buftype == "" and vim.bo[buf].modified
end

--- The file icon for `buf` + a per-extension highlight group carrying its colour on the bar bg. Returns nil
--- when the buffer is unnamed or the resolved glyph is empty. The icon comes from the configured
--- `icon_provider` (lvim-icons / nvim-web-devicons / mini.icons, resolved via lvim-utils.icons); the colour
--- is that provider's resolved hex.
---@param buf? integer
---@param bar_bg? string  the bar background hex (so the icon sits on the bar, not its own bg)
---@return string? icon, string? group
function M.devicon(buf, bar_bg)
    buf = buf or 0
    local name = api.nvim_buf_get_name(buf)
    if name == "" then
        return nil
    end
    local ext = vim.fn.fnamemodify(name, ":e")
    local r = iconlib.get(name, { provider = M.cfg().icon_provider, color_mode = M.cfg().icon_color_mode })
    local icon, color = r.glyph, r.color
    if not icon or icon == "" then
        return nil
    end
    -- Sanitise the extension into a valid highlight-group suffix: a non-word char (`c++`, `d-`) is illegal in
    -- a group name, so nvim_set_hl fails SILENTLY and the invalid chars leak into the `%#…#` statusline token.
    local suffix = (ext ~= "" and ext:gsub("%W", "_")) or "none"
    local group = "LvimUiChromeDevicon_" .. suffix
    pcall(api.nvim_set_hl, 0, group, { fg = color, bg = bar_bg })
    return icon, group
end

--- A short UNIQUE name for `win`'s buffer: the basename, disambiguated with its parent dir only when another
--- loaded buffer shares the same basename. Self-contained replacement for `tabby.filename.unique`.
---@param win? integer
---@return string
function M.unique_name(win)
    win = win or 0
    local buf = api.nvim_win_get_buf(win)
    local name = api.nvim_buf_get_name(buf)
    if name == "" then
        return "[No Name]"
    end
    local tail = vim.fn.fnamemodify(name, ":t")
    for _, b in ipairs(api.nvim_list_bufs()) do
        if b ~= buf and api.nvim_buf_is_loaded(b) then
            local n = api.nvim_buf_get_name(b)
            if n ~= "" and vim.fn.fnamemodify(n, ":t") == tail then
                -- a clash → include the immediate parent dir for disambiguation
                return vim.fn.fnamemodify(name, ":h:t") .. "/" .. tail
            end
        end
    end
    return tail
end

--- Return a copy of `list` with duplicates removed (order preserved).
---@param list any[]
---@return any[]
function M.remove_duplicate(list)
    local seen, out = {}, {}
    for _, v in ipairs(list or {}) do
        if not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    return out
end

return M
