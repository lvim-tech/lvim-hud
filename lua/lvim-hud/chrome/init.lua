-- lvim-hud.chrome: the editor-chrome family — statusline, winbar, tabline, statuscolumn — plus the folded
-- transient finder/echo overlay. One `setup()` registers all four as `%!`-evaluated expressions, self-themes
-- the `LvimUiChrome*` groups from the live palette, starts the shared git poller, and installs the redraw +
-- per-window autocmds. Each component is independently toggleable via `config.chrome`.
--
---@module "lvim-hud.chrome"

local api = vim.api
local parts = require("lvim-hud.chrome.parts")
local git = require("lvim-hud.chrome.git")
local colors = require("lvim-utils.colors")
local highlight = require("lvim-utils.highlight")
local config = require("lvim-hud.config")

local M = {}

M.statusline = require("lvim-hud.chrome.statusline")
M.winbar = require("lvim-hud.chrome.winbar")
M.tabline = require("lvim-hud.chrome.tabline")
M.statuscolumn = require("lvim-hud.chrome.statuscolumn")
M.overlay = require("lvim-hud.chrome.overlay")

local STATUSLINE = "%!v:lua.require'lvim-hud.chrome.statusline'.render()"
local WINBAR = "%!v:lua.require'lvim-hud.chrome.winbar'.render()"
local TABLINE = "%!v:lua.require'lvim-hud.chrome.tabline'.render()"
local STATUSCOLUMN = "%!v:lua.require'lvim-hud.chrome.statuscolumn'.render()"

