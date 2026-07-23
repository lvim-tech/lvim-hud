-- lvim-hud.cmdline: self-rendered command-line. Externalises the cmdline via vim.ui_attach({ ext_cmdline })
-- and draws it in an owned float + buffer, the way ui.nvim / noice do. Owning the buffer
-- lets us reserve real cells for a padded, coloured icon badge ( <icon> ) followed by the
-- command text on a tinted background — which decorating the built-in cmdline cannot do
-- (ephemeral inline virt_text is broken: neovim/neovim#24797).
--
---@module "lvim-hud.cmdline"

local colors = require("lvim-utils.colors")
local status = require("lvim-hud.chrome.overlay")
local M = {}

local api = vim.api
local _ns = api.nvim_create_namespace("lvim_utils_cmdline")
local _msg_keyns = api.nvim_create_namespace("lvim_utils_cmdline_msg")
local _pager_ns = api.nvim_create_namespace("lvim_utils_cmdline_pager")
local _active_ns = api.nvim_create_namespace("lvim_utils_cmdline_pager_active")
local _buf ---@type integer?
local _win ---@type integer?
local _cfg ---@type table
local _blink ---@type uv.uv_timer_t?
local _msg_timer ---@type uv.uv_timer_t?
local _cursor_on = true
local _active = false
---@type LvimChromeOverlayState?  the statusline owner (e.g. an open finder) snapshotted when the cmdline opens OVER
--- it, put back on close so its title/counter survive instead of being cleared.
local _saved_status = nil
---@type boolean  true while THIS cmdline owns the statusline overlay (snapshotted it on open) and must restore
--- it on close. A routed MESSAGE dismissal shares `close()` but never snapshotted — it must NOT touch the line.
local _owns_status = false
---@type boolean  true while the cmdline is HOSTED in the msgarea zone (its render reserved rows). A routed
--- message never reserves rows, so `close()` must not run the zone reflow (`done()`) for one.
local _hosted = false
---@type integer  bumped on every cmdline_show; a nested-level hide's scheduled teardown bails once a newer
--- show has arrived (the outer cmdline re-armed), so tearing down the nested float never kills the outer one.
local _show_seq = 0

---@type string?  the last routed message shown in the float (for a VimResized re-layout of a sticky message)
local _last_message = nil
---@type fun(msg: string)  forward decl: the routed-message layout (defined below M.input), referenced by the
--- VimResized autocmd in M.setup above its definition — so it must be a module local in scope there.
local render_message

---@type { content: table[], pos: integer, firstc: string, prompt: string, level: integer, block: table[], special: string? }
local state = { content = {}, pos = 0, firstc = ":", prompt = "", level = 1, block = {}, special = nil }

--- The unified-minibuffer host provider (the msgarea zone). The edge is INVERTED — the cmdline never requires
--- msgarea; msgarea registers this in its setup. `host(height)` reserves `height` rows at the bottom of the
--- zone and returns a table carrying at least `width` (or nil when the zone is off); `done()` releases them.
---@class LvimCmdlineHostProvider
---@field host fun(height: integer): table|nil  reserve `height` rows in the zone; nil when the zone is off
---@field done fun()  release the reserved rows and reflow the zone (window work — scheduled)
---@field clear? fun()  drop the reserved ROWS only, no window work — safe in the ui-event fast context

--- The registered host provider, or nil when no zone hosts the cmdline (it then anchors to the editor bottom).
---@type LvimCmdlineHostProvider?
local _host_provider = nil

--- Register the cmdline's unified-minibuffer host provider (the msgarea zone). Called by lvim-msgarea
--- in its setup; keeps the cmdline free of any msgarea dependency.
---@param provider LvimCmdlineHostProvider
function M.set_host_provider(provider)
    _host_provider = provider
end

--- Highlight groups: base = text area (light tint), <base>Icon = badge (stronger tint).
---@return table<string, table>
local function build()
    local c = colors
    local b, bg = c.blend, c.bg
    local g = {}
    local function pair(name, col)
        g[name] = { fg = col, bg = b(col, bg, 0.1) }
        g[name .. "Icon"] = { fg = col, bg = b(col, bg, 0.2), bold = true }
        -- BLOCK cursor: the caret is a highlight ON the char under it (not a glyph), so fill the cell with the
        -- mode colour and draw the char in the editor bg — reverse-style, the char stays readable.
        g[name .. "Caret"] = { fg = bg, bg = col }
    end
    pair("LvimUiCmdlineCommand", c.blue)
    pair("LvimUiCmdlineSearch", c.green)
    pair("LvimUiCmdlineEval", c.red)
    pair("LvimUiCmdlineLua", c.purple)
    pair("LvimUiCmdlineInput", c.cyan)
    pair("LvimUiCmdlineShell", c.orange)
    pair("LvimUiCmdlineSubstitute", c.cyan)
    pair("LvimUiCmdlineSet", c.yellow)
    -- Pager (:Messages) chrome.
    g.LvimUiCmdlinePagerBorder = { fg = c.blue }
    g.LvimUiCmdlinePagerCursor = { bg = c.bg_highlight }
    g.LvimUiCmdlinePagerKey = { fg = c.blue, bold = true }
    g.LvimUiCmdlinePagerLabel = { fg = c.comment }
    -- Per-level message groups (history-pager rows) are owned by the notify module
    -- (single source of truth); merge them in so the cmdline pager shares them.
    local nm_ok, nm = pcall(require, "lvim-hud.notify")
    if nm_ok and nm.msg_highlights then
        for k, v in pairs(nm.msg_highlights()) do
            g[k] = v
        end
    end
    return g
end

---@return integer
local function ensure_buf()
    if not (_buf and api.nvim_buf_is_valid(_buf)) then
        _buf = api.nvim_create_buf(false, true)
    end
    return _buf
end

--- Concatenate a content array ({ { attr, text }, ... }) to a plain string.
---@param content table[]
---@return string
local function flatten(content)
    local s = ""
    for _, chunk in ipairs(content or {}) do
        s = s .. (chunk[2] or "")
    end
    return s
end

local function stop_blink()
    if _blink then
        _blink:stop()
        _blink:close()
        _blink = nil
    end
end

local function close()
    _active = false
    _last_message = nil
    -- Restore the statusline overlay ONLY when THIS cmdline snapshotted it (a real cmdline open). A routed
    -- message dismissal also calls close() but never owned the line — restoring here would run
    -- overlay.restore(nil) → clear() and wipe whatever a still-open finder published to the bottom line.
    if _owns_status then
        status.restore(_saved_status) -- put the prior owner's status (the finder) back, or clear if none
        _saved_status = nil
        _owns_status = false
    end
    stop_blink()
    if _msg_timer then
        _msg_timer:stop()
        _msg_timer:close()
        _msg_timer = nil
    end
    vim.on_key(nil, _msg_keyns)
    if _win and api.nvim_win_is_valid(_win) then
        pcall(api.nvim_win_close, _win, true)
    end
    _win = nil
    state.block, state.special = {}, nil
    vim.g.ui_cmdline_pos = nil -- drop the completion-menu anchor (blink falls back to its default)
    -- Release the unified msgarea reservation — ONLY when this cmdline actually hosted rows there. A routed
    -- message never reserved any, so it must not trigger a zone reflow (`done()`) on dismiss.
    if _hosted and _host_provider and _host_provider.done then
        _host_provider.done()
    end
    _hosted = false
end

--- Draw the current cmdline (and any :g/:'<,'> block) into the float.
local function render()
    if not _active then
        return
    end
    -- input() prompts report an empty firstc; treat them as the "@" (input) mode.
    local ct = (state.firstc ~= "" and state.firstc) or "@"
    local mode = _cfg.modes[ct] or _cfg.fallback
    -- Content sub-modes for ":" commands (lua / expr / shell / substitute / set).
    if ct == ":" then
        local cmd_text = flatten(state.content)
        for _, p in ipairs(_cfg.patterns or {}) do
            if cmd_text:match(p.match) then
                mode = p
                break
            end
        end
    end
    local prompt = state.prompt or ""
    -- Left panel = icon + a label. For the input mode the live prompt ("New name: ")
    -- wins; otherwise the per-mode static label ("Command", "Search ↓", …).
    local label = (prompt ~= "" and prompt) or (mode.label or "")
    local badge
    -- Publish to the statusline only when the global echo model is on (config.chrome.overlay.enabled) AND this
    -- cmdline opts in (cmdline.statusline). Either off ⇒ the float keeps its own mode badge.
    local to_statusline = status.is_enabled() and _cfg.statusline ~= false
    if to_statusline then
        -- For a SEARCH (`/` `?`), compute the live match statistics for the typed pattern (current/total,
        -- like Emacs/hlslens) and publish them as the counter — recomputed each keystroke. Empty pattern or
        -- an invalid in-progress regex ⇒ 0 (the counter hides). nil for non-search so the `:` completion
        -- counter (published by msgarea) is left untouched.
        local typed = flatten(state.content)
        local cur, total
        if state.firstc == "/" or state.firstc == "?" then
            -- live search match statistics (current/total) for the typed pattern. (For `:`, the counter is
            -- the completion result count — published by the completion integration (native / blink) via
            -- msgarea, which has a real selection; computing it here too would fight that, flicking the
            -- counter between e.g. `1/2` and `2`.)
            if typed ~= "" then
                -- Bounded: `maxcount = 0` counts EVERY match of the in-progress pattern per keystroke (a whole
                -- multi-MB buffer scan on a cheap intermediate pattern). Cap it (999 ⇒ sc.total saturates) and
                -- time-box it (100 ms) so a live `/`/`?` counter never stalls typing.
                local ok, sc =
                    pcall(vim.fn.searchcount, { pattern = typed, recompute = 1, maxcount = 999, timeout = 100 })
                cur = (ok and sc and sc.current) or 0
                total = (ok and sc and sc.total) or 0
            else
                cur, total = 0, 0
            end
        end
        -- Statusline integration: the mode ICON + LABEL move UP to the bottom line (like the navigator), so
        -- the float shows ONLY the input. Also publish the STRING being entered (the search pattern / the
        -- command) as the action, so `:`/`/`/`?` all show what is typed. The counter is the search count for
        -- a search, else nil (msgarea sets the `:` completion count). An input() prompt stays in the float.
        status.set({
            title = label ~= "" and label:gsub("%s+$", "") or nil,
            title_hl = mode.hl,
            icon = mode.glyph,
            icon_hl = mode.hl .. "Icon", -- the float badge's own per-mode colour, so the line mirrors it
            action = prompt == "" and typed or "", -- the typed string (not for an input() prompt)
            current = cur,
            total = total,
        })
        badge = (prompt ~= "" and (" " .. prompt:gsub("%s+$", "") .. " ")) or ""
    else
        -- The mode badge in the float: configurable spaces left of / right of the glyph (`badge_pad_left/
        -- right`). A trailing gap on the label keeps the input text off the box edge.
        local lpad = string.rep(" ", _cfg.badge_pad_left or 2)
        local rpad = string.rep(" ", _cfg.badge_pad_right or 2)
        if label ~= "" then
            label = label:gsub("%s+$", "") .. "  "
        end
        badge = lpad .. mode.glyph .. rpad .. label
    end
    local badge_w = vim.fn.strdisplaywidth(badge)
    -- One extra cell after the panel so the input text is not glued to the box (>= 1 when there is no badge).
    local pad = string.rep(" ", math.max(badge_w + 1, 1))

    -- Command text; may contain newlines (multi-line paste, or <C-CR>). Split it so the
    -- format is preserved — each source line becomes its own buffer line.
    local text = flatten(state.content)
    -- Hide a sub-mode keyword (lua / ! / = / set …); it is shown by the panel label.
    local strip_len = 0
    if mode.strip then
        local pre = text:match(mode.strip)
        if pre then
            text = text:sub(#pre + 1)
            strip_len = #pre
        end
    end
    local pos = math.max(0, state.pos - strip_len)
    if state.special then
        text = text:sub(1, pos) .. state.special .. text:sub(pos + 1)
    end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local sublines = vim.split(text, "\n", { plain = true })

    -- Map the byte cursor position onto (subline, column within it).
    local cpos = pos + (state.special and #state.special or 0)
    local cur_sub, cur_col = #sublines, #sublines[#sublines]
    do
        local p = cpos
        for i, sl in ipairs(sublines) do
            if p <= #sl then
                cur_sub, cur_col = i, p
                break
            end
            p = p - (#sl + 1)
        end
    end

    -- Build buffer lines: :g/:'<,'> block lines, then the (possibly multi-line) prompt.
    local lines = {}
    for _, bline in ipairs(state.block) do
        lines[#lines + 1] = pad .. flatten(bline)
    end
    local cmd_row = #lines
    lines[#lines + 1] = pad .. sublines[1]
    for i = 2, #sublines do
        lines[#lines + 1] = pad .. sublines[i]
    end
    lines[#lines] = lines[#lines] .. " "

    local buf = ensure_buf()
    -- This render can be reached from a `setcmdline()`-triggered CmdlineChanged (e.g. accepting a completion
    -- in the zone), which fires under TEXTLOCK — buffer changes are then forbidden (E565). Detect that via
    -- the first write and retry on the next tick (outside textlock) instead of erroring.
    if not pcall(api.nvim_buf_set_lines, buf, 0, -1, false, lines) then
        vim.schedule(render)
        return
    end
    api.nvim_buf_clear_namespace(buf, _ns, 0, -1)

    -- Left panel (icon + prompt label) overlaying the reserved leading cells.
    api.nvim_buf_set_extmark(buf, _ns, cmd_row, 0, {
        virt_text = { { badge, mode.hl .. "Icon" } },
        virt_text_pos = "overlay",
    })

    -- Extend the panel background down the left gutter of every row.
    for r = 0, #lines - 1 do
        api.nvim_buf_set_extmark(buf, _ns, r, 0, {
            end_col = math.min(badge_w, #(lines[r + 1] or "")),
            hl_group = mode.hl .. "Icon",
        })
    end

    -- BLOCK caret. A terminal grid can't place a thin bar BETWEEN cells (overlay HIDES the next char, inline
    -- SHIFTS it, an empty inline placeholder leaves a visible gap) and, externalised, there is no hardware cursor
    -- to borrow — so the caret is a HIGHLIGHT on the cell UNDER it (the char to the right of the insertion point):
    -- the standard terminal block cursor. It changes NO text — no shift, no width change, no wrap change; the char
    -- stays readable (the `<mode.hl>Caret` group is reverse / distinct fg+bg); the blink just adds/removes the
    -- highlight. The last buffer line carries a trailing space (built above) so the end-of-command position also
    -- has a cell to colour.
    if _cursor_on then
        local crow = cmd_row + cur_sub - 1
        -- The caret's byte column = the gutter (`pad`, which the buffer lines were built with) + the cursor's
        -- offset into the sub-line. Use `#pad` directly rather than re-deriving `badge_w + 1`, so the caret can
        -- never drift from the pad the lines actually carry (the two must stay identical).
        local cline = lines[crow + 1] or ""
        local ccol = math.min(#pad + cur_col, #cline)
        -- Highlight ONE utf-8 codepoint (read the lead byte for its length) so a multibyte glyph under the cursor
        -- is coloured WHOLE, never cut mid-sequence.
        local lead = cline:byte(ccol + 1)
        local clen = 1
        if lead then
            if lead >= 0xF0 then
                clen = 4
            elseif lead >= 0xE0 then
                clen = 3
            elseif lead >= 0xC0 then
                clen = 2
            end
        end
        if ccol < #cline then
            api.nvim_buf_set_extmark(buf, _ns, crow, ccol, {
                end_col = math.min(ccol + clen, #cline),
                hl_group = mode.hl .. "Caret",
                hl_mode = "replace",
                priority = 300,
            })
        end
    end

    -- Grow vertically: each (block + prompt) line wraps at the window width, so the height is the sum of wrapped
    -- rows, capped so the float never covers the screen. The block caret is a highlight (adds no width).
    local width = vim.o.columns
    local height = 0
    for _, l in ipairs(lines) do
        height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
    end
    height = math.max(1, math.min(height, _cfg.max_height or math.floor(vim.o.lines * 0.5)))

    -- Unified minibuffer: when the msgarea zone hosts the cmdline, anchor the float to the BOTTOM of
    -- that panel (over its reserved rows) instead of the editor bottom — identical content, relocated.
    local host
    if _host_provider and _host_provider.host then
        host = _host_provider.host(height)
    end
    _hosted = host ~= nil -- whether we reserved zone rows this render (close() reflows only when true)
    -- Hosted: pin to the ABSOLUTE bottom of the screen, NOT to a bufpos inside the zone. The zone always
    -- sits flush with the screen bottom (its grid grows UPWARD), so the cmdline's bottom `height` rows are
    -- invariant — anchoring to the editor bottom keeps it put when the grid resizes, instead of riding a
    -- bufpos that shifts down (and snapping back a frame later) as completion rows appear above it.
    local win_config = host
            and {
                relative = "editor",
                row = math.max(0, vim.o.lines - height),
                col = 0,
                width = host.width,
                height = height,
                style = "minimal",
                zindex = 300,
                border = "none",
                focusable = false,
            }
        or {
            relative = "editor",
            style = "minimal",
            zindex = 300,
            row = math.max(0, vim.o.lines - vim.o.cmdheight - height - (_cfg.row_offset or 0)),
            col = 0,
            width = width,
            height = height,
            border = "none",
            focusable = false,
        }
    local opened = not (_win and api.nvim_win_is_valid(_win))
    if opened then
        _win = api.nvim_open_win(buf, false, win_config)
    else
        api.nvim_win_set_config(_win, win_config)
    end
    api.nvim_set_option_value("winhighlight", "Normal:" .. mode.hl .. ",Search:None,CurSearch:None", { win = _win })
    api.nvim_set_option_value("wrap", true, { win = _win })

    -- Publish the cmdline's screen position so a completion engine (blink.cmp) anchors its menu just
    -- ABOVE the actual command line — wherever it is (the editor bottom, or inside the msgarea zone in
    -- unified mode) — instead of falling back to a fixed editor-bottom popup. `{ row, col }`, 0-based.
    local ok_pos, pos = pcall(api.nvim_win_get_position, _win)
    if ok_pos then
        vim.g.ui_cmdline_pos = { pos[1], pos[2] }
    end

    -- Force an immediate redraw: the initial firstc frame (and the blink toggle on an otherwise-idle screen)
    -- would appear a keystroke late without it. This is safe for a PASTE now — `schedule_render()` coalesces the
    -- per-character burst into ONE render, so this flush runs once per burst, not per character.
    pcall(api.nvim__redraw, { flush = true })
end

--- Start the cursor blink timer (re-renders, toggling the block cursor).
local function start_blink()
    if _blink then
        return
    end
    _blink = vim.uv.new_timer()
    if not _blink then
        return
    end
    _blink:start(
        500,
        500,
        vim.schedule_wrap(function()
            if not (_win and api.nvim_win_is_valid(_win)) then
                stop_blink()
                return
            end
            _cursor_on = not _cursor_on
            render()
        end)
    )
end

---@param fn fun()
local function schedule(fn)
    if vim.in_fast_event() then
        vim.schedule(fn)
    else
        fn()
    end
end

---@type boolean  a render is already queued for this frame — coalesce the burst of cmdline_show/pos events a
--- PASTE fires (one per character) into a SINGLE render of the final state. Without this each character forced
--- its own `nvim__redraw({flush})` (render's tail), so a long paste crawled in visibly, character by character.
--- `render()` reads the LIVE `state`, so the one queued render always draws the latest content.
local _render_queued = false

--- Queue a coalesced render + (idempotent) blink start. ALWAYS defers via `vim.schedule` (never the conditional
--- `schedule()` helper): `CmdlineChanged` fires in a NON-fast context, where `schedule()` would run `render()`
--- synchronously and clear the flag before the next character — so the burst never coalesced and every pasted
--- character forced its own full render + `nvim__redraw({flush})`. Deferring unconditionally lets a whole
--- paste's events queue behind ONE render of the final `state`.
local function schedule_render()
    if _render_queued then
        return
    end
    _render_queued = true
    vim.schedule(function()
        _render_queued = false
        render()
        start_blink()
    end)
end

--- Enable the self-rendered cmdline (ext_cmdline) + register highlights.
---@param cfg table  the merged lvim-hud.config.cmdline
---@return nil
function M.setup(cfg)
    cfg = cfg or {}
    _cfg = cfg
    if not cfg.enable then
        return
    end

    -- Self-theme the cmdline groups: bind() applies build() with `default = true` and
    -- re-applies on palette/ColorScheme change (overwritable, like the rest of the UI).
    local hl_ok, hl = pcall(require, "lvim-utils.highlight")
    if hl_ok then
        hl.bind(build)
    end

    -- Authoritative content refresh: cmdline_show does not always carry the result of
    -- `<C-r>` register insertion, so re-read the real command line on every change.
    local cmdline_group = api.nvim_create_augroup("LvimUiCmdline", { clear = true })
    api.nvim_create_autocmd("CmdlineChanged", {
        group = cmdline_group,
        callback = function()
            state.content = { { 0, vim.fn.getcmdline() } }
            state.pos = vim.fn.getcmdpos() - 1
            state.special = nil
            _cursor_on = true
            schedule_render() -- coalesced: a paste fires CmdlineChanged (and cmdline_show) per character
        end,
    })
    -- Re-render on resize: the float spans the full width and sits at the bottom (both from
    -- `vim.o.columns`/`vim.o.lines`), so a resize while the cmdline is open must reflow it. Render
    -- SYNCHRONOUSLY (VimResized is never a fast event) so the float follows the new size in the SAME frame —
    -- no stale-geometry frame between the resize and the reflow.
    api.nvim_create_autocmd("VimResized", {
        group = cmdline_group,
        callback = function()
            if not (_win and api.nvim_win_is_valid(_win)) then
                return
            end
            if _active then
                render()
            elseif _last_message then
                -- A persistent routed message is showing (render() early-returns on `not _active`): re-anchor
                -- it from the stored text so a shrink does not leave it mid-screen / clipped.
                render_message(_last_message)
            end
        end,
    })

    -- One-time side effects, once-latched behind M._ready: a repeated setup() must NOT stack a second
    -- vim.ui_attach handler (each with a fresh namespace ⇒ the cmdline double-renders), re-map the newline
    -- keys, or re-register the "cmdline" sink. Mirrors notify's _ui_attached latch. (The autocmds above use a
    -- clear=true augroup, so they stay idempotent outside this latch.)
    if not M._ready then
        M._ready = true

        -- Cmdline-mode keys that insert a literal newline for multi-line command input.
        for _, key in ipairs(cfg.newline_keys or {}) do
            vim.keymap.set("c", key, "<C-v><C-j>", { desc = "lvim-hud cmdline: newline" })
        end

        -- Keep the cmdline OPEN when <BS> is pressed on an EMPTY line. Neovim's default ABORTS the cmdline there
        -- (a surprising exit while deleting back through a command); instead make it a no-op — the cmdline stays,
        -- and with any text <BS> deletes as usual. Esc / <C-c> still abort. Gated on `keep_open_on_empty_bs`
        -- (default true). `<C-h>` mirrors <BS> the same way.
        if cfg.keep_open_on_empty_bs ~= false then
            for _, key in ipairs({ "<BS>", "<C-h>" }) do
                vim.keymap.set("c", key, function()
                    return vim.fn.getcmdline() == "" and "" or key
                end, { expr = true, desc = "lvim-hud cmdline: keep open on empty backspace" })
            end
        end

        -- Expose a notify "cmdline" printer: host maps message kinds to it via
        -- notify.ext_kinds (e.g. lua_print = "cmdline") to show them in the cmdline float.
        if not cfg.message or cfg.message.enable ~= false then
            local nm_ok, nm = pcall(require, "lvim-hud.notify")
            if nm_ok and nm.register_sink then
                nm.register_sink("cmdline", function(text)
                    M.message(text)
                end)
            end
        end

        local ui_ns = api.nvim_create_namespace("lvim_utils_cmdline_ui")
        vim.ui_attach(ui_ns, { ext_cmdline = true }, function(event, ...)
            local a = { ... }
            if event == "cmdline_show" then
                -- Neovim RE-EMITS cmdline_show after any forced screen redraw — including the flush at the
                -- tail of our own render() and every incsearch repaint during a `/`/`?` search — carrying the
                -- SAME content we are already showing. Acting on such a spurious show (resetting the blink
                -- cursor to on + scheduling a render whose redraw re-emits yet another show) is the feedback
                -- loop behind the search flicker AND the blink stutter. Ignore a show that changes nothing;
                -- only a real content / cursor / mode / prompt / level change falls through and renders.
                if
                    _active
                    and flatten(a[1] or {}) == flatten(state.content)
                    and (a[2] or 0) == state.pos
                    and (a[3] or ":") == state.firstc
                    and (a[4] or "") == state.prompt
                    and (a[6] or 1) == state.level
                then
                    return
                end
                -- Every real show (incl. the outer level re-arriving after a nested prompt closes) bumps the
                -- generation, so a nested hide's scheduled teardown can tell it has been superseded.
                _show_seq = _show_seq + 1
                if not _active then
                    -- Opening OVER whatever owns the statusline (e.g. an active finder hosted in the zone
                    -- below): snapshot it so close() restores its title/counter instead of clearing the line.
                    local owns = (_cfg and status.is_enabled() and _cfg.statusline ~= false) and true or false
                    _saved_status = owns and status.save() or nil
                    _owns_status = owns
                end
                _active = true
                state.content = a[1] or {}
                state.pos = a[2] or 0
                state.firstc = a[3] or ":"
                state.prompt = a[4] or ""
                state.level = a[6] or 1
                state.special = nil
                _cursor_on = true
                schedule_render()
            elseif event == "cmdline_pos" then
                state.pos = a[1] or 0
                state.special = nil
                _cursor_on = true
                schedule_render()
            elseif event == "cmdline_special_char" then
                state.special = a[1]
                schedule_render()
            elseif event == "cmdline_hide" then
                local level = a[1] or 1
                -- Give the zone back our ROWS immediately (data only — no window API, so it is safe here). The
                -- typed command runs SYNCHRONOUSLY, before the scheduled `close` below: a command that opens a
                -- docked panel would otherwise reserve its rows on top of ours, and the zone would compose the
                -- SUM for one frame — the panel visibly opening too tall and then shrinking. Skip it for a
                -- NESTED hide (level > 1): the outer cmdline still owns its rows. The real teardown (closing the
                -- float, reflowing) stays scheduled: it touches windows.
                if level <= 1 and _host_provider and _host_provider.clear then
                    pcall(_host_provider.clear)
                end
                -- Generation-guard the teardown: a nested (`<C-r>=`) hide is immediately followed by the outer
                -- level's cmdline_show, which bumps _show_seq. Capture it now; the scheduled close bails when a
                -- newer show has re-armed the cmdline — so closing the nested float never kills the restored
                -- level-1 float (which would leave the live cmdline invisible).
                local seq = _show_seq
                schedule(function()
                    if seq ~= _show_seq then
                        return
                    end
                    close()
                end)
            elseif event == "cmdline_block_show" then
                state.block = a[1] or {}
                schedule(render)
            elseif event == "cmdline_block_append" then
                state.block[#state.block + 1] = a[1]
                schedule(render)
            elseif event == "cmdline_block_hide" then
                state.block = {}
                schedule(render)
            end
        end)

        -- We draw our OWN cursor in the cmdline float, so hide the redundant hardware cursor in the buffer
        -- while the command-line is active (like the native cmdline). Driven by lvim-utils.cursor.
        pcall(function()
            require("lvim-utils.cursor").set_cmdline_hide(true)
        end)
    end
end

--- vim.ui.input-style prompt rendered in the command-line (via native input(), which
--- flows through this module's ext_cmdline handler). Blocking, like the real cmdline.
---@param opts { prompt?: string, default?: string, completion?: string }
---@param on_confirm fun(input: string?)
---@return nil
function M.input(opts, on_confirm)
    opts = opts or {}
    local function run()
        local sentinel = "\27lvim_cmdline_cancel\27"
        local ok, res = pcall(vim.fn.input, {
            prompt = opts.prompt or "",
            default = opts.default or "",
            completion = opts.completion,
            cancelreturn = sentinel,
        })
        if (not ok) or res == sentinel then
            on_confirm(nil)
        else
            on_confirm(res)
        end
    end
    if vim.in_fast_event() then
        vim.schedule(run)
    else
        run()
    end
end

--- Lay out `msg` in the shared float — buffer lines + the icon badge + window placement, all from the CURRENT
--- `vim.o.columns`/`vim.o.lines`. Pure rendering (no dismiss-key / timer setup), so a VimResized can re-run it
--- to re-anchor a persistent message at the new size.
---@param msg string
function render_message(msg)
    local m = (_cfg and _cfg.message) or {}
    local hl = m.hl or "LvimUiCmdlineInput"
    local badge = string.rep(" ", _cfg.badge_pad_left or 2)
        .. (m.glyph or "")
        .. string.rep(" ", _cfg.badge_pad_right or 2)
    local badge_w = vim.fn.strdisplaywidth(badge)
    local pad = string.rep(" ", badge_w + 1)

    local lines = {}
    for _, l in ipairs(vim.split(msg:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })) do
        lines[#lines + 1] = pad .. l
    end

    local buf = ensure_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(buf, _ns, 0, -1)
    api.nvim_buf_set_extmark(buf, _ns, 0, 0, {
        virt_text = { { badge, hl .. "Icon" } },
        virt_text_pos = "overlay",
    })
    for r = 0, #lines - 1 do
        api.nvim_buf_set_extmark(buf, _ns, r, 0, {
            end_col = math.min(badge_w, #(lines[r + 1] or "")),
            hl_group = hl .. "Icon",
        })
    end

    local width = vim.o.columns
    local height = 0
    for _, l in ipairs(lines) do
        height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
    end
    height = math.max(1, math.min(height, _cfg.max_height or math.floor(vim.o.lines * 0.5)))
    local win_config = {
        relative = "editor",
        style = "minimal",
        zindex = 300,
        row = math.max(0, vim.o.lines - vim.o.cmdheight - height - (_cfg.row_offset or 0)),
        col = 0,
        width = width,
        height = height,
        border = "none",
        focusable = false,
    }
    if _win and api.nvim_win_is_valid(_win) then
        api.nvim_win_set_config(_win, win_config)
    else
        _win = api.nvim_open_win(buf, false, win_config)
    end
    api.nvim_set_option_value("winhighlight", "Normal:" .. hl .. ",Search:None,CurSearch:None", { win = _win })
    api.nvim_set_option_value("wrap", true, { win = _win })
    pcall(api.nvim__redraw, { flush = true })
end

--- Show a message in the cmdline float (notify "cmdline" sink target). Cleared with
--- <Esc>; auto-hides only when `message.timeout` > 0 (else it persists). Skipped while
--- a real cmdline is active.
---@param msg string
---@return nil
function M.message(msg)
    local m = (_cfg and _cfg.message) or {}
    msg = tostring(msg or "")
    if msg == "" or _active then
        return
    end
    _last_message = msg -- remembered so a VimResized can re-anchor a persistent (timeout 0) message
    render_message(msg)

    -- Dismiss keys (config message.dismiss_keys; Vim notation, "esc" accepted). Observed
    -- via `typed` (raw key before mapping) so they work even when the key is remapped.
    local dismiss = {}
    for _, k in ipairs(m.dismiss_keys or { "<Esc>" }) do
        local spec = (tostring(k):lower() == "esc") and "<Esc>" or k
        dismiss[api.nvim_replace_termcodes(spec, true, false, true)] = true
    end
    vim.on_key(function(key, typed)
        if dismiss[typed or "\0"] or dismiss[key or "\0"] then
            vim.schedule(function()
                if not _active then
                    close()
                end
            end)
        end
    end, _msg_keyns)

    -- Auto-hide only when a positive timeout is configured; otherwise persist until <Esc>.
    if _msg_timer then
        _msg_timer:stop()
        _msg_timer:close()
        _msg_timer = nil
    end
    local timeout = tonumber(m.timeout) or 0
    if timeout > 0 then
        _msg_timer = vim.uv.new_timer()
        if _msg_timer then
            -- REPEATING (not one-shot): if a real cmdline is active when the deadline fires, the shared float
            -- is owned by it — closing now would break the live cmdline (and the expired message, plus its
            -- dismiss on_key handler, would otherwise stay stuck). We skip and re-check next tick; once the
            -- cmdline is gone a tick closes us. close() stops this timer, so a normal dismiss ends it at once.
            _msg_timer:start(
                timeout,
                timeout,
                vim.schedule_wrap(function()
                    if not _active then
                        close()
                    end
                end)
            )
        end
    end
end

local _pager_prev ---@type integer?
local _pager_guicursor ---@type string?
---@type fun()?  closes the currently-open pager (set while one is open); called to tear a previous pager down
--- before opening a new one, so a second M.pager never cross-closes the new pager's windows.
local _pager_close = nil

--- Focusable pager in a bottom float (cmdline-area), used by :Messages. The caller fills
--- the buffer via opts.on_open(buf); opts.keymaps (key → {fn,label}) become buffer-local
--- maps + footer buttons. Filter/refresh/quit work because the float is focused.
---@param opts { title?: string, keymaps?: table<string, { fn: function, label?: string, badge?: string, label_hl?: string }>, order?: string[], level_at?: function, on_open?: function }
---@return nil
function M.pager(opts)
    opts = opts or {}
    if _pager_close then
        _pager_close() -- a pager is already open: tear it down before opening a new one
    end
    _pager_prev = api.nvim_get_current_win()
    local buf = api.nvim_create_buf(false, true)
    if opts.on_open then
        pcall(opts.on_open, buf)
    end

    -- Title (left) + buttons (right), badge style; buttons collapse to just the key
    -- badges when the width is too small to fit their labels. The title TEXT is uppercased through the
    -- canonical lvim-ui casing (the icon box padding stays — it aligns with the history rows' icon column).
    local icon = (_cfg and _cfg.message and _cfg.message.glyph) or ""
    local title_text = vim.trim(opts.title or "Messages")
    local tc_ok, ui_util = pcall(require, "lvim-ui.util")
    if tc_ok and ui_util.title_case then
        title_text = ui_util.title_case(title_text)
    end
    local title = {
        { "  " .. icon .. "  ", "LvimUiCmdlineCommandIcon" },
        { " " .. title_text, "LvimUiCmdlineCommand" },
    }
    local btns = {}
    for key, km in pairs(opts.keymaps or {}) do
        btns[#btns + 1] = { key = key, label = km.label or key, badge = km.badge, label_hl = km.label_hl }
    end
    -- Order by opts.order (preferred sequence), then any remaining keys alphabetically.
    local order = {}
    for i, k in ipairs(opts.order or {}) do
        order[k] = i
    end
    table.sort(btns, function(a, b)
        local oa, ob = order[a.key] or 50, order[b.key] or 50
        if oa ~= ob then
            return oa < ob
        end
        return a.key < b.key
    end)
    btns[#btns + 1] = { key = "q", label = "close" }
    local buttons_full, buttons_compact = {}, {}
    for _, b in ipairs(btns) do
        local badge = b.badge or "LvimUiCmdlineCommandIcon"
        local lhl = b.label_hl or "LvimUiCmdlineCommand"
        buttons_full[#buttons_full + 1] = { " " .. b.key .. " ", badge }
        buttons_full[#buttons_full + 1] = { " " .. b.label .. " ", lhl }
        buttons_compact[#buttons_compact + 1] = { " " .. b.key .. " ", badge }
        buttons_compact[#buttons_compact + 1] = { " ", lhl }
    end
    local function vw(chunks)
        local n = 0
        for _, c in ipairs(chunks) do
            n = n + vim.fn.strdisplaywidth(c[1])
        end
        return n
    end

    local lc = math.max(1, api.nvim_buf_line_count(buf))
    local height = math.max(1, math.min(lc, math.floor(vim.o.lines * 0.5)))
    local width = vim.o.columns
    local list_row = math.max(1, vim.o.lines - height - vim.o.cmdheight - 1)

    -- List window: focusable (for the keymaps), no cursor/cursorline.
    local lwin = api.nvim_open_win(buf, true, {
        relative = "editor",
        row = list_row,
        col = 0,
        width = width,
        height = height,
        style = "minimal",
        border = "none",
        zindex = 250,
    })
    api.nvim_set_option_value("cursorline", false, { win = lwin })

    -- Header window: a separate non-focusable 1-row float just above the list (lvim-space
    -- main + info pattern), so it stays put while the list filters/refreshes.
    local hbuf = api.nvim_create_buf(false, true)
    local hwin = api.nvim_open_win(hbuf, false, {
        relative = "editor",
        row = math.max(0, list_row - 1),
        col = 0,
        width = width,
        height = 1,
        style = "minimal",
        border = "none",
        zindex = 251,
        focusable = false,
    })
    api.nvim_buf_set_lines(hbuf, 0, -1, false, { string.rep(" ", width) })
    local buttons = (vw(title) + vw(buttons_full) + 2 > width) and buttons_compact or buttons_full
    local pad = math.max(1, width - vw(title) - vw(buttons))
    local hrow = {}
    vim.list_extend(hrow, title)
    -- Tint the gap with the title's text background so the band continues unbroken from
    -- the title across to the buttons.
    hrow[#hrow + 1] = { string.rep(" ", pad), "LvimUiCmdlineCommand" }
    vim.list_extend(hrow, buttons)
    api.nvim_buf_set_extmark(hbuf, _pager_ns, 0, 0, { virt_text = hrow, virt_text_pos = "overlay" })

    -- Recompute the float height + position from the current line count, so filtering down
    -- to fewer (or a single placeholder) rows shrinks the pager, and clearing it grows back.
    local function resize()
        if not (lwin and api.nvim_win_is_valid(lwin)) then
            return
        end
        local w = vim.o.columns -- re-read so a resize uses the CURRENT width, not the stale open-time one
        local n = math.max(1, api.nvim_buf_line_count(buf))
        local h = math.max(1, math.min(n, math.floor(vim.o.lines * 0.5)))
        local row = math.max(1, vim.o.lines - h - vim.o.cmdheight - 1)
        pcall(api.nvim_win_set_config, lwin, { relative = "editor", row = row, col = 0, width = w, height = h })
        if hwin and api.nvim_win_is_valid(hwin) then
            pcall(
                api.nvim_win_set_config,
                hwin,
                { relative = "editor", row = math.max(0, row - 1), col = 0, width = w, height = 1 }
            )
        end
    end

    -- Hide the cursor while the pager is focused; restore on close.
    _pager_guicursor = vim.o.guicursor
    pcall(api.nvim_set_hl, 0, "LvimUiPagerNoCursor", { blend = 100, nocombine = true })
    vim.o.guicursor = "a:LvimUiPagerNoCursor"

    local function close_pager()
        _pager_close = nil
        vim.o.guicursor = _pager_guicursor or vim.o.guicursor
        -- Close THIS call's own windows (closure lwin/hwin), never module-level handles — so a second pager
        -- opened while this one lingers can't cross-close the new windows through this one's WinLeave.
        for _, w in ipairs({ lwin, hwin }) do
            if w and api.nvim_win_is_valid(w) then
                pcall(api.nvim_win_close, w, true)
            end
        end
        -- Delete the two scratch buffers too: closing only the WINDOWS leaves them hidden (bufhidden=hide is
        -- the scratch default) with their <Nop> maps, the CursorMoved autocmd and the on_lines attach — two
        -- leaked buffers per pager run. Deleting them drops the maps + buffer autocmds and detaches on_lines.
        for _, b in ipairs({ buf, hbuf }) do
            if b and api.nvim_buf_is_valid(b) then
                pcall(api.nvim_buf_delete, b, { force = true })
            end
        end
        if _pager_prev and api.nvim_win_is_valid(_pager_prev) then
            pcall(api.nvim_set_current_win, _pager_prev)
        end
    end
    _pager_close = close_pager

    -- Lock the pager down: only the action keys, `q`/<Esc>, and vertical navigation stay
    -- live; every other normal-mode key becomes a no-op so the buffer can't be driven into
    -- edits, search, the cmdline, visual mode or macros.
    do
        local keep = {
            q = true,
            ["<Esc>"] = true,
            -- navigation
            j = true,
            k = true,
            h = true,
            l = true,
            g = true,
            G = true,
            ["<Down>"] = true,
            ["<Up>"] = true,
            ["<Left>"] = true,
            ["<Right>"] = true,
            ["<C-d>"] = true,
            ["<C-u>"] = true,
            ["<C-f>"] = true,
            ["<C-b>"] = true,
            ["<C-e>"] = true,
            ["<C-y>"] = true,
            -- select + copy inside the message list
            v = true,
            V = true,
            ["<C-v>"] = true,
            y = true,
            Y = true,
        }
        for key in pairs(opts.keymaps or {}) do
            keep[key] = true
        end
        local disable = {}
        for c = 33, 126 do
            local ch = string.char(c)
            if ch == "<" then
                ch = "<lt>"
            end
            disable[#disable + 1] = ch
        end
        vim.list_extend(disable, {
            "<Space>",
            "<CR>",
            "<BS>",
            "<Tab>",
            "<Del>",
            "<Insert>",
            "<Left>",
            "<Right>",
            "<Home>",
            "<End>",
            "<PageUp>",
            "<PageDown>",
            "<C-v>",
            "<C-w>",
            "<C-o>",
            "<C-i>",
            "<C-r>",
            "<C-a>",
            "<C-x>",
            "<C-^>",
        })
        for _, key in ipairs(disable) do
            if not keep[key] then
                pcall(vim.keymap.set, "n", key, "<Nop>", { buffer = buf, nowait = true, silent = true })
            end
        end
    end
    for key, km in pairs(opts.keymaps or {}) do
        vim.keymap.set("n", key, km.fn, { buffer = buf, nowait = true, silent = true })
    end
    vim.keymap.set("n", "q", close_pager, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", close_pager, { buffer = buf, nowait = true, silent = true })

    -- Active (focused) row: a stronger tint of its level, following the (hidden) cursor.
    local function mark_active()
        if not (buf and api.nvim_buf_is_valid(buf)) then
            return
        end
        api.nvim_buf_clear_namespace(buf, _active_ns, 0, -1)
        if not (opts.level_at and lwin and api.nvim_win_is_valid(lwin)) then
            return
        end
        local r = api.nvim_win_get_cursor(lwin)[1] - 1
        local lvl = opts.level_at(r)
        if not lvl then
            return
        end
        local cap = lvl:sub(1, 1):upper() .. lvl:sub(2)
        -- Active row as a multiline hl_group range (+hl_eol) to the next line's start, so it
        -- fills the full width (matching the row tint's mechanism) and, at a priority above
        -- the icon badge (100), covers the icon too — the focused row and icon merge.
        api.nvim_buf_set_extmark(buf, _active_ns, r, 0, {
            end_row = r + 1,
            end_col = 0,
            hl_group = "LvimUiMsg" .. cap .. "Active",
            hl_eol = true,
            priority = 200,
        })
    end
    api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = mark_active })
    api.nvim_buf_attach(buf, false, {
        on_lines = function()
            vim.schedule(function()
                resize()
                mark_active()
            end)
        end,
    })
    mark_active()

    api.nvim_create_autocmd("WinLeave", {
        buffer = buf,
        once = true,
        callback = function()
            vim.schedule(close_pager)
        end,
    })
end

return M
