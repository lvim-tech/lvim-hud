-- lvim-hud.chrome.engine: the SHARED segment-rendering engine for every chrome component (statusline,
-- winbar, tabline, statuscolumn). A component supplies a LIST of segment specs; the engine renders them with
-- per-segment caching keyed by each segment's `events` — so a redraw that changed nothing repaints the same
-- string with no recompute (no flicker). The idea is heirline's per-component `update`+cache; the code is ours.
--
-- A component creates its OWN instance via `engine.new{…}` (its own cache, its own forced-redraw command, its
-- own align-fill group) and feeds it the segments + a per-render context. Clickable regions + dynamic
-- highlight groups are shared module-level (ids are globally unique), so `engine.on_click` is the one dispatch.
--
---@module "lvim-hud.chrome.engine"

local api = vim.api

local M = {}

---@class LvimChromeCtx
---@field buf integer
---@field win integer
---@field mode? string    -- the one-char mode (n / i / v / …) — statusline
---@field active? boolean -- is this the component of the ACTIVE window — statusline
---@field lnum? integer   -- the line being drawn (v:lnum) — statuscolumn (per-line)
---@field relnum? integer -- v:relnum — statuscolumn
---@field virtnum? integer -- v:virtnum — statuscolumn

---@class LvimChromeSegment
---@field name? string                                              -- cache key + identity (required to cache)
---@field content? string|fun(ctx: LvimChromeCtx): string?          -- the text (a `%`-code string, or a fn → string/nil)
---@field hl? string|table|fun(ctx: LvimChromeCtx): (string|table)? -- a group name, a { fg, bg, bold, … } spec, or a fn
---@field when? fun(ctx: LvimChromeCtx): boolean                    -- show only when true
---@field events? string[]|"always"                                 -- invalidate the cache on these (a `"User:Pat"` entry → that User pattern); "always" / absent = volatile
---@field click? { run: function, name?: string, _id?: integer }    -- make the segment clickable (_id: internal)
---@field buf? boolean                                              -- also invalidate when the shown buffer changes
---@field align? boolean                                            -- a marker: emit `%=` (everything after floats right)

---@class LvimChromeEngine  -- a component engine instance (its own cache); created by M.new
---@field render fun(segs: LvimChromeSegment[], ctx: LvimChromeCtx): string
---@field invalidate fun(names?: string[])
---@field install_autocmds fun(grp: integer, segs: LvimChromeSegment[])

-- ── dynamic highlight groups (an `hl` TABLE → a group, cached by content so each is registered once) ──────
---@type table<string, string>
local dyn_groups = {}
local dyn_n = 0

---@param hl string|table|function|nil
---@param ctx LvimChromeCtx
---@return string?  a highlight-group name
local function hl_group(hl, ctx)
    if type(hl) == "function" then
        local ok, res = pcall(hl, ctx)
        hl = ok and res or nil
    end
    if hl == nil or hl == "" then
        return nil
    end
    if type(hl) == "string" then
        return hl
    end
    local key = table.concat({
        hl.fg or "",
        hl.bg or "",
        tostring(hl.bold),
        tostring(hl.italic),
        tostring(hl.underline),
        tostring(hl.reverse),
    }, "|")
    local name = dyn_groups[key]
    if not name then
        dyn_n = dyn_n + 1
        name = "LvimUiChromeDyn" .. dyn_n
        pcall(api.nvim_set_hl, 0, name, hl)
        dyn_groups[key] = name
    end
    return name
end

--- Drop the dynamic-group cache (on ColorScheme) so `hl` functions re-register against the new palette.
function M.clear_hl_cache()
    dyn_groups, dyn_n = {}, 0
end

-- ── clickable regions (each `click.run` gets a stable global id; Neovim calls M.on_click with it) ────────
---@type table<integer, function>
local click_runs = {}
local click_n = 0

---@param spec LvimChromeSegment
---@param text string
---@return string
local function click_region(spec, text)
    local c = spec.click
    if not (c and type(c.run) == "function") or text == "" then
        return text
    end
    if not c._id then
        click_n = click_n + 1
        c._id = click_n
    end
    click_runs[c._id] = c.run
    return ("%%%d@v:lua.require'lvim-hud.chrome.engine'.on_click@%s%%X"):format(c._id, text)
end

--- Mouse dispatch for the clickable regions (`%@…@`): run the segment's `click.run` for region `id`.
---@param id integer
function M.on_click(id)
    local run = click_runs[id]
    if run then
        pcall(run)
    end
end

-- offset so PER-CELL click ids (keyed by the caller) never collide with the per-segment auto-ids (small)
local CELL_BASE = 1000000

--- Wrap `text` in a clickable region calling `fn` — for PER-CELL clicks the per-segment `click` can't express
--- (e.g. each WINDOW / TAB cell of the tabline). `key` is a STABLE per-cell number (a window id / a tab index)
--- so the dispatch registry stays bounded across renders.
---@param key integer
---@param fn function
---@param text string
---@return string
function M.click_region(key, fn, text)
    if type(fn) ~= "function" or text == "" then
        return text
    end
    local id = CELL_BASE + key
    click_runs[id] = fn
    return ("%%%d@v:lua.require'lvim-hud.chrome.engine'.on_click@%s%%X"):format(id, text)
end