--- The `LvimUiChrome*` highlight groups, recomputed from the live palette (bound on setup, re-applied on
--- theme change). Accent fg groups sit on the bar bg; mode pills + tab cells are bg-coloured.
---@param palette? table
---@return table<string, table>
local function build(palette)
    local c = palette or colors
    local bg = c.bg_dark
    local pill_fg = (vim.o.background == "dark") and c.bg or c.fg
    local g = {}
    -- accent fg groups (bold), on the bar bg
    local accents = {
        Blue = c.blue,
        Green = c.green,
        Orange = c.orange,
        Cyan = c.cyan,
        Red = c.red,
        Purple = c.purple,
        Yellow = c.yellow,
    }
    for suffix, col in pairs(accents) do
        g["LvimUiChrome" .. suffix] = { fg = col, bg = bg, bold = true }
    end
    g.LvimUiChromeMark = { fg = c.blue } -- statuscolumn mark letter (NO bg → inherits the gutter's own bg)
    -- the bar FILL: a bar-bg group the statusline/tabline wrap their `%=` gap in, so the empty middle stays
    -- bar-coloured (our own group → the colorscheme never overrides it, unlike the global StatusLine group)
    g.LvimUiChromeFill = { fg = c.fg, bg = bg }
    -- mode pills (bg-coloured)
    g.LvimUiChromeModeN = { bg = c.green, fg = pill_fg, bold = true }
    g.LvimUiChromeModeI = { bg = c.red, fg = pill_fg, bold = true }
    g.LvimUiChromeModeV = { bg = c.orange, fg = pill_fg, bold = true }
    g.LvimUiChromeModeC = { bg = c.purple, fg = pill_fg, bold = true }
    g.LvimUiChromeModeR = { bg = c.cyan, fg = pill_fg, bold = true }
    g.LvimUiChromeModeT = { bg = c.blue, fg = pill_fg, bold = true }
    -- git diff counts
    g.LvimUiChromeGitAdd = { fg = c.git.add, bg = bg }
    g.LvimUiChromeGitChange = { fg = c.git.change, bg = bg }
    g.LvimUiChromeGitDelete = { fg = c.git.delete, bg = bg }
    -- diagnostics — the fg comes from the EDITOR's own diagnostic groups (Diagnostic{Error,Warn,Info,Hint}),
    -- so a statusline count matches the gutter signs / virtual text / every other diagnostic UI; the palette
    -- accent is only a fallback for a theme that leaves a group undefined.
    local function diag_fg(group, fallback)
        local h = api.nvim_get_hl(0, { name = group, link = false })
        return (h and h.fg) or fallback
    end
    g.LvimUiChromeDiagError = { fg = diag_fg("DiagnosticError", c.red), bg = bg }
    g.LvimUiChromeDiagWarn = { fg = diag_fg("DiagnosticWarn", c.yellow), bg = bg }
    g.LvimUiChromeDiagInfo = { fg = diag_fg("DiagnosticInfo", c.blue), bg = bg }
    g.LvimUiChromeDiagHint = { fg = diag_fg("DiagnosticHint", c.cyan), bg = bg }
    -- tabline cells
    g.LvimUiChromeTabLogo = { bg = c.green, fg = bg, bold = true }
    g.LvimUiChromeTabActive = { bg = c.green, fg = bg, bold = true }
    g.LvimUiChromeTabInactive = { bg = bg, fg = c.green, bold = true }
    g.LvimUiChromeTabWorkspace = { bg = c.orange, fg = bg, bold = true }
    g.LvimUiChromeTabProject = { bg = c.red, fg = bg, bold = true }
    return g
end

--- Force the standard bar groups to the bar bg so the un-highlighted gaps (`%=`, padding) match the segments.
--- `define` always applies (overrides the colorscheme); re-run on ColorScheme.
local function force_bars()
    local c = colors
    local bg = c.bg_dark
    highlight.define("StatusLine", { bg = bg, fg = c.fg })
    highlight.define("StatusLineNC", { bg = bg, fg = c.fg_dim })
    highlight.define("WinBar", { bg = bg, fg = c.fg })
    highlight.define("WinBarNC", { bg = bg, fg = c.fg_dim })
    highlight.define("TabLine", { bg = bg, fg = c.green })
    highlight.define("TabLineFill", { bg = bg })
    highlight.define("TabLineSel", { bg = c.green, fg = bg, bold = true })
    -- NOTE: the statuscolumn gutter is intentionally NOT forced here — it inherits the colorscheme's own
    -- (dimmed) LineNr / SignColumn / CursorLineNr background, so the gutter stays uniform AND dimmed like
    -- before. The statuscolumn cells use native (no-bg) groups to keep that one continuous gutter bg.
end

--- Apply (or clear) the winbar + statuscolumn for one window, honouring the exclusion lists.
---@param win integer
local function apply_window(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    local cfg = config.chrome
    local buf = api.nvim_win_get_buf(win)
    local float = api.nvim_win_get_config(win).relative ~= ""
    -- Each component honours its OWN blacklist (winbar vs statuscolumn can exclude different buffers). only
    -- assign when the value actually changes — re-setting a window option forces a redraw, so a guard here
    -- avoids needless flicker on every WinEnter. On an EXCLUDED window we clear ONLY our own winbar /
    -- statuscolumn — never wipe a foreign one the window set itself (e.g. neo-tree's source-selector winbar).
    if cfg.winbar.enabled then
        if not (float or parts.excluded(buf, "winbar")) then
            if vim.wo[win].winbar ~= WINBAR then
                vim.wo[win].winbar = WINBAR
            end
        elseif vim.wo[win].winbar == WINBAR then
            vim.wo[win].winbar = ""
        end
    end
    if cfg.statuscolumn.enabled then
        if not (float or parts.excluded(buf, "statuscolumn")) then
            if vim.wo[win].statuscolumn ~= STATUSCOLUMN then
                vim.wo[win].statuscolumn = STATUSCOLUMN
            end
        elseif vim.wo[win].statuscolumn == STATUSCOLUMN then
            vim.wo[win].statuscolumn = ""
        end
    end
end

--- Configure and activate the chrome components from `config.chrome`.
function M.setup()
    local cfg = config.chrome

    -- theming
    highlight.bind(build) -- the LvimUiChrome* groups (auto re-applied on theme change)
    force_bars()

    -- The chrome BARS are chrome, not "background" content: they must NOT fade when an lvim-ui surface
    -- backdrop dims/darkens the windows behind a float. Register our group prefix as UNMUTED in the shared
    -- dim + darken namespaces (both honour `preserve`), so opening any picker leaves the statusline /
    -- winbar / tabline at full colour while the code behind them dims. Self-registered here — lvim-hud owns
    -- the `LvimUiChrome*` groups, so no central config needs to know about them.
    pcall(function()
        require("lvim-utils.dim").preserve("^LvimUiChrome")
    end)

    local grp = api.nvim_create_augroup("LvimUiChrome", { clear = true })
    api.nvim_create_autocmd("ColorScheme", { group = grp, callback = force_bars })

    -- `showtabline` for the CURRENT buffer: 0 on excluded buffers (the start dashboard etc.), the configured
    -- value otherwise — so chrome never paints the tabline over the dashboard.
    local function apply_tabline()
        if not cfg.tabline.enabled then
            return
        end
        -- The tabline is GLOBAL, so its visibility must NOT depend on which window is focused (a transient float
        -- / picker / side panel must never collapse it — that was the "shows, hides, shows" instability). Hide
        -- ONLY when the current tab holds NO real file window (the dashboard); otherwise show.
        local has_real = false
        for _, w in ipairs(api.nvim_tabpage_list_wins(api.nvim_get_current_tabpage())) do
            if api.nvim_win_get_config(w).relative == "" and not parts.excluded(api.nvim_win_get_buf(w), "tabline") then
                has_real = true
                break
            end
        end
        -- With MORE THAN ONE tabpage the tabline is doing its actual job (showing the tabs), so keep it — else a
        -- fullscreen panel tab (e.g. `:LvimGit status` in its dedicated tabpage, whose only real window holds a
        -- nofile backdrop) would collapse it and hide which tab you are on. The dashboard case (a lone tab with
        -- no real file) still hides.
        local target = (has_real or #api.nvim_list_tabpages() > 1) and (cfg.tabline.showtabline or 2) or 0
        if vim.o.showtabline ~= target then
            vim.o.showtabline = target
        end
    end

    -- the float guard (the last regular window, for the statusline) + the winbar / tabline / statuscolumn — the
    -- LATTER only while their component is enabled, so an only-statusline setup does NOT re-apply windows on
    -- every window event. NO explicit `redrawtabline`: the `%!` tabline is re-evaluated by Neovim's native
    -- redraw on these events, so forcing a second repaint only flickered (on cmdline / float close / :e).
    -- `apply_tabline` just keeps `showtabline` right (a change there triggers its own redraw).
    api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "FileType", "WinNew", "WinClosed", "TabEnter", "TabClosed" }, {
        group = grp,
        callback = function()
            M.statusline.track_window()
            if cfg.winbar.enabled or cfg.statuscolumn.enabled then
                apply_window(api.nvim_get_current_win())
            end
            if cfg.tabline.enabled then
                apply_tabline()
            end
        end,
    })

    -- Paint the actual lines on VimEnter — AFTER the start dashboard (snacks sets laststatus/showtabline = 0)
    -- and other startup UIs have loaded — so chrome never briefly flashes a statusline/tabline over them. If
    -- VimEnter already fired (a live re-setup), activate immediately.
    local function activate()
        git.start((cfg.git or {}).poll_ms or 1000)
        -- The statusline component installs its OWN per-segment invalidation autocmds — derived from each
        -- segment's `events` via the shared engine (cursor / text events only invalidate; everything else
        -- forces one redraw) — plus its side effects (git poller restart on DirChanged, dynamic-hl reset on
        -- ColorScheme). Done HERE (VimEnter-deferred), not in setup(): a segments FUNCTION whose `require`
        -- target loads after setup() resolves to `{}` at setup time, so installing then would register NO
        -- invalidation autocmds and the named+`events` segments would cache stale forever.
        M.statusline.install_autocmds(grp)
        if cfg.statusline.enabled then
            vim.o.statusline = STATUSLINE
        end
        if cfg.tabline.enabled then
            vim.o.tabline = TABLINE
        end
        M.statusline.track_window()
        for _, win in ipairs(api.nvim_list_wins()) do
            apply_window(win)
        end
        apply_tabline()
    end
    if vim.v.vim_did_enter == 1 then
        activate()
    else
        api.nvim_create_autocmd("VimEnter", { group = grp, once = true, callback = activate })
    end
end

return M
