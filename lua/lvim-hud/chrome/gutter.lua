-- lvim-hud.chrome.gutter: helpers for composing a STATUSCOLUMN (the per-line gutter) from config — the
-- extmark reader, the sign-kind filters, the diagnostic icon, the mark lookup, and mouse-click resolution.
-- Ships NO predefined sections (like the statusline); the config builds the segments from these (see
-- chrome.engine + chrome.statuscolumn). All gutter cells use NATIVE (no-bg) groups so the gutter stays one
-- uniform dimmed background.
--
---@module "lvim-hud.chrome.gutter"

local api = vim.api
local parts = require("lvim-hud.chrome.parts")

local M = {}

-- ── sign-kind filters (pass a sign's highlight group) ────────────────────────────────────────────────────
---@param hl string
---@return boolean
function M.is_diag(hl)
    return hl:match("^DiagnosticSign") ~= nil
end
---@param hl string
---@return boolean
function M.is_git(hl)
    return hl:match("^MiniDiffSign") ~= nil
end
---@param hl string
---@return boolean
function M.is_other(hl)
    return not (hl:match("^DiagnosticSign") or hl:match("^MiniDiffSign") or hl:match("^[Gg]it[Ss]ign"))
end

-- ── extmark reader ───────────────────────────────────────────────────────────────────────────────────────
--- Sign extmarks on `buf` line `lnum` (1-based) whose group passes `filter`, sorted by priority (highest 1st).
---@param buf integer
---@param lnum integer
---@param filter fun(hl: string): boolean
---@return { name: string, text: string, sign_hl_group: string, priority: integer }[]
function M.signs(buf, lnum, filter)
    if not api.nvim_buf_is_valid(buf) then
        return {}
    end
    -- `type = "sign"` filters to sign/number/line-highlight extmarks in C, so this per-line hot path no longer
    -- iterates (and rejects) every hl / virt_text extmark on the line (semantic tokens, rainbow). Number-only
    -- signs still pass — they carry the sign decoration flags (`number_hl_group`) the "sign" class covers.
    local ok, marks = pcall(
        api.nvim_buf_get_extmarks,
        buf,
        -1,
        { lnum - 1, 0 },
        { lnum - 1, -1 },
        { details = true, type = "sign" }
    )
    if not ok or not marks then
        return {}
    end
    local res = {}
    for _, m in ipairs(marks) do
        local d = m[4] or {}
        local hl = d.sign_hl_group or d.number_hl_group or ""
        if hl ~= "" and filter(hl) then
            res[#res + 1] =
                { name = d.sign_name or hl, text = d.sign_text or "", sign_hl_group = hl, priority = d.priority or 0 }
        end
    end
    table.sort(res, function(a, b)
        return (a.priority or 0) > (b.priority or 0)
    end)
    return res
end

-- ── presentation helpers ─────────────────────────────────────────────────────────────────────────────────
--- The diagnostic icon for a `DiagnosticSign*` highlight group.
---@param hl string
---@return string
function M.diag_icon(hl)
    local di = parts.icons().diagnostics
    return (hl == "DiagnosticSignError" and di.error)
        or (hl == "DiagnosticSignWarn" and di.warn)
        or (hl == "DiagnosticSignInfo" and di.info)
        or (hl == "DiagnosticSignHint" and di.hint)
        or di.global
end

-- One-frame memo for the merged (global + buffer) mark list: the statuscolumn evaluates mark_letter once PER
-- SCREEN LINE per redraw, and each call otherwise forks TWO getmarklist() VimL lookups. Cache them for the
-- buffer and clear on the next event-loop tick (vim.schedule), so every line of one synchronous redraw shares
-- a single pair of lookups; a later redraw (after any mark change) rebuilds them.
---@type { buf: integer, list: table[] }?
local _mark_memo = nil
local _mark_memo_clear = false

--- The merged global + buffer mark list for `buf`, memoized for the current redraw frame.
---@param buf integer
---@return table[]
local function mark_list(buf)
    if _mark_memo and _mark_memo.buf == buf then
        return _mark_memo.list
    end
    local list = vim.list_extend(vim.fn.getmarklist(), vim.fn.getmarklist(buf))
    _mark_memo = { buf = buf, list = list }
    if not _mark_memo_clear then
        _mark_memo_clear = true
        vim.schedule(function()
            _mark_memo = nil
            _mark_memo_clear = false
        end)
    end
    return list
end

--- The mark letter sitting on `buf` line `lnum`, or "". A line can hold several marks; when this is the
--- CURSOR line of `win`, the one reported is column-aware — the first mark AT or AFTER the cursor column
--- (so a mark directly UNDER the cursor is the one shown, and stepping right along the line advances to the
--- next mark ahead), falling back to the nearest mark to the LEFT once the cursor is past them all. On any
--- other line (or with no window) the first mark in list order is used, exactly as before.
---@param buf integer
---@param lnum integer
---@param win integer?  the window being drawn — enables the cursor-column pick on its cursor line
---@return string
function M.mark_letter(buf, lnum, win)
    -- Only the cursor line needs the column-aware pick; compute its 1-based cursor column (getmarklist cols
    -- are 1-based, the window cursor col is 0-based) once, and leave it nil for every other line.
    local ccol
    if win and win ~= 0 and api.nvim_win_is_valid(win) then
        local cur = api.nvim_win_get_cursor(win)
        if cur[1] == lnum then
            ccol = cur[2] + 1
        end
    end
    local here = {}
    for _, m in ipairs(mark_list(buf)) do
        local letter = m.mark:match("^[`']?([a-zA-Z])$")
        if letter and m.pos[1] == buf and m.pos[2] == lnum then
            if not ccol then
                return letter -- not the cursor line: keep the first-in-list mark (zero extra work)
            end
            here[#here + 1] = { letter = letter, col = m.pos[3] or 1 }
        end
    end
    if #here == 0 then
        return ""
    end
    table.sort(here, function(a, b)
        return a.col < b.col
    end)
    for _, e in ipairs(here) do
        if e.col >= ccol then
            return e.letter
        end
    end
    return here[#here].letter
end

-- ── click resolution (for a segment's `click.run`) ───────────────────────────────────────────────────────
--- Move the cursor to the clicked gutter line; return its window, buffer and 1-based line.
---@return integer? win, integer? buf, integer? lnum
function M.at_mouse()
    local mp = vim.fn.getmousepos() or {}
    local win = mp.winid
    if not win or not api.nvim_win_is_valid(win) then
        return
    end
    local buf = api.nvim_win_get_buf(win)
    local lnum = mp.line or vim.v.lnum
    pcall(api.nvim_set_current_win, win)
    pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
    return win, buf, lnum
end

--- The top sign of kind `filter` at the CLICKED line (after moving the cursor there) — for a `click.run`
--- handler, e.g. `click = { run = function() local s = gutter.sign_at_mouse(gutter.is_diag); … end }`.
---@param filter fun(hl: string): boolean
---@return table? sign
function M.sign_at_mouse(filter)
    local _, buf, lnum = M.at_mouse()
    if buf and lnum then
        return M.signs(buf, lnum, filter)[1]
    end
end

return M