-- ── build one segment's final string (stateless) ─────────────────────────────────────────────────────────
--- `when` gate → `content` → wrap in `hl` → wrap in the `click` region. A broken `content`/`hl`/`when` is
--- pcall-guarded so one bad custom segment renders "" instead of breaking the whole bar.
---@param spec LvimChromeSegment
---@param ctx LvimChromeCtx
---@return string
local function build(spec, ctx)
    if spec.when then
        local ok, show = pcall(spec.when, ctx)
        if ok and not show then
            return ""
        end
    end
    local text
    local content = spec.content
    if type(content) == "function" then
        local ok, out = pcall(content, ctx)
        text = (ok and out) or ""
    else
        text = content or ""
    end
    if text == nil or text == "" then
        return ""
    end
    local group = hl_group(spec.hl, ctx)
    if group then
        text = ("%%#%s#%s%%*"):format(group, text)
    end
    return click_region(spec, text)
end

--- VOLATILE = rebuilt every render (no `events`, or "always"); else cached until an event / buffer switch.
---@param spec LvimChromeSegment
---@return boolean
local function volatile(spec)
    return spec.events == nil or spec.events == "always"
end

-- ── instance factory ─────────────────────────────────────────────────────────────────────────────────────
--- Create a component engine with its own cache.
---@param opts? { fill?: string|false, volatile?: boolean }  -- align-fill group (default "LvimUiChromeFill", or `false` for a bare `%=`); `volatile` = never cache (rebuild every segment every render — for PER-LINE components like the statuscolumn, where each line's render differs)
---@return LvimChromeEngine
function M.new(opts)
    opts = opts or {}
    -- `align` emits this gap. `fill = false` → a bare `%=` (no group — e.g. the statuscolumn, whose native
    -- gutter bg must show through); otherwise the gap wears the fill group (default LvimUiChromeFill).
    local fill = opts.fill == false and "%=" or ("%%#%s#%%="):format(opts.fill or "LvimUiChromeFill")
    local always_volatile = opts.volatile == true

    ---@type table<string, string>   name -> last built string
    local cache = {}
    ---@type table<string, boolean>  name -> needs rebuild
    local dirty = {}
    ---@type integer?                the buffer the `buf` segments were built for
    local cache_buf = nil

    local self = {}

    --- Mark cached segments for rebuild. `nil` = all.
    ---@param names? string[]
    function self.invalidate(names)
        if names then
            for _, n in ipairs(names) do
                dirty[n] = true
            end
        else
            cache, dirty = {}, {}
        end
    end

    ---@param spec LvimChromeSegment
    ---@param ctx LvimChromeCtx
    ---@return string
    local function eval(spec, ctx)
        if spec.align then
            return fill
        end
        local name = spec.name
        if always_volatile or not name then
            return build(spec, ctx) -- per-line instance, or unnamed → never cache; build fresh
        end
        if volatile(spec) or dirty[name] or cache[name] == nil then
            cache[name] = build(spec, ctx)
            dirty[name] = false
        end
        return cache[name]
    end

    --- Render a segment list (handles the buffer-switch invalidation of `buf` segments).
    ---@param segs LvimChromeSegment[]
    ---@param ctx LvimChromeCtx
    ---@return string
    function self.render(segs, ctx)
        if ctx.buf ~= cache_buf then
            cache_buf = ctx.buf
            for _, spec in ipairs(segs) do
                if spec.buf and spec.name then
                    dirty[spec.name] = true
                end
            end
        end
        local out = {}
        for _, spec in ipairs(segs) do
            out[#out + 1] = eval(spec, ctx)
        end
        return table.concat(out)
    end

    --- Install the invalidation autocmds derived from the segments' `events`. INVALIDATE-ONLY, like heirline:
    --- each event just clears the affected segments' cache (so they re-evaluate on Neovim's NEXT native
    --- redraw) — it does NOT force a redraw. A `"User:Pat"` event registers a User autocmd on Pat. (Anything
    --- that must repaint NOW — the git poller's branch change, etc. — issues its own redraw in the component.)
    ---@param grp integer
    ---@param segs LvimChromeSegment[]
    function self.install_autocmds(grp, segs)
        ---@type table<string, table<string, boolean>>  event(or "User:Pat") -> set of segment names
        local by_event = {}
        for _, spec in ipairs(segs) do
            local events = spec.events
            if type(events) == "table" and spec.name then
                for _, ev in ipairs(events) do
                    by_event[ev] = by_event[ev] or {}
                    by_event[ev][spec.name] = true
                end
            end
        end
        for ev, nameset in pairs(by_event) do
            local names = vim.tbl_keys(nameset)
            local pat = ev:match("^User:(.+)$")
            -- pcall: an UNKNOWN event name (a typo in a custom segment's `events`) must NOT abort the whole
            -- install (which would leave the bar un-set). Skip it + warn, keep the rest working.
            local ok = pcall(api.nvim_create_autocmd, pat and "User" or ev, {
                group = grp,
                pattern = pat, -- nil for non-User events
                callback = function()
                    self.invalidate(names) -- invalidate-only; Neovim's native redraw repaints
                end,
            })
            if not ok then
                vim.schedule(function()
                    vim.notify(("lvim-hud.chrome: ignored unknown segment event %q"):format(ev), vim.log.levels.WARN)
                end)
            end
        end
    end

    return self
end

return M
