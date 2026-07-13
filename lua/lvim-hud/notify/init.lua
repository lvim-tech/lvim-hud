-- lvim-hud.notify: the notification hub — intercepts vim.notify (and optionally print), routes
-- every message through a list of pluggable printers, and ships two built-in printers:
--   "toast"   – one floating panel per severity level, stacked vertically
--   "history" – ring-buffer; browsable with M.history()
--
-- Works out-of-the-box after require() — no setup() call needed. Its live config is
-- `config.notify`; setup() merges user opts into it IN PLACE (via utils.merge) so the `_cfg`
-- alias and every `require("lvim-hud.config").notify` reader see the effective values.
--
---@module "lvim-hud.notify"

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop
local colors = require("lvim-utils.colors")
local config = require("lvim-hud.config")
local hl = require("lvim-utils.highlight")
local merge = require("lvim-utils.utils").merge
local levels = vim.log.levels
local NS = api.nvim_create_namespace("lvim_utils_notify")

-- ── level metadata ────────────────────────────────────────────────────────

-- Per-panel metadata: key → { icon_key, name, icon, hl, header_hl }
-- icon_key  – looked up in _cfg.icons and _cfg.level_names (built-in panels)
-- name      – explicit display name (overrides icon_key-based lookup when set)
-- icon      – explicit icon char (overrides _cfg.icons lookup when set)
-- hl        – highlight group for content lines
-- header_hl – highlight group for the header bar
-- Reverse map: vim.log.levels integer → icon_key string
local LEVEL_KEY = {
    [levels.TRACE] = "trace",
    [levels.DEBUG] = "debug",
    [levels.INFO] = "info",
    [levels.WARN] = "warn",
    [levels.ERROR] = "error",
}

local _panel_meta = {
    [levels.TRACE] = {
        icon_key = "trace",
        hl = "LvimNotifyDebug",
        header_hl = "LvimNotifyHeaderDebug",
        sep_hl = "LvimNotifySepDebug",
        title_hl = "LvimNotifyTitleDebug",
    },
    [levels.DEBUG] = {
        icon_key = "debug",
        hl = "LvimNotifyDebug",
        header_hl = "LvimNotifyHeaderDebug",
        sep_hl = "LvimNotifySepDebug",
        title_hl = "LvimNotifyTitleDebug",
    },
    [levels.INFO] = {
        icon_key = "info",
        hl = "LvimNotifyInfo",
        header_hl = "LvimNotifyHeaderInfo",
        sep_hl = "LvimNotifySepInfo",
        title_hl = "LvimNotifyTitleInfo",
    },
    [levels.WARN] = {
        icon_key = "warn",
        hl = "LvimNotifyWarn",
        header_hl = "LvimNotifyHeaderWarn",
        sep_hl = "LvimNotifySepWarn",
        title_hl = "LvimNotifyTitleWarn",
    },
    [levels.ERROR] = {
        icon_key = "error",
        hl = "LvimNotifyError",
        header_hl = "LvimNotifyHeaderError",
        sep_hl = "LvimNotifySepError",
        title_hl = "LvimNotifyTitleError",
    },
}

-- Bottom-to-top stacking order (ERROR closest to bottom edge)
-- Custom panels registered via M.register_panel() are prepended (shown highest).
local PANEL_ORDER = {
    levels.ERROR,
    levels.WARN,
    levels.INFO,
    levels.DEBUG,
    levels.TRACE,
}

-- ── runtime state ─────────────────────────────────────────────────────────

local _cfg = config.notify
local _history = {}
local _printers = {}
-- The unified history-zone view's state, PERSISTED across the passive live render and the focused browse (so a
-- new message arriving while you browse keeps your filter, and the focus save/restore is not clobbered).
local _hist_filter = nil ---@type string?
local _hist_saved = nil ---@type table?
local _hist_sel = 1 ---@type integer  the focused filter-bar button (l/h move it; <CR> activates it)

--- The message-zone sink (the msgarea zone) that `:Messages` browses the log in. The edge is INVERTED —
--- notify never requires msgarea; msgarea registers itself here in its setup. The sink implements the zone
--- contract notify drives; when nil, `:Messages` falls back to notify's own cmdline pager.
---@class LvimNotifyHistorySink
---@field is_enabled fun(): boolean  whether the zone is on
---@field segment fun(name: string, opts?: table): table  get/create the named zone segment
---@field is_focused fun(name: string): boolean  whether the named segment currently holds focus
---@field bar_focused fun(): boolean  whether the zone's filter bar sub-sector holds focus
---@field zone_width fun(): integer  the real panel width (not vim.o.columns)
---@field blur fun()  leave/close the zone

--- The registered message-zone sink, or nil when no zone is installed.
---@type LvimNotifyHistorySink?
local _history_sink = nil

--- Register the message-zone sink for `:Messages` history browsing (the msgarea zone). Called by
--- lvim-msgarea in its setup; keeps notify free of any msgarea dependency.
---@param sink LvimNotifyHistorySink
function M.set_history_sink(sink)
    _history_sink = sink
end

-- One panel per level: _panels[level] = { win, buf, width, height, entries }
local _panels = {}

-- Named progress channels, each rendered as its own independent floating panel.
-- Registered via M.progress_register(id, opts); updated via M.progress_update(id, lines).
-- _prog_channels[id] = { name, icon, header_hl, lines, marks, natural_w, win, buf, height }
local _prog_channels = {}
-- Insertion order: first registered = lowest in the stack (closest to bottom edge).
local _prog_order = {}
-- Last global panel width committed by _rebuild_all — lets progress_update skip the full uniform rebuild when
-- the width is unchanged (the common case on a $/progress burst) and re-render only the changed channel.
---@type integer?
local _last_global_w = nil

-- ── helpers ───────────────────────────────────────────────────────────────

local function dw(s)
    return vim.fn.strdisplaywidth(tostring(s or ""))
end

local function wrap(text, limit)
    if limit <= 0 then
        return { tostring(text) }
    end
    local lines = {}
    for raw in tostring(text):gmatch("[^\n]+") do
        local line = ""
        for word in raw:gmatch("%S+") do
            local candidate = line == "" and word or (line .. " " .. word)
            if dw(candidate) > limit then
                if line ~= "" then
                    table.insert(lines, line)
                end
                line = word
            else
                line = candidate
            end
        end
        if line ~= "" then
            table.insert(lines, line)
        end
    end
    return #lines > 0 and lines or { "" }
end

-- ── panel management ──────────────────────────────────────────────────────

local function _close_panel(level)
    local p = _panels[level]
    if not p then
        return
    end
    if api.nvim_win_is_valid(p.win) then
        api.nvim_win_close(p.win, true)
    end
    if api.nvim_buf_is_valid(p.buf) then
        api.nvim_buf_delete(p.buf, { force = true })
    end
    _panels[level] = nil
end

--- Rows of screen below the toast stack: the command-line (`cmdheight` — which GROWS when the msgarea zone /
--- cmdline area opens below the statusline) + the global statusline (1 row when shown) + the configured
--- `bottom_margin` gap. The stack is anchored this many rows up from the bottom, so it sits ABOVE the
--- statusline and RIDES UP with it as the area grows `cmdheight` (and back down when the area closes).
---@return integer
local function _bottom_offset()
    local statusline = (vim.o.laststatus >= 2) and 1 or 0
    return vim.o.cmdheight + statusline + _cfg.bottom_margin
end

--- Reposition all open panels so they stack from the bottom offset upward.
--- Progress channels are at the bottom (in registration order); level panels stack above.
local function _restack()
    local offset = _bottom_offset()

    for _, id in ipairs(_prog_order) do
        local ch = _prog_channels[id]
        if ch and ch.win and api.nvim_win_is_valid(ch.win) then
            local win_row = math.max(0, vim.o.lines - offset - (ch.height or 1))
            api.nvim_win_set_config(ch.win, {
                relative = "editor",
                row = win_row,
                col = api.nvim_win_get_config(ch.win).col,
            })
            offset = offset + (ch.height or 1) + _cfg.panel_gap
        end
    end

    for _, lvl in ipairs(PANEL_ORDER) do
        local p = _panels[lvl]
        if p and api.nvim_win_is_valid(p.win) then
            local win_row = math.max(0, vim.o.lines - offset - p.height)
            api.nvim_win_set_config(p.win, {
                relative = "editor",
                row = win_row,
                col = api.nvim_win_get_config(p.win).col,
            })
            offset = offset + p.height + _cfg.panel_gap
        end
    end
end

local _rebuild_all -- forward declaration; defined after progress helpers

--- Rebuild one panel's buffer content at the given width. No restack.
local function _rebuild_panel(level, win_w)
    local p = _panels[level]
    if not p or #p.entries == 0 then
        return
    end

    p.width = win_w

    local cfg_icons = _cfg.icons or {}
    local cfg_names = _cfg.level_names or {}
    local meta = _panel_meta[level] or {}
    local icon_key = meta.icon_key or tostring(level)
    local pad_s = string.rep(" ", _cfg.padding)
    local count = #p.entries
    local name = meta.name or cfg_names[icon_key] or icon_key
    local icon = meta.icon or cfg_icons[icon_key] or " "
    local header_hl = meta.header_hl or "LvimNotifyHeaderInfo"
    local sep_hl = meta.sep_hl or "LvimNotifySepInfo"
    if count > 1 then
        name = name .. "s"
    end

    local hdr = pad_s .. icon .. " " .. name
    local fill = win_w - dw(hdr)
    if fill > 0 then
        hdr = hdr .. string.rep(" ", fill)
    end

    local sep = string.rep(_cfg.separator or "─", win_w)

    local all_lines = { hdr }
    local row_offset = 1
    local col_marks = {}
    local sep_rows = {}

    for i, entry in ipairs(p.entries) do
        if i > 1 and _cfg.show_separator ~= false then
            table.insert(all_lines, sep)
            table.insert(sep_rows, row_offset)
            row_offset = row_offset + 1
        end
        for _, l in ipairs(entry.lines) do
            local lw = dw(l)
            table.insert(all_lines, lw < win_w and (l .. string.rep(" ", win_w - lw)) or l)
        end
        for _, m in ipairs(entry.marks) do
            table.insert(col_marks, { m[1] + row_offset, m[2], m[3], m[4] })
        end
        row_offset = row_offset + #entry.lines
    end

    local h = #all_lines
    local buf = p.buf
    local win = p.win
    -- The scratch buffer can be wiped out from under us (e.g. an external :bwipeout!) between renders; writing
    -- to an invalid buffer throws out of a TTL defer_fn / progress tick. Treat the panel as dead and drop it
    -- (a fresh toast recreates it) instead of erroring.
    if not api.nvim_buf_is_valid(buf) then
        _close_panel(level)
        return
    end
    local win_col = math.max(0, vim.o.columns - win_w - 1)

    api.nvim_set_option_value("modifiable", true, { buf = buf })
    api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
    api.nvim_set_option_value("modifiable", false, { buf = buf })

    api.nvim_buf_clear_namespace(buf, NS, 0, -1)

    -- Set an extmark, CLAMPING its byte columns to the target line's actual length. `nvim_buf_set_extmark`
    -- errors ("col_end out of range") if `end_col` (or `col`) runs past the line — which can happen when a
    -- mark's byte column was computed against pre-padding / multibyte text or a shorter-than-expected line. The
    -- clamp is the root-cause guard so a progress-channel redraw never throws.
    ---@param row integer  0-based line
    ---@param col integer  0-based start byte column
    ---@param o table      extmark opts (with `end_col`)
    local function set_col_mark(row, col, o)
        local len = #(all_lines[row + 1] or "")
        o.end_col = math.min(o.end_col or len, len)
        api.nvim_buf_set_extmark(buf, NS, row, math.min(col, len), o)
    end

    set_col_mark(0, 0, {
        end_col = #hdr,
        hl_group = header_hl,
        hl_eol = true,
        priority = 200,
    })

    -- Tint the whole content body (every row below the header bar) one level — the
    -- separator and title marks layer their fg on top. Only when a matching Body group
    -- exists (the standard levels; custom panels keep the plain panel bg).
    local body_hl, n_body = header_hl:gsub("Header", "Body")
    if n_body > 0 then
        for r = 1, h - 1 do
            api.nvim_buf_set_extmark(buf, NS, r, 0, {
                line_hl_group = body_hl,
                priority = 100,
            })
        end
    end

    for _, r in ipairs(sep_rows) do
        set_col_mark(r, 0, {
            end_col = #sep,
            hl_group = sep_hl,
            hl_eol = true,
            priority = 150,
        })
    end

    for _, m in ipairs(col_marks) do
        set_col_mark(m[1], m[2], {
            end_col = m[3],
            hl_group = m[4],
            priority = 150,
        })
    end

    if not api.nvim_win_is_valid(win) then
        return
    end
    p.height = h
    api.nvim_win_set_config(win, {
        relative = "editor",
        width = win_w,
        height = h,
        row = math.max(0, vim.o.lines - _bottom_offset() - h),
        col = win_col,
    })
end

--- Global max natural_w across every notify entry and every progress channel.
local function _global_max_w()
    local w = _cfg.min_width
    for _, p in pairs(_panels) do
        for _, e in ipairs(p.entries) do
            w = math.max(w, e.natural_w or 0)
        end
    end
    for _, ch in pairs(_prog_channels) do
        w = math.max(w, ch.natural_w or 0)
    end
    return w
end

--- Close empty panel for `level` if needed, then trigger a full uniform rebuild.
local function _rebuild(level)
    local p = _panels[level]
    if p and #p.entries == 0 then
        _close_panel(level)
    end
    _rebuild_all()
end

-- ── progress channels ─────────────────────────────────────────────────────

--- Render (or close) one named progress channel at the given width. No restack.
local function _render_prog_channel(id, win_w)
    local ch = _prog_channels[id]
    if not ch then
        return
    end

    if not ch.lines or #ch.lines == 0 then
        if ch.win and api.nvim_win_is_valid(ch.win) then
            api.nvim_win_close(ch.win, true)
        end
        if ch.buf and api.nvim_buf_is_valid(ch.buf) then
            api.nvim_buf_delete(ch.buf, { force = true })
        end
        ch.win = nil
        ch.buf = nil
        ch.height = nil
        return
    end

    local pad_s = string.rep(" ", _cfg.padding)
    local hdr_icon = ch.icon or (_cfg.icons or {}).progress or ""
    local hdr_name = ch.name or tostring(id)
    local hdr_hl = ch.header_hl or "LvimNotifyHeaderInfo"
    local hdr_text = pad_s .. hdr_icon .. " " .. hdr_name
    local hdr_fill = win_w - dw(hdr_text)
    if hdr_fill > 0 then
        hdr_text = hdr_text .. string.rep(" ", hdr_fill)
    end

    -- col_marks format: { row, col_start, col_end_bytes, hl_group, hl_eol? }
    local all_lines = { hdr_text }
    local col_marks = { { 0, 0, #hdr_text, hdr_hl, true } }
    local row_offset = 1

    for _, l in ipairs(ch.lines) do
        local safe = l:gsub("\n", " ")
        local lw = dw(safe)
        table.insert(all_lines, lw < win_w and (safe .. string.rep(" ", win_w - lw)) or safe)
    end
    for _, m in ipairs(ch.marks or {}) do
        table.insert(col_marks, { row_offset + m[1], m[2], m[3], m[4] })
    end

    local h = #all_lines
    local win_col = math.max(0, vim.o.columns - win_w - 1)

    -- Recreate when the window OR its scratch buffer is gone (an external :bwipeout! can wipe the buffer,
    -- leaving a stale window); close any stale window first so a fresh one doesn't orphan it.
    if not ch.win or not api.nvim_win_is_valid(ch.win) or not ch.buf or not api.nvim_buf_is_valid(ch.buf) then
        if ch.win and api.nvim_win_is_valid(ch.win) then
            api.nvim_win_close(ch.win, true)
        end
        local buf = api.nvim_create_buf(false, true)
        api.nvim_set_option_value("filetype", "lvim-utils-notify", { buf = buf })
        local win = api.nvim_open_win(buf, false, {
            relative = "editor",
            row = math.max(0, vim.o.lines - _bottom_offset() - h),
            col = win_col,
            width = win_w,
            height = h,
            border = _cfg.border or "none",
            style = "minimal",
            focusable = false,
            zindex = math.max(1, _cfg.zindex - 10),
        })
        api.nvim_set_option_value("winhl", "Normal:LvimNotifyNormal", { win = win })
        ch.win = win
        ch.buf = buf
    end

    local buf = ch.buf
    api.nvim_set_option_value("modifiable", true, { buf = buf })
    api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
    api.nvim_set_option_value("modifiable", false, { buf = buf })

    api.nvim_buf_clear_namespace(buf, NS, 0, -1)

    -- Body tint (0.2) over the progress content rows, same as the toast panels; the header
    -- bar (row 0, hdr_hl at 0.3) and the col marks sit on top.
    local body_hl, n_body = hdr_hl:gsub("Header", "Body")
    if n_body > 0 then
        for r = 1, h - 1 do
            api.nvim_buf_set_extmark(buf, NS, r, 0, {
                line_hl_group = body_hl,
                priority = 100,
            })
        end
    end

    for _, m in ipairs(col_marks) do
        -- clamp col + end_col to the line's byte length: a mark's byte column can run past a
        -- shorter-than-expected / pre-padding / multibyte line, which errors ("end_col out of
        -- range") — the same guard the per-level panel render uses (see `set_mark`).
        local len = #(all_lines[m[1] + 1] or "")
        api.nvim_buf_set_extmark(buf, NS, m[1], math.min(m[2], len), {
            end_col = math.min(m[3], len),
            hl_group = m[4],
            hl_eol = m[5] or false,
            priority = 150,
        })
    end

    ch.height = h
    if api.nvim_win_is_valid(ch.win) then
        api.nvim_win_set_config(ch.win, {
            relative = "editor",
            width = win_w,
            height = h,
            row = math.max(0, vim.o.lines - _bottom_offset() - h),
            col = win_col,
        })
    end
end

--- Coalesce redraw requests into ONE light repaint per event-loop tick. Replaces a per-update `redraw!`
--- (a full-screen CLEAR + redraw) that flickered the WHOLE screen on every progress/notify change — LSP
--- `$/progress` fires often, so that was the main editing flicker. `:redraw` (no `!`) repaints the dirty
--- regions (the floats) without the screen-clear; the pending flag collapses a burst into a single repaint.
---
--- `:redraw` repaints only the DIRTY regions (the panels), so the STATUSLINE — which a panel may overlap, and
--- whose `%!` expression is otherwise not re-evaluated mid-burst — is left on a stale frame (visible at startup
--- while `$/progress` runs). `redrawstatus` after it keeps the line current; it is cheap (a cached chrome line)
--- and repaints identical content, so it cannot flicker.
local _redraw_pending = false
local function flush_redraw()
    if _redraw_pending then
        return
    end
    _redraw_pending = true
    vim.schedule(function()
        _redraw_pending = false
        pcall(vim.cmd, "redraw")
        pcall(vim.cmd, "redrawstatus")
    end)
end

--- Master rebuild: one global width for ALL panels (notify levels + progress channels).
_rebuild_all = function()
    local win_w = _global_max_w()
    _last_global_w = win_w
    for _, lvl in ipairs(PANEL_ORDER) do
        if _panels[lvl] then
            _rebuild_panel(lvl, win_w)
        end
    end
    for _, id in ipairs(_prog_order) do
        _render_prog_channel(id, win_w)
    end
    _restack()
    flush_redraw()
end

-- Reflow the notification stack on terminal/window resize: each panel's right-edge column comes
-- from `vim.o.columns` and the bottom-up stack from `vim.o.lines`, so a rebuild re-anchors them
-- all. Installed once (the module is a singleton); a no-op when nothing is on screen.
api.nvim_create_autocmd("VimResized", {
    group = api.nvim_create_augroup("LvimUtilsNotifyResize", { clear = true }),
    callback = function()
        if next(_panels) or next(_prog_channels) then
            _rebuild_all()
        end
    end,
})

-- Re-anchor the stack whenever `cmdheight` changes: the msgarea zone / cmdline area opens by GROWING
-- `cmdheight` (pushing the statusline up), so the toast stack — anchored above the statusline via
-- `_bottom_offset()` — must ride up with it (and back down when the area closes). A move-only `_restack`
-- (no content rebuild); a no-op when nothing is on screen.
api.nvim_create_autocmd("OptionSet", {
    pattern = "cmdheight",
    group = api.nvim_create_augroup("LvimUtilsNotifyCmdheight", { clear = true }),
    callback = function()
        if next(_panels) or next(_prog_channels) then
            _restack()
            flush_redraw()
        end
    end,
})

-- ── toast printer ─────────────────────────────────────────────────────────

local function _show_toast(msg, level, opts)
    opts = opts or {}
    level = level or levels.INFO
    msg = tostring(msg or "")

    local meta = _panel_meta[level] or {}
    local title_hl = meta.title_hl or "LvimNotifyTitleInfo"
    local title = opts.title and tostring(opts.title) or nil
    local pad = _cfg.padding
    local pad_s = string.rep(" ", pad)
    local max_w = _cfg.max_width
    local min_w = _cfg.min_width
    local available = max_w - pad * 2
    local msg_lines = wrap(msg, available)
    -- `timeout = false` is the sticky convention (a toast that never auto-dismisses); it maps to 0 (0 already
    -- means "no timer" below). A plain `and/or` would let false fall through to the default — so branch it.
    local timeout
    if opts.timeout == false then
        timeout = 0
    elseif opts.timeout ~= nil then
        timeout = opts.timeout
    else
        timeout = _cfg.timeout
    end

    -- (Re)render an entry's buffer lines + marks + natural width. A `×N` badge is shown
    -- when the same toast has been collapsed more than once (see dedup below). Also
    -- (re)sets the sliding deadline so a repeat refreshes the timeout.
    local function render(entry)
        local lines, marks, ri = {}, {}, 0
        local function push(str, m)
            table.insert(lines, str)
            if m then
                table.insert(marks, { ri, m[1], m[2], m[3] })
            end
            ri = ri + 1
        end
        local badge = (entry.count and entry.count > 1) and ("  ×" .. entry.count) or ""
        if entry.title then
            push(pad_s .. entry.title .. badge, { pad, pad + dw(entry.title), title_hl })
        end
        for i, mline in ipairs(entry.msg_lines) do
            push(pad_s .. mline .. ((not entry.title and i == 1) and badge or ""))
        end
        local inner_w = 0
        for _, l in ipairs(lines) do
            inner_w = math.max(inner_w, dw(l))
        end
        entry.lines, entry.marks = lines, marks
        entry.natural_w = math.min(max_w, math.max(min_w, inner_w + pad * 2))
        entry.deadline = vim.uv.now() + timeout
    end

    -- Dedup: an identical consecutive toast (same level, title, message) bumps a counter
    -- on the existing entry instead of stacking a duplicate, and refreshes its deadline.
    local p = _panels[level]
    if _cfg.dedup ~= false and p and api.nvim_win_is_valid(p.win) then
        local last = p.entries[#p.entries]
        if last and last.title == title and last.raw == msg then
            last.count = (last.count or 1) + 1
            render(last)
            _rebuild(level)
            return
        end
    end

    local entry = { title = title, msg_lines = msg_lines, raw = msg, count = 1 }
    render(entry)

    -- Create panel for this level if needed.
    -- Initial width uses natural_w; _rebuild will widen it when more entries arrive.
    if not _panels[level] or not api.nvim_win_is_valid(_panels[level].win) then
        -- An externally-closed toast window leaves a stale panel with a still-valid bufhidden=hide buffer;
        -- _close_panel deletes that buffer (and closes the win if any) instead of orphaning it on a bare nil.
        _close_panel(level)
        local buf = api.nvim_create_buf(false, true)
        local win_col = math.max(0, vim.o.columns - entry.natural_w - 1)
        api.nvim_set_option_value("filetype", "lvim-utils-notify", { buf = buf })
        local win = api.nvim_open_win(buf, false, {
            relative = "editor",
            row = math.max(0, vim.o.lines - _bottom_offset() - 2),
            col = win_col,
            width = entry.natural_w,
            height = 1,
            border = _cfg.border or "none",
            style = "minimal",
            focusable = false,
            zindex = _cfg.zindex,
        })
        api.nvim_set_option_value("winhl", "Normal:LvimNotifyNormal", { win = win })
        _panels[level] = { win = win, buf = buf, width = entry.natural_w, height = 1, entries = {} }
    end

    table.insert(_panels[level].entries, entry)
    _rebuild(level)

    if timeout > 0 then
        -- Sliding-deadline removal: a dedup hit pushes `entry.deadline` forward, so the
        -- toast persists while it keeps repeating and clears `timeout` ms after the last.
        local function schedule_remove()
            vim.defer_fn(function()
                local pp = _panels[level]
                if not pp then
                    return
                end
                for i, e in ipairs(pp.entries) do
                    if e == entry then
                        if vim.uv.now() < (e.deadline or 0) then
                            schedule_remove()
                        else
                            table.remove(pp.entries, i)
                            _rebuild(level)
                        end
                        break
                    end
                end
            end, math.max(50, (entry.deadline or 0) - vim.uv.now()))
        end
        schedule_remove()
    end
end

-- ── history printer ────────────────────────────────────────────────────────

--- Seconds a message stays PASSIVELY visible in the zone (`history.hide_after`); 0 = forever (old behaviour).
---@return integer
local function _hide_after()
    return tonumber((_cfg.history or {}).hide_after) or 0
end

---@type integer?  uv.now() at which the countdowns were PAUSED (the zone has focus); nil while they run
local _hist_paused_at = nil
---@type integer  message lines the zone showed on the LAST render (the reflow is deferred, so the buffer
--- cannot be measured in time — this is how "how many rows appeared above the reader" is known)
local _hist_rendered = 0
---@type boolean  the reader closed the panel with `q`: stay hidden until a NEW message (or a re-open)
local _hist_dismissed = false
---@type uv.uv_timer_t?  fires at the next message's expiry (re-armed after each render)
local _hist_timer = nil

--- The LIFE glyph for a message: a circle that DRAINS as its countdown runs out (full on arrival, empty just
--- before it goes). Picked by the REMAINING FRACTION — unlike the LSP progress spinner, which cycles its
--- frames on a timer regardless of the work done, this one MEANS something: it is the message's time left.
--- Empty string when transient mode is off, when the glyphs are disabled, or when the message has no clock.
---@param item table
---@return string
local function _hist_life(item)
    local icons = (_cfg.history or {}).life_icons
    if _hide_after() <= 0 or type(icons) ~= "table" or #icons == 0 or not item.expires then
        return ""
    end
    -- PAUSED (the reader is in the zone): the clocks are frozen, so the glyph freezes with them — it shows the
    -- time each message will still have when they leave, not a countdown that kept running while they read.
    local now = _hist_paused_at or uv.now()
    local left = (item.expires - now) / (_hide_after() * 1000)
    if left <= 0 then
        return "" -- out of time: the glyph is GONE (such a message is only ever seen in the browse view)
    end
    if left > 1 then
        left = 1
    end
    -- fraction 1 → frame 1 (full) … fraction →0 → the last frame (empty)
    local idx = #icons - math.floor(left * #icons + 0.5) + 1
    return icons[math.max(1, math.min(#icons, idx))]
end

--- Has this message run out of its passive time? Never while the countdowns are paused (you are reading the
--- zone) and never when `hide_after = 0`.
---@param item table
---@return boolean
local function _hist_expired(item)
    if _hide_after() <= 0 or _hist_paused_at ~= nil or not item.expires then
        return false
    end
    return uv.now() >= item.expires
end

local function _append_history(msg, level, opts)
    table.insert(_history, {
        msg = tostring(msg or ""),
        level = level or levels.INFO,
        opts = opts or {},
        time = os.time(),
        -- Its OWN clock, started when it ARRIVES: a new message never extends an older one's time.
        expires = _hide_after() > 0 and (uv.now() + _hide_after() * 1000) or nil,
    })
    _hist_dismissed = false -- a new message always shows, even if the panel was closed with `q`
    local max = _cfg.max_history or 100
    while #_history > max do
        table.remove(_history, 1)
    end
end

-- ── dispatch ───────────────────────────────────────────────────────────────

-- Routing sinks for ext_messages behaviours other than toast/history (e.g. "cmdline").
-- name → fun(text, level, opts). Registered by domain modules; NOT iterated by _dispatch,
-- so a sink fires only for messages explicitly routed to it via ext_kinds.
local _sinks = {}

local _in_dispatch = false

local function _dispatch(msg, level, opts)
    if vim.in_fast_event() then
        return vim.schedule(function()
            _dispatch(msg, level, opts)
        end)
    end
    if _in_dispatch then
        return
    end
    _in_dispatch = true
    for _, p in ipairs(_printers) do
        local ok, err = pcall(p.fn, msg, level, opts)
        if not ok then
            pcall(
                vim.api.nvim_echo,
                { { "lvim-hud notify printer failed: " .. tostring(err), "WarningMsg" } },
                true,
                {}
            )
        end
    end
    _in_dispatch = false
end

-- ── public API ─────────────────────────────────────────────────────────────

function M.add_printer(name, fn)
    M.remove_printer(name)
    table.insert(_printers, { name = name, fn = fn })
end

function M.remove_printer(name)
    for i, p in ipairs(_printers) do
        if p.name == name then
            table.remove(_printers, i)
            return
        end
    end
end

function M.has_printer(name)
    for _, p in ipairs(_printers) do
        if p.name == name then
            return true
        end
    end
    return false
end

--- Register a routing sink for an ext_kinds behaviour (e.g. "cmdline"). Unlike a printer,
--- it is only called for messages whose kind maps to `name` in ext_kinds. Pass `nil` to remove.
---@param name string
---@param fn fun(text: string, level: integer, opts: table)|nil
function M.register_sink(name, fn)
    _sinks[name] = fn
end

-- Saved original `ext_kinds` values, so a temporary routing (e.g. msgarea while enabled) can be
-- restored verbatim on teardown.
---@type table<string, any>
local _saved_kinds = {}

--- Route message kinds to a behaviour at runtime (e.g. `{ echomsg = "msgarea" }`), saving whatever
--- each kind mapped to before so `unroute_kinds` can put it back. Mutates the live ext_kinds the
--- ext_messages handler reads.
---@param map table<string, string>
function M.route_kinds(map)
    _cfg.ext_kinds = _cfg.ext_kinds or {}
    for kind, behaviour in pairs(map or {}) do
        if _saved_kinds[kind] == nil then
            -- false sentinel = "was absent" (so we can delete it again, not leave it set)
            _saved_kinds[kind] = _cfg.ext_kinds[kind] == nil and false or _cfg.ext_kinds[kind]
        end
        _cfg.ext_kinds[kind] = behaviour
    end
end

--- Restore the `ext_kinds` entries for `keys` to what they were before `route_kinds`.
---@param keys string[]
function M.unroute_kinds(keys)
    _cfg.ext_kinds = _cfg.ext_kinds or {}
    for _, kind in ipairs(keys or {}) do
        local prev = _saved_kinds[kind]
        if prev ~= nil then
            _cfg.ext_kinds[kind] = (prev == false) and nil or prev
            _saved_kinds[kind] = nil
        end
    end
end

function M.notify(msg, level, opts)
    _dispatch(msg, level, opts)
end
function M.get_history()
    return vim.deepcopy(_history)
end
function M.clear()
    _history = {}
end

--- Register a named progress channel with its own floating panel and appearance.
--- Safe to call multiple times; subsequent calls update appearance only.
---@param id   string  Unique channel identifier
---@param opts table   { name?: string, icon?: string, header_hl?: string }
function M.progress_register(id, opts)
    opts = opts or {}
    if not _prog_channels[id] then
        _prog_channels[id] = {}
        table.insert(_prog_order, id)
    end
    local ch = _prog_channels[id]
    if opts.name ~= nil then
        ch.name = opts.name
    end
    if opts.icon ~= nil then
        ch.icon = opts.icon
    end
    if opts.header_hl ~= nil then
        ch.header_hl = opts.header_hl
    end
end

--- Register a custom panel with a unique key, display name, and highlight groups.
--- The panel is stacked above all built-in severity panels by default.
---@param key  any     Unique identifier (string or integer) for the panel
---@param opts table   { name: string, icon: string, hl: string, header_hl: string, order?: integer }
function M.register_panel(key, opts)
    opts = opts or {}
    _panel_meta[key] = {
        name = opts.name,
        icon = opts.icon,
        hl = opts.hl or "LvimNotifyInfo",
        header_hl = opts.header_hl or "LvimNotifyHeaderInfo",
    }
    -- Remove any existing position for this key, then insert at requested order.
    for i, k in ipairs(PANEL_ORDER) do
        if k == key then
            table.remove(PANEL_ORDER, i)
            break
        end
    end
    table.insert(PANEL_ORDER, opts.order or 1, key)
end

--- Push a message directly to a named panel (built-in or custom).
--- Accepts the same opts as vim.notify (title, timeout, …).
---@param key  any     Panel key passed to M.register_panel, or a vim.log.levels value
---@param msg  string
---@param opts table|nil
function M.push(key, msg, opts)
    _show_toast(msg, key, opts)
end

--- Update content for a named progress channel (auto-registers if unknown).
---@param id    string
---@param lines string[]
---@param marks table[]|nil  { row, col_start, col_end, hl_group } (row 0-based within lines)
function M.progress_update(id, lines, marks)
    if not _prog_channels[id] then
        _prog_channels[id] = {}
        table.insert(_prog_order, id)
    end
    local ch = _prog_channels[id]
    ch.lines = lines
    ch.marks = marks or {}
    local min_w = _cfg.min_width
    local max_w = _cfg.max_width
    local nw = min_w
    for _, l in ipairs(lines) do
        nw = math.max(nw, dw(l))
    end
    ch.natural_w = math.min(max_w, nw + _cfg.padding * 2)
    -- Fast path: when the GLOBAL panel width is unchanged (the common case on a $/progress burst — many ticks
    -- per second), only THIS channel's content changed, so re-render just it + restack the stack geometry
    -- instead of rewriting every open toast panel's buffer. A width change (a new widest line, or the first
    -- channel) falls back to the full uniform rebuild (which re-caches _last_global_w).
    local w = _global_max_w()
    if _last_global_w ~= nil and w == _last_global_w then
        _render_prog_channel(id, w)
        _restack()
        flush_redraw()
    else
        _rebuild_all()
    end
end

--- Clear content for a named progress channel and close its panel.
---@param id string
function M.progress_clear(id)
    local ch = _prog_channels[id]
    if not ch then
        return
    end
    ch.lines = nil
    ch.marks = nil
    ch.natural_w = nil
    -- The rebuild first closes this channel's now-empty window/buffer (_render_prog_channel with no lines);
    -- then prune the id from BOTH registries so dynamic (per-operation / LSP-token) ids can't accumulate
    -- unboundedly — later rebuilds/width scans no longer iterate the dead channel. register/update recreate
    -- cheaply, so no tombstone is needed.
    _rebuild_all()
    _prog_channels[id] = nil
    for i, v in ipairs(_prog_order) do
        if v == id then
            table.remove(_prog_order, i)
            break
        end
    end
end

--- Clear all progress channels and close all their panels.
function M.progress_clear_all()
    for _, ch in pairs(_prog_channels) do
        ch.lines = nil
        ch.marks = nil
        ch.natural_w = nil
    end
    _rebuild_all()
    -- Prune every (now-closed) channel from both registries, same rationale as progress_clear.
    _prog_channels = {}
    _prog_order = {}
end

-- ── history window ────────────────────────────────────────────────────────

local _hist_NS = api.nvim_create_namespace("lvim_utils_notify_history")

--- Build lines + highlights for the history popup. Returns them without touching any buffer.
local function _history_build(filter)
    local lines = {}
    local highlights = {} -- { line, col_start, col_end, group }
    local levels = {} -- per-line level key ("error"/"warn"/"info"/"debug")

    local function push_hl(group, col_s, col_e)
        table.insert(highlights, { line = #lines - 1, col_start = col_s, col_end = col_e, group = group })
    end

    -- Whole-line tint per level (ui.nvim-style coloured rows).
    local TINT = { error = "LvimUiMsgError", warn = "LvimUiMsgWarn", info = "LvimUiMsgInfo", debug = "LvimUiMsgDebug" }
    local function push_line_hl(group)
        table.insert(highlights, { line = #lines - 1, line_hl = group })
    end

    local function push_header(label)
        local text = "  " .. label
        table.insert(lines, text)
        push_hl("LvimUiTitle", 0, #text)
    end

    -- notifications
    for i = #_history, 1, -1 do
        local item = _history[i]
        if not filter or filter == (LEVEL_KEY[item.level] or "info") then
            local key = LEVEL_KEY[item.level] or "info"
            local cap = key:sub(1, 1):upper() .. key:sub(2)
            local icon = (_cfg.icons or {})[key] or " "
            local ts = os.date("%H:%M:%S", item.time) --[[@as string]]
            local title = item.opts and item.opts.title
            local pre = title and ("[" .. title .. "] ") or ""
            -- Icon badge at column 0 (`  icon  `), aligned directly under the title's icon box
            -- (2 spaces each side). One plain gap cell, then the timestamp, then the message.
            local badge = "  " .. icon .. "  "
            local badge_b = #badge
            local ts_s = badge_b + 1
            local msg_flat = item.msg:gsub("\n", " ")
            local line = badge .. " " .. ts .. "  " .. pre .. msg_flat
            local msg_s = ts_s + #ts + 2
            table.insert(lines, line)
            levels[#lines] = key
            push_line_hl(TINT[key] or "LvimUiMsgInfo")
            push_hl("LvimUiMsg" .. cap .. "Icon", 0, badge_b)
            push_hl("LvimUiFooterLabel", ts_s, ts_s + #ts)
            -- Message text in the level colour (same hue as the icon).
            push_hl("LvimUiMsg" .. cap .. "Text", msg_s, #line)
        end
    end

    -- Filtered to a level that has no records: one placeholder row in that level's style.
    if #lines == 0 then
        local key = filter or "info"
        local cap = key:sub(1, 1):upper() .. key:sub(2)
        local icon = (_cfg.icons or {})[key] or " "
        local badge = "  " .. icon .. "  "
        local badge_b = #badge
        local line = badge .. " No " .. cap .. " records"
        table.insert(lines, line)
        levels[#lines] = key
        push_line_hl(TINT[key] or "LvimUiMsgInfo")
        push_hl("LvimUiMsg" .. cap .. "Icon", 0, badge_b)
        push_hl("LvimUiMsg" .. cap .. "Text", badge_b + 1, #line)
    end

    return lines, highlights, levels
end

--- Write pre-built lines + highlights into buf.
local function _history_write(buf, lines, highlights)
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    api.nvim_buf_clear_namespace(buf, _hist_NS, 0, -1)
    for _, m in ipairs(highlights) do
        if m.line_hl then
            -- Whole-line tint as a real hl_group range (+hl_eol), NOT line_hl_group: a
            -- line_hl_group overrides any cell hl_group regardless of priority, which would
            -- swallow the icon badge. As a plain range it loses to the higher-priority badge.
            -- Must span to the next line's start (end_row+1) so the range covers the EOL —
            -- only then does hl_eol fill the rest of the screen line to the window edge.
            api.nvim_buf_set_extmark(buf, _hist_NS, m.line, 0, {
                end_row = m.line + 1,
                end_col = 0,
                hl_group = m.line_hl,
                hl_eol = true,
                priority = 10,
            })
        else
            api.nvim_buf_set_extmark(buf, _hist_NS, m.line, m.col_start, {
                end_col = m.col_end,
                hl_group = m.group,
                priority = 100,
            })
        end
    end
end

local _lvl_map = { i = "info", w = "warn", e = "error", d = "debug" }
local _lvl_labels = { i = "Info", w = "Warn", e = "Error", d = "Debug" }

-- ── history in the msgarea zone ─────────────────────────────────────────────
-- When the msgarea zone is enabled, `:Messages` browses the log IN it (below a hosted finder) — one
-- consistent, navigable message space — instead of the cmdline pager.

local _hist_cap = { info = "Info", warn = "Warn", error = "Error", debug = "Debug" }

--- The history as zone lines (newest first) + parallel whole-row level tints (which take the focused zone's
--- active-row "Sel" boost). `filter` keeps one level, or nil for all.
---@param filter string?
---@param live_only boolean?  passive view: drop the messages whose time has run out (they stay in _history)
---@param width integer?  the zone panel's width — the LIFE glyph is right-aligned inside it
---@return string[] lines, string[] hls
local function _history_zone_lines(filter, live_only, width)
    local lines, hls = {}, {}
    width = width or 0
    for i = #_history, 1, -1 do
        local item = _history[i]
        local key = LEVEL_KEY[item.level] or "info"
        if (not filter or filter == key) and not (live_only and _hist_expired(item)) then
            local icon = (_cfg.icons or {})[key]
            local ts = os.date("%H:%M:%S", item.time) --[[@as string]]
            local title = item.opts and item.opts.title
            local pre = title and ("[" .. title .. "] ") or ""
            local body = (icon and icon ~= "" and (icon .. "  ") or "") .. ts .. "  " .. pre .. item.msg:gsub("\n", " ")
            local row = "  " .. body
            -- The LIFE circle rides the RIGHT edge of its row, two columns in — the message reads left to
            -- right and the time it has left is a margin note, not a prefix. Skipped when the text already
            -- fills the row (there is nowhere to put it that would not overwrite the message).
            local life = _hist_life(item)
            if life ~= "" and width > 0 then
                local pad = width - vim.fn.strdisplaywidth(row) - vim.fn.strdisplaywidth(life) - 2
                if pad > 0 then
                    row = row .. string.rep(" ", pad) .. life .. "  "
                end
            end
            lines[#lines + 1] = row
            hls[#hls + 1] = "LvimUiMsg" .. (_hist_cap[key] or "Info")
        end
    end
    if #lines == 0 and not live_only then
        -- the empty-filter placeholder carries THAT level's own bg tint (a red row for "No Error records", …),
        -- so the empty state reads as belonging to the filtered colour; All (no filter) stays Info-blue.
        lines, hls =
            { "  No " .. (_hist_cap[filter] or "") .. " records" }, { "LvimUiMsg" .. (_hist_cap[filter] or "Info") }
    end
    return lines, hls
end

-- Each history-bar button's hl prefix: a / All is blue (Info), the levels their own colour, Refresh GREEN,
-- close YELLOW (the two extra hues added to msg_highlights).
local _btn_cap = { a = "Info", e = "Error", w = "Warn", i = "Info", d = "Debug", r = "Refresh", q = "Close" }

-- The history filter bar's BUTTONS, in display order. Each: key (the letter + hotkey), label, lvl (the level
-- it filters to, nil for All / actions), filt (a filter vs an action).
local _bar_btns = {
    { id = "all", k = "a", l = "All", lvl = nil, filt = true },
    { id = "error", k = "e", l = "Error", lvl = "error", filt = true },
    { id = "warn", k = "w", l = "Warn", lvl = "warn", filt = true },
    { id = "info", k = "i", l = "Info", lvl = "info", filt = true },
    { id = "debug", k = "d", l = "Debug", lvl = "debug", filt = true },
    { id = "refresh", k = "r", l = "Refresh", lvl = nil, filt = false },
    { id = "close", k = "q", l = "Close", lvl = nil, filt = false },
}

-- The history filter bar rendered THROUGH ui.bar — so it gets real button navigation (`l`/`h` move the
-- selection, the `sel` one lit) + overflow CHEVRONS, like the finder bars. Returns the row text + the per-cell
-- hls (msgarea span format), with the active FILTER bold and the SELECTED button (cursor) lit.
---@param filter string?  the active level filter (nil = All)
---@param opts table  `{ key_pad = {l,r}, label_pad = {l,r}, gap }`
---@param sel? integer  the focused button index — kept VISIBLE (scroll-follow) even when the bar isn't focused
---@param hover? integer  the button to LIGHT (blue hover) — only while the bar sub-sector is focused
---@return string text, table spans
local function _history_bar(filter, opts, sel, hover)
    local uibar = require("lvim-ui.bar")
    local surface = require("lvim-ui.surface")
    local labels = ((_cfg.history or {}).bar or {}).labels or {}
    local items = {}
    for bi, b in ipairs(_bar_btns) do
        if bi > 1 and (opts.gap or 0) > 0 then
            items[#items + 1] = { type = "separator", text = (" "):rep(opts.gap) }
        end
        local cap = _btn_cap[b.k]
        -- Built by the SHARED `surface.button` mapper with the `action` KIND (the letter as its OWN badge box); the
        -- per-LEVEL msg tints (config-driven, history.bar.tints — Badge for the letter, Name for the label; the "A"
        -- variant when ACTIVE or HOVERED) are this consumer's own colours, passed as the `hl` box override.
        items[#items + 1] = surface.button({
            name = labels[b.id] or b.l, -- a config label override, else the default name
            key = b.k, -- the lowercase hotkey (a/e/w/…)
            style = "action",
            active = b.filt and (b.lvl == filter),
            hl = {
                icon = {
                    padding = opts.key_pad,
                    normal = "LvimUiMsg" .. cap .. "BadgeN",
                    active = "LvimUiMsg" .. cap .. "BadgeA",
                    hover = "LvimUiMsg" .. cap .. "BadgeA",
                },
                text = {
                    padding = opts.label_pad,
                    normal = "LvimUiMsg" .. cap .. "NameN",
                    active = "LvimUiMsg" .. cap .. "NameA",
                    hover = "LvimUiMsg" .. cap .. "NameA",
                },
            },
        }, "action")
    end
    -- ui.bar draws the whole row: a left "Messages" TITLE (shown only when NOT on the statusline) with the
    -- buttons stacked to the RIGHT in the remaining width; without a title they sit at the left.
    local res = uibar.render({
        items = items,
        width = opts.width or vim.o.columns,
        align = (opts.title and opts.title ~= "") and "right" or "left",
        sel = sel,
        hover = hover,
        title = opts.title,
        title_hl = "LvimUiMsgAreaTitle",
    })
    local hls = { { eol = true, hl = "LvimUiBarFill", priority = 1 } } -- the continuous bar STRIP under the row
    for _, sp in ipairs(res.spans) do
        hls[#hls + 1] = { c0 = sp[1], c1 = sp[2], hl = sp[3], priority = 100 }
    end
    return res.line, hls
end

--- Render the log into the zone's "history" segment (priority 10 — below a hosted finder), optionally FOCUS
--- it. This is the ONE message view: routed live (`focus=false`) it shows as clean tinted lines (the bar is
--- `title_when_focused`), browsed (`focus=true`, via `:Messages` or a `<C-w>j` descend) it gains the coloured
--- filter bar + `j`/`k` scroll with the active row lit + the level keys + `q`. State (`_hist_filter`,
--- `_hist_saved`) is MODULE-level so a message arriving mid-browse keeps the filter + the focus snapshot.
--- With `history.statusline` (default true) the "Messages" title + count publish to the bottom statusline on
--- focus (so it changes with focus — finder vs messages) and the bar omits the title; else the title sits in
--- the bar. Returns whether the zone took it (false ⇒ zone off, caller falls back to the cmdline pager).
---@param focus boolean  also move focus into the zone (browse) vs just render it (passive live display)
---@return boolean shown
local function _history_zone_render(focus)
    local ma = _history_sink
    if not (ma and ma.is_enabled and ma.is_enabled()) then
        return false
    end
    if focus then
        _hist_dismissed = false -- an explicit open (`:Messages`) always shows the history again
    end
    local hcfg = _cfg.history or {}
    local bcfg = hcfg.bar or {}
    local opts = { key_pad = bcfg.key_pad or { 1, 1 }, label_pad = bcfg.label_pad or { 1, 1 }, gap = bcfg.gap or 0 }
    local title_text = hcfg.title or "Messages"
    local ok_st, status = pcall(require, "lvim-hud.chrome.overlay")
    local use_status = ok_st and hcfg.statusline ~= false and status.is_enabled()
    -- When NOT on the statusline, the "Messages" label sits at the LEFT of the bar (buttons then stack right).
    opts.title = (not use_status) and title_text or nil
    local seg = ma.segment("history", { priority = 10 })

    -- A message arriving while the user is BROWSING the zone (focused) appears IMMEDIATELY, at the top — it is
    -- a message about what they just did ("3 lines yanked"), and waiting for the next cursor move to reveal it
    -- reads as a broken panel. What must NOT change is their PLACE: the new rows land above them and push every
    -- existing row down, so the cursor is moved by exactly that many lines and stays on the same message.
    local browsing = (not focus) and ma.is_focused ~= nil and ma.is_focused("history")
    -- The passive live display always shows ALL: a new message must appear regardless of a stale browse filter
    -- (e.g. one left on "Error" after a previous `:Messages` was closed). A focused BROWSE keeps its filter.
    if not focus and not browsing then
        _hist_filter = nil
    end

    local function fcount()
        if not _hist_filter then
            return #_history
        end
        local n = 0
        for _, it in ipairs(_history) do
            if (LEVEL_KEY[it.level] or "info") == _hist_filter then
                n = n + 1
            end
        end
        return n
    end

    local function publish() -- the statusline reflects the focused "Messages" context (+ its filtered count)
        if use_status then
            status.set({ title = title_text, total = fcount(), current = 0 })
        end
    end
    --- Re-arm the expiry timer to the EARLIEST live message's deadline. One timer for the whole history — it
    --- fires when something actually expires, it does not poll. Disarmed while paused (focused) or off.
    local function arm()
        if _hist_timer then
            _hist_timer:stop()
            _hist_timer:close()
            _hist_timer = nil
        end
        if _hide_after() <= 0 or _hist_paused_at ~= nil then
            return
        end
        local now, soonest = uv.now(), nil
        for _, it in ipairs(_history) do
            if it.expires and it.expires > now and (soonest == nil or it.expires < soonest) then
                soonest = it.expires
            end
        end
        if not soonest then
            return
        end
        _hist_timer = uv.new_timer()
        if not _hist_timer then
            return
        end
        -- With the LIFE glyph on, the zone must repaint as the circles DRAIN — one tick per frame, so nothing
        -- is redrawn more often than it visibly changes (a 10s life over 8 frames = a repaint every 1.25s).
        -- Without the glyph there is nothing to animate: a single shot at the next expiry is enough.
        local icons = (_cfg.history or {}).life_icons
        local frames = (type(icons) == "table" and #icons) or 0
        local interval = frames > 0 and math.max(200, math.floor((_hide_after() * 1000) / frames))
            or math.max(16, soonest - now)
        local repeat_ms = frames > 0 and interval or 0
        _hist_timer:start(interval, repeat_ms, function()
            vim.schedule(function()
                _history_zone_render(false) -- repaint: the circles drain, the expired ones drop out (zone hides)
            end)
        end)
    end

    --- @param browse boolean?  are we rendering the FOCUSED (browse) view? Passed explicitly — it must never be
    --- read from the enclosing `focus` argument: this closure outlives the call that built it (it is the
    --- segment's on_focus/on_blur/keys handler), so that value goes stale and a blur would still render as if
    --- the reader were inside (which is why `q` looked like it only hid the title bar).
    local function render(browse)
        if browse == nil then
            browse = (ma.is_focused ~= nil and ma.is_focused("history")) == true
        end
        -- light the focused button (hover) ONLY while the BAR sub-sector is focused; keep `sel` always so the
        -- bar scrolls to keep that button visible.
        local hov = (ma.bar_focused and ma.bar_focused()) and _hist_sel or nil
        opts.width = (ma.zone_width and ma.zone_width()) or vim.o.columns -- the REAL panel width (not o.columns)
        local bar, bar_hls = _history_bar(_hist_filter, opts, _hist_sel, hov)
        seg:configure({ title = bar, title_hls = bar_hls })
        -- PASSIVE: only the messages whose time has not run out — that is the whole point of `hide_after`.
        -- BROWSE: everything, because you asked to see it (and nothing expires while you read).
        local live_only = _hide_after() > 0 and not browse
        local lines, hls = _history_zone_lines(_hist_filter, live_only, opts.width)
        if (live_only and #lines == 0) or (_hist_dismissed and not browse) then
            -- nothing live left (every message timed out), or the reader closed the panel with `q`: the zone
            -- has nothing to show and closes. `q` stays dismissed until a NEW message arrives or it is opened
            -- again — otherwise the blur repaint below would just put the messages straight back on screen.
            seg:clear()
            _hist_rendered = 0
            arm()
            return
        end
        -- Keep the reader's PLACE. New messages are prepended, so every row they are reading moves DOWN by
        -- however many rows appeared. The panel's reflow is DEFERRED (the zone re-composes on the next tick),
        -- so the shift is measured from OUR line counts — not the buffer's, which has not changed yet — and
        -- applied after the reflow lands.
        local win = browse and ma.zone_win and ma.zone_win() or nil
        local row = (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_cursor(win)[1] or nil
        local delta = #lines - (_hist_rendered or #lines)
        _hist_rendered = #lines
        seg:set(lines, hls)
        if win and row and delta > 0 then
            vim.schedule(function()
                if api.nvim_win_is_valid(win) then
                    local n = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
                    pcall(api.nvim_win_set_cursor, win, { math.min(row + delta, n), 0 })
                end
            end)
        end
        arm()
    end
    local function refilter(f) -- a filter key (fires only WHILE focused) → re-render + refresh the count
        _hist_filter = f
        render()
        publish()
    end
    local function run_btn(b) -- activate a bar button (a hotkey, or <CR> on the focused one)
        if not b then
            return
        end
        if b.filt then
            refilter(b.lvl) -- a level filter (All / Error / …)
        elseif b.k == "r" then
            render()
            publish() -- Refresh
        elseif b.k == "q" then
            _hist_dismissed = true -- closed by the reader: do not let the blur repaint bring it back
            _hist_rendered = 0
            seg:clear()
            ma.blur() -- close
        end
    end

    seg:configure({
        title_when_focused = true, -- the filter bar shows only while browsing (focused); else clean tinted lines
        keys = {
            -- `q` is the messages panel's OWN close (a segment key overrides msgarea's generic clear+blur):
            -- it must DISMISS the panel, i.e. mark it closed so the blur repaint below does not immediately
            -- put the messages back on screen — which is what made `q` look like it only hid the title bar.
            q = function()
                _hist_dismissed = true
                _hist_rendered = 0
                seg:clear()
                ma.blur()
            end,
            a = function()
                refilter(nil)
            end,
            e = function()
                refilter("error")
            end,
            w = function()
                refilter("warn")
            end,
            i = function()
                refilter("info")
            end,
            d = function()
                refilter("debug")
            end,
            r = function()
                render()
                publish()
            end,
            -- BAR navigation — only while the bar SUB-SECTOR is focused (reached with `<C-k>`): `l`/`h` move the
            -- focused button, `<CR>` activates it (chevrons scroll-follow it). From the content they are inert.
            l = function()
                if not (ma.bar_focused and ma.bar_focused()) then
                    return
                end
                _hist_sel = math.min(#_bar_btns, _hist_sel + 1)
                render()
            end,
            h = function()
                if not (ma.bar_focused and ma.bar_focused()) then
                    return
                end
                _hist_sel = math.max(1, _hist_sel - 1)
                render()
            end,
            ["<CR>"] = function()
                if not (ma.bar_focused and ma.bar_focused()) then
                    return
                end
                run_btn(_bar_btns[_hist_sel])
            end,
        },
        -- The msgarea toggles bar ⇄ content focus (`<C-k>`/`<C-j>`); re-render so the bar's hover follows.
        on_bar_change = function()
            render()
        end,
        -- The statusline is FOCUS-driven (so it is right even on re-descend): entering snapshots whoever owns
        -- the line now (the finder) + shows "Messages"; leaving puts it back (or clears if there was none).
        on_focus = function()
            -- Reading the zone PAUSES every countdown: nothing may vanish under you while you are in it. The
            -- focused view also lists the WHOLE history (see render) — the transient display hides messages,
            -- it never drops them.
            if _hide_after() > 0 and _hist_paused_at == nil then
                _hist_paused_at = uv.now()
            end
            render(true)
            if use_status then
                _hist_saved = status.save()
                publish()
            end
        end,
        on_blur = function()
            -- Leaving RESUMES the countdowns where they stopped — a message with 4s left when you descended
            -- still has 4s left when you come back up, instead of having quietly run out while you read.
            if _hist_paused_at ~= nil then
                local delta = uv.now() - _hist_paused_at
                _hist_paused_at = nil
                for _, it in ipairs(_history) do
                    if it.expires then
                        it.expires = it.expires + delta
                    end
                end
            end
            _hist_filter = nil -- the passive view always shows every level (a browse filter must not linger)
            render(false) -- back to the passive view: only the messages that still have time left
            if use_status then
                status.restore(_hist_saved) -- nil snapshot ⇒ clears (no prior owner)
                _hist_saved = nil
            end
        end,
    })
    render(focus == true or browsing)
    if focus then
        seg:focus() -- fires on_focus → snapshot + publish + show the bar (title_when_focused)
    end
    return true
end

function M.history()
    if #_history == 0 then
        M.push(vim.log.levels.INFO, "No notifications")
        return
    end
    -- The msgarea zone (when on) is the one message space — browse the log there (focused), below a finder.
    if _history_zone_render(true) then
        return
    end

    local filter = nil
    local buf_ref ---@type integer

    local current_levels = {}
    local function rerender()
        if buf_ref and api.nvim_buf_is_valid(buf_ref) then
            local lines, hls, levels = _history_build(filter)
            _history_write(buf_ref, lines, hls)
            current_levels = levels or {}
        end
    end

    -- Per-level colour groups for the pager buttons (key badge + label), matching the
    -- toast/history level colours.
    local _lvl_cap = { info = "Info", warn = "Warn", error = "Error", debug = "Debug" }
    local keymaps = {
        a = {
            fn = function()
                filter = nil
                rerender()
            end,
            label = "All",
        },
        r = { fn = rerender, label = "Refresh" },
    }
    for key, lvl in pairs(_lvl_map) do
        local cap = _lvl_cap[lvl] or "Info"
        keymaps[key] = {
            fn = function()
                filter = filter == lvl and nil or lvl
                rerender()
            end,
            label = _lvl_labels[key],
            badge = "LvimUiMsg" .. cap .. "Icon",
            label_hl = "LvimUiMsg" .. cap .. "Text",
        }
    end

    local cmd = require("lvim-hud.cmdline")
    cmd.pager({
        title = " History ",
        keymaps = keymaps,
        order = { "a", "e", "w", "i", "d", "r" },
        level_at = function(row)
            return current_levels[row + 1]
        end,
        on_open = function(b)
            buf_ref = b
            rerender()
        end,
    })
end

-- ── ext_messages (vim.ui_attach) ──────────────────────────────────────────

-- Map message kind → vim.log.levels
local _KIND_LEVEL = {
    emsg = levels.ERROR,
    echoerr = levels.ERROR,
    lua_error = levels.ERROR,
    rpc_error = levels.ERROR,
    shell_err = levels.ERROR,
    wmsg = levels.WARN,
    echomsg = levels.INFO,
    echo = levels.INFO,
    [""] = levels.INFO,
    bufwrite = levels.INFO,
    undo = levels.INFO,
    shell_out = levels.DEBUG,
    lua_print = levels.DEBUG,
    verbose = levels.DEBUG,
}

--- Convert content fragments [{attr_id, text}, …] to a plain string.
local function _fragments_to_text(content)
    local parts = {}
    for _, frag in ipairs(content) do
        table.insert(parts, frag[2] or "")
    end
    return vim.trim(table.concat(parts))
end

local _in_ext = false
local _ui_attached = false
local _dedup_last = {} -- [text] = uv_hrtime of last dispatch
local _DEDUP_WINDOW = 500 -- ms — same text within this window is dropped

local function _dedup_check(text)
    local now = vim.uv.hrtime() / 1e6 -- ms
    local last = _dedup_last[text]
    if last and (now - last) < _DEDUP_WINDOW then
        return true
    end
    _dedup_last[text] = now
    -- keep table small
    if vim.tbl_count(_dedup_last) > 50 then
        local oldest, oldest_key = math.huge, nil
        for k, t in pairs(_dedup_last) do
            if t < oldest then
                oldest, oldest_key = t, k
            end
        end
        if oldest_key then
            _dedup_last[oldest_key] = nil
        end
    end
    return false
end

local function _attach_ui()
    if _ui_attached then
        return
    end
    _ui_attached = true

    local ns = api.nvim_create_namespace("lvim_utils_ext_messages")

    vim.ui_attach(ns, { ext_messages = true }, function(event, ...)
        if event == "msg_show" then
            local kind, content, _replace = ...

            -- capture args before scheduling (varargs don't survive yield)
            local text_raw = _fragments_to_text(content)

            if kind == "return_prompt" then
                vim.schedule(function()
                    api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
                end)
                return
            end

            local behaviour = (_cfg.ext_kinds or {})[kind] or "history"
            if behaviour == "ignore" then
                return
            end

            vim.schedule(function()
                if _in_ext or _in_dispatch then
                    return
                end
                _in_ext = true
                local ok, err = pcall(function()
                    local text = vim.trim(text_raw)
                    if text == "" then
                        return
                    end
                    if _dedup_check(text) then
                        return
                    end

                    local lvl = _KIND_LEVEL[kind] or levels.INFO
                    local timeout = (lvl == levels.INFO or lvl == levels.DEBUG) and (_cfg.ext_echo_timeout or 3000)
                        or _cfg.timeout

                    _append_history(text, lvl, {})

                    if behaviour == "toast" then
                        _show_toast(text, lvl, { timeout = timeout })
                    elseif behaviour == "zone" then
                        _history_zone_render(false) -- live passive display IN the zone (clean lines; bar on focus)
                    elseif _sinks[behaviour] then
                        _sinks[behaviour](text, lvl, { timeout = timeout })
                    end
                end)
                _in_ext = false
                if not ok then
                    io.stderr:write("[lvim-hud.notify] ext handler error: " .. tostring(err) .. "\n")
                end
            end)
        end
    end)
end

local _initialized = false

--- Per-level highlight groups for the history pager rows. Single source of truth
--- (the cmdline module merges these too). Owned here so the history has its colours
--- even when the cmdline module is disabled. Every strength comes from config (`history.tints` for the
--- rows, `history.bar.tints` for the filter buttons) — the values below are only the fallbacks:
---   LvimUiMsg<L>       row background + text — the level tint the panel is read by   (tints.row)
---   LvimUiMsg<L>Icon   the level icon's cell — a denser badge, bold                  (tints.icon)
---   LvimUiMsg<L>Active a focused row's bg    — kept at the icon's strength so the two merge
---   LvimUiMsg<L>Sel    the row under the cursor while the zone is FOCUSED, bold      (tints.active)
---@return table<string, table>
function M.msg_highlights()
    local c = colors
    local b, bg = c.blend, c.bg
    local g = {}
    -- The per-level accents (+ the two bar-action hues) — config-driven: a PALETTE KEY (tracks the live
    -- theme) or a literal "#rrggbb". Everything below is DERIVED from these, so one entry recolours a level's
    -- row, its icon cell, its focused row and its filter button together.
    local cc = (_cfg.history or {}).colors or {}
    ---@param key string  the config key (error/warn/…)
    ---@param fallback string  the palette key used when it is unset
    ---@return string
    local function accent(key, fallback)
        local v = cc[key] or fallback
        if type(v) == "string" and v:sub(1, 1) == "#" then
            return v
        end
        return c[v] or c[fallback] or c.blue
    end
    local msg = {
        Error = accent("error", "red"),
        Warn = accent("warn", "orange"),
        Info = accent("info", "blue"),
        Debug = accent("debug", "purple"),
        Refresh = accent("refresh", "green"),
        Close = accent("close", "yellow"),
    }
    -- the filter bar's per-part tint strengths come from config (history.bar.tints) — fully customisable.
    local bt = ((_cfg.history or {}).bar or {}).tints or {}
    local badge_t, name_t = bt.badge or {}, bt.name or {}
    local bn, ba = badge_t.normal or 0.2, badge_t.active or 0.4
    local nn, na = name_t.normal or 0.1, name_t.active or 0.3
    -- The message ROWS' own strengths (config-driven, like the bar's).
    local rt = (_cfg.history or {}).tints or {}
    local t_row, t_icon, t_active = rt.row or 0.05, rt.icon or 0.1, rt.active or 0.2
    for name, col in pairs(msg) do
        g["LvimUiMsg" .. name] = { fg = col, bg = b(col, bg, t_row) }
        g["LvimUiMsg" .. name .. "Text"] = { fg = col, bg = b(col, bg, t_row) }
        g["LvimUiMsg" .. name .. "Icon"] = { fg = col, bg = b(col, bg, t_icon), bold = true }
        g["LvimUiMsg" .. name .. "Active"] = { bg = b(col, bg, t_icon) } -- merges with the icon cell
        -- The ACTIVE (cursor) message row while the zone is FOCUSED: same hue, the strongest tint + bold (the
        -- help-window active-row canon), so the focused row is unmistakable while the cursor is hidden.
        g["LvimUiMsg" .. name .. "Sel"] = { fg = col, bg = b(col, bg, t_active), bold = true }
        -- The filter bar's two button parts, each in a NORMAL + ACTIVE/hover tint (config-driven).
        g["LvimUiMsg" .. name .. "BadgeN"] = { fg = col, bg = b(col, bg, bn), bold = true }
        g["LvimUiMsg" .. name .. "BadgeA"] = { fg = col, bg = b(col, bg, ba), bold = true }
        g["LvimUiMsg" .. name .. "NameN"] = { fg = col, bg = b(col, bg, nn) }
        g["LvimUiMsg" .. name .. "NameA"] = { fg = col, bg = b(col, bg, na), bold = true }
    end
    return g
end

-- Self-theme the history-pager groups at module load (not just in setup) so they exist
-- after a plain require(); bind() applies them with `default = true` and re-applies on
-- palette change and on ColorScheme.
pcall(function()
    hl.bind(M.msg_highlights)
end)

--- Initialise the notify hub: merge `user_cfg` into the live `config.notify` IN PLACE, build the
--- printer list, intercept vim.notify (once), and — when configured — override print / attach the
--- ext_messages UI. Safe to call directly (`require("lvim-hud.notify").setup({...})`) or via the
--- top-level `require("lvim-hud").setup({ notify = {...} })`.
---@param user_cfg? table  notify config overrides (merged into config.notify)
function M.setup(user_cfg)
    user_cfg = user_cfg or {}
    merge(_cfg, user_cfg)

    -- LvimNotify* groups are self-themed centrally via highlight.bind (config factory),
    -- so notify no longer re-registers them here.

    -- Build printer list: explicit printers list replaces defaults;
    -- otherwise ensure toast + history are present on first call.
    if user_cfg.printers then
        _printers = {}
        for _, p in ipairs(user_cfg.printers) do
            if p == "toast" then
                M.add_printer("toast", _show_toast)
            elseif p == "history" then
                M.add_printer("history", _append_history)
            elseif type(p) == "function" then
                M.add_printer(tostring(p), p)
            elseif type(p) == "table" and p.fn then
                M.add_printer(p.name or tostring(p), p.fn)
            end
        end
        if not M.has_printer("history") then
            M.add_printer("history", _append_history)
        end
    elseif not _initialized then
        M.add_printer("toast", _show_toast)
        M.add_printer("history", _append_history)
    end

    -- Intercept vim.notify on first setup.
    if not _initialized then
        vim.notify = function(msg, level, opts)
            _dispatch(msg, level, opts)
        end ---@diagnostic disable-line: duplicate-set-field
    end

    if _cfg.override_print then
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                table.insert(parts, tostring(select(i, ...)))
            end
            _dispatch(table.concat(parts, "\t"), levels.DEBUG, { title = "print" })
        end
    end

    if _cfg.ext_messages then
        _attach_ui()
    end

    -- Register `:LvimMessages` so setup() gives it (like the other plugins' :Lvim* commands) — it browses the
    -- captured notification / message log (in the msgarea zone when installed, else the cmdline pager).
    pcall(vim.api.nvim_create_user_command, "LvimMessages", function()
        M.history()
    end, { desc = "lvim-hud: browse captured notifications / messages" })

    _initialized = true
end

return M
