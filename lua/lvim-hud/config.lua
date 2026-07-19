-- lvim-hud.config: the live config for the editor-periphery (HUD) plugin — everything that is NOT the text
-- buffer: the chrome components (statusline / winbar / tabline / statuscolumn + the transient finder/echo
-- OVERLAY), the self-rendered command-line, the notification hub (toasts + the :Messages history), and the
-- vim.ui.input dispatcher.
--
-- `setup()` (lvim-hud.init) merges the user's `{ chrome, cmdline, notify, input }` into the matching sub-table
-- here IN PLACE (via lvim-utils.utils.merge); readers `require("lvim-hud.config").<mod>` see the effective
-- values. Every glyph is a real single-width Nerd-font codepoint.
--
---@module "lvim-hud.config"

local M = {}

local function chrome_exclude(extra_ft)
    local filetype = {
        "lvim-dashboard", -- the lvim-tech start dashboard
        "snacks_dashboard",
        "alpha",
        "ctrlspace",
        "ctrlspace_help",
        "undotree",
        "diff",
        "Outline",
        "NvimTree",
        "LvimHelper",
        "dashboard",
        "vista",
        "spectre_panel",
        "DiffviewFiles",
        "flutterToolsOutline",
        "log",
        "dapui_scopes",
        "dapui_breakpoints",
        "dapui_stacks",
        "dapui_watches",
        "dapui_console",
        "calendar",
        "neo-tree",
        "neo-tree-popup",
        "noice",
        "toggleterm",
        "git",
        "netrw",
        "dbee",
        "fzf",
        "replacer",
    }
    for _, ft in ipairs(extra_ft or {}) do
        filetype[#filetype + 1] = ft
    end
    return {
        buftype = { "nofile", "prompt", "help", "terminal" },
        filetype = filetype,
    }
end

---@class LvimHudChromeConfig
---@field statusline   table  The bottom line component (enabled / segments / exclude)
---@field winbar       table  The per-window top line component (enabled / segments / exclude)
---@field tabline      table  The top tabline component (enabled / showtabline / segments / exclude)
---@field statuscolumn table  The per-line gutter component (enabled / segments / exclude)
---@field overlay      table  The transient finder/echo overlay (enabled / show_action / show_counter / pads)
---@field git          table  Shared git poller (poll_ms — the .git/HEAD fs_poll interval)
---@field icons        table  Single-width Nerd-font glyphs for every component (mode / git / diagnostics / scrollbar / …)
---@field icon_provider "auto"|"lvim"|"devicons"|"mini"  Which plugin provides the file devicon (via lvim-utils.icons)
---@field icon_color_mode string?  lvim-icons colour mode for the devicon: "theme"|"brand"|"theme_brand"; nil = the lvim-icons global default

---@type LvimHudChromeConfig
M.chrome = {
    -- Which icon plugin supplies the per-file devicon (resolved through lvim-utils.icons):
    -- "auto" prefers lvim-icons, then nvim-web-devicons, then mini.icons, else a built-in glyph.
    icon_provider = "auto",
    -- lvim-icons colour mode for the devicon (ignored by devicons/mini): "theme" follows the
    -- colorscheme, "brand" the real brand hue, "theme_brand" a mix. nil = lvim-icons' own default.
    icon_color_mode = nil,
    -- ── statusline ────────────────────────────────────────────────────────────
    -- The bottom line, rendered by lvim-hud.chrome.engine. There are NO predefined segments (like heirline) —
    -- YOU define them all in your config. `segments` is a LIST of specs, OR a FUNCTION returning one (resolved
    -- lazily at render time, so no eager require). Each spec:
    --   { name, content = fn(ctx) -> str, hl?, when?, events?, click?, buf?, align? }   (see chrome.engine)
    -- Compose from the helpers — chrome.parts (seg / icons / devicon), chrome.utils, chrome.git. Unset / empty
    -- ⇒ a blank line.
    statusline = {
        enabled = true,
        ---@type LvimChromeSegment[]|fun(): LvimChromeSegment[]|nil
        segments = nil,
        -- The statusline is GLOBAL (laststatus=3): a SINGLE line for the whole editor. A per-buffer blacklist
        -- would only BLANK that one line whenever the focused window is a special buffer (dashboard, qf,
        -- neo-tree, terminal, help …) — never wanted — so it is EMPTY: the statusline ALWAYS renders for the
        -- current window. (The PER-WINDOW winbar / statuscolumn below keep their own blacklists.)
        exclude = { buftype = {}, filetype = {} },
    },

    -- ── winbar ────────────────────────────────────────────────────────────────
    -- Per-window top line: terminal label / inactive filename / active filename + breadcrumb.
    winbar = {
        enabled = true,
        -- The per-window top line, rendered by lvim-hud.chrome.engine. NO predefined sections (like heirline)
        -- — YOU define them in your config. `segments` = a LIST of specs, OR a FUNCTION returning one; each
        -- section's `content = fn(ctx)` gets ctx = { buf, win, active } and gates with `when`. Compose from
        -- chrome.parts (devicon / unique_name / seg / icons) + chrome.utils. Unset ⇒ a blank winbar.
        ---@type LvimChromeSegment[]|fun(): LvimChromeSegment[]|nil
        segments = nil,
        -- this component's OWN buftype/filetype blacklist (no winbar on these buffers). `qf` is here (but NOT in
        -- the statusline list) because lvim-qf-loc draws the quickfix window's OWN winbar (the keymap bar) — the
        -- chrome winbar would fight it — while the quickfix still gets a normal chrome STATUSLINE.
        exclude = chrome_exclude({ "qf" }),
    },

    -- ── tabline ───────────────────────────────────────────────────────────────
    -- vim logo · current-tab windows · `%=` · lvim-space tabs · workspace · project.
    tabline = {
        enabled = true,
        showtabline = 2, -- 0 never / 1 when ≥2 tabpages / 2 always
        -- The top tabline, rendered by lvim-hud.chrome.engine. NO predefined sections (like heirline) — YOU
        -- define them in your config. `segments` = a LIST of specs, OR a FUNCTION returning one. Compose from
        -- chrome.parts (seg / icons / excluded / unique_name) + `engine.click_region(key, fn, text)` for
        -- clickable window / tab CELLS (tabby's functionality). Unset ⇒ a blank tabline.
        ---@type LvimChromeSegment[]|fun(): LvimChromeSegment[]|nil
        segments = nil,
        -- this component's OWN buftype/filetype blacklist (tabline hidden when the tab holds only these). `qf` is
        -- excluded here too (a lone quickfix tab keeps the tabline hidden), but NOT from the statusline.
        exclude = chrome_exclude({ "qf" }),
    },

    -- ── statuscolumn ──────────────────────────────────────────────────────────
    -- other-sign · diagnostic-sign · `%=` · line numbers (+marks) · git gutter.
    statuscolumn = {
        enabled = true,
        -- The per-line gutter, rendered by lvim-hud.chrome.engine. NO predefined sections (like heirline) —
        -- YOU define them in your config. `segments` = a LIST of specs, OR a FUNCTION returning one; each
        -- section's `content = fn(ctx)` gets ctx = { buf, win, lnum, relnum, virtnum }. Compose from
        -- chrome.gutter (signs / diag_icon / mark_letter / sign_at_mouse) + chrome.parts. Unset ⇒ blank gutter.
        ---@type LvimChromeSegment[]|fun(): LvimChromeSegment[]|nil
        segments = nil,
        -- this component's OWN buftype/filetype blacklist (no statuscolumn gutter on these buffers). `qf` is
        -- excluded here too (the quickfix shows file:line in its content, so no gutter), but NOT the statusline.
        exclude = chrome_exclude({ "qf" }),
    },

    -- ── transient finder / echo overlay (ex config.status) ──────────────────────
    -- A navigator / the command-line publishes a title + match counter here and the statusline DISPLAYS it,
    -- so the bottom line acts as the echo/info area. Off → each UI draws its own title in place.
    overlay = {
        enabled = true, -- master switch for the echo/info model
        show_action = false, -- show the typed query/command on the left
        show_counter = true, -- show the match counter (current/total) on the right
        icon_pad_left = 1,
        icon_pad_right = 2,
        title_pad_left = 1,
        title_pad_right = 1,
        segment_pad = 1,
    },

    -- ── shared: git poller ──────────────────────────────────────────────────────
    git = {
        poll_ms = 1000, -- .git/HEAD fs_poll interval
    },

    -- ── icons (single-width Nerd-font; override any with a literal glyph) ────────
    icons = {
        vim = "", -- mode pill leader / tabline logo
        folder = "󰉖", -- cwd
        git = "", -- branch
        commit = "", -- hunk position
        separator = "➤", -- breadcrumb / sequence separator (➤)
        lock = "", -- readonly
        save = "", -- modified
        vline = "▌", -- statuscolumn git gutter bar (▌)
        terminal = "", -- winbar terminal label
        lsp = "", -- lsp/lint/format segment
        unix = "",
        dos = "",
        mac = "",
        git_status = {
            added = "",
            deleted = "",
            modified = "",
        },
        diagnostics = {
            error = "",
            warn = "",
            info = "",
            hint = "󰌵",
            global = "",
        },
        -- the 8 scrollbar block chars, tallest (top) → shortest (bottom): █▇▆▅▄▃▂▁
        scrollbar = {
            "█",
            "▇",
            "▆",
            "▅",
            "▄",
            "▃",
            "▂",
            "▁",
        },
    },
}

---@class LvimHudCmdlineConfig
---@field enable          boolean  Master switch for the self-rendered cmdline
---@field message         table    Routed-message display in the float (enable / glyph / hl / timeout / dismiss_keys)
---@field statusline      boolean  Publish the cmdline mode + match counter to the bottom statusline
---@field badge_pad_left  integer  Spaces left of the mode-badge glyph (when the badge shows in the float)
---@field badge_pad_right integer  Spaces right of the mode-badge glyph
---@field row_offset      integer  Rows of extra offset above the cmdheight area
---@field caret           string   The caret glyph drawn in the externalised cmdline (no real cursor there)
---@field max_height      integer|boolean Max float height; false = auto (≈ half the screen)
---@field newline_keys    string[] Cmdline-mode keys that insert a literal newline ({} to disable)
---@field keep_open_on_empty_bs boolean  Backspace/Ctrl-H on an EMPTY cmdline is a no-op instead of Neovim's default abort (default true; Esc / Ctrl-C still abort)
---@field modes           table    firstc → { glyph, label, hl } per command-line mode (: / ? = @)
---@field fallback        table    { glyph, label, hl } used when no mode entry matches
---@field patterns        table[]  Content sub-modes for ":" commands (first match wins), each mode entry + a `match`

---@type LvimHudCmdlineConfig
M.cmdline = {
    enable = false,
    -- Messages routed here (via notify ext_kinds -> "cmdline") are shown in the float.
    -- Configure which kinds in the host's notify.ext_kinds (e.g. lua_print = "cmdline").
    message = {
        enable = true,
        glyph = "",
        hl = "LvimUiCmdlineInput",
        timeout = 0, -- 0 = persist until a dismiss key; >0 = auto-hide after N ms
        -- Keys that clear a persistent message (Vim notation; "esc" accepted). List.
        dismiss_keys = { "<Esc>" },
    },
    -- Statusline integration (default on): publish the cmdline MODE (label + glyph) and the completion
    -- match counter to the bottom statusline (lvim-hud.chrome.overlay), so the line shows the current action like
    -- the navigator. The float then keeps only the glyph as a compact prompt prefix (the static label moves
    -- to the statusline). false = keep the full mode label badge in the float, nothing in the statusline.
    statusline = true,
    -- The float's mode badge padding (when the badge is shown in the float — i.e. `statusline = false`, or
    -- an input() prompt). Independent spaces left of / right of the glyph (the gap to the label / text).
    badge_pad_left = 2,
    badge_pad_right = 2,
    -- Rows of extra offset above the cmdheight area.
    row_offset = 0,
    -- The caret GLYPH drawn in the externalised cmdline (there is no real cursor there — it is hidden). Its
    -- COLOUR follows the active mode (each `modes.<x>.hl` group's `fg`). "▎" (¼ cell) matches the finders'
    -- terminal beam-cursor width; "▏" is thinner (⅛ cell), "█" a full block.
    caret = "▎",
    -- Max float height; false = auto (≈ half the screen). Long input wraps + grows up.
    max_height = false,
    -- Cmdline-mode keys that insert a literal newline (multi-line command input).
    -- Set to {} to disable.
    newline_keys = { "<M-CR>" },
    -- <BS>/<C-h> on an EMPTY cmdline is a no-op (the cmdline stays open) instead of Neovim's default, which
    -- ABORTS the cmdline there — a surprising exit while deleting back through a command. Esc / <C-c> still
    -- abort. Set false for the stock behaviour.
    keep_open_on_empty_bs = true,
    -- firstc -> { glyph, label, hl }. The left panel shows " <glyph> <label> "; for the
    -- input mode (@) the live prompt (e.g. "New name: ") is used instead of the label.
    modes = {
        [":"] = { glyph = "", label = "Command", hl = "LvimUiCmdlineCommand" },
        ["/"] = { glyph = "", label = "Search ↓ down", hl = "LvimUiCmdlineSearch" },
        ["?"] = { glyph = "", label = "Search ↑ up", hl = "LvimUiCmdlineSearch" },
        ["="] = { glyph = "", label = "Expr", hl = "LvimUiCmdlineEval" },
        ["@"] = { glyph = "", label = "", hl = "LvimUiCmdlineInput" },
    },
    fallback = { glyph = "", label = "", hl = "LvimUiCmdlineCommand" },
    -- Content sub-modes for ":" commands (first match wins). Each is like a mode
    -- entry plus a Lua-pattern `match` tested against the typed command text.
    patterns = {
        { match = "^lua[ =]", strip = "^lua%s*=?%s*", glyph = "", label = "Lua", hl = "LvimUiCmdlineLua" },
        { match = "^=", strip = "^=%s*", glyph = "", label = "Expr", hl = "LvimUiCmdlineEval" },
        { match = "^!", strip = "^!%s*", glyph = "", label = "Shell", hl = "LvimUiCmdlineShell" },
        { match = "^%S*s/", glyph = "", label = "Substitute", hl = "LvimUiCmdlineSubstitute" },
        { match = "^setl?%a* ", strip = "^set%a*%s+", glyph = "", label = "Set", hl = "LvimUiCmdlineSet" },
    },
}

---@class LvimHudNotifyConfig
---@field max_history       integer  Ring-buffer size for M.history()
---@field timeout           integer  Auto-dismiss delay in ms; 0 = sticky
---@field dedup             boolean  Collapse identical consecutive toasts into one with a ×N badge
---@field min_width         integer  Panel minimum width
---@field max_width         integer  Panel maximum width
---@field padding           integer  Horizontal padding inside the panel
---@field bottom_margin     integer  Gap (rows) above the statusline
---@field panel_gap         integer  Rows between stacked level panels
---@field border            string   Floating window border (passed to nvim_open_win)
---@field zindex            integer  Floating window z-index
---@field separator         string   Character repeated across the panel width as entry separator
---@field show_separator    boolean  Show a separator line between individual messages in the same panel
---@field override_print    boolean  Replace global print() as well
---@field ext_messages      boolean  Intercept all Neovim messages via vim.ui_attach (ext_messages)
---@field ext_echo_timeout  integer  Timeout (ms) for echo/info-level ext messages
---@field ext_kinds         table<string, string> Per-kind behaviour: "toast" | "history" | "ignore"
---@field printers          table    Active printers on load ("toast" / "history" / { name, fn } / fn)
---@field progress_width    integer|nil Width of the progress panel (nil = max_width)
---@field icons             table<string, string> Level icons
---@field level_names       table<string, string> Singular/plural level names shown in the header bar
---@field history           table    The :Messages history zone + its filter bar

---@type LvimHudNotifyConfig
M.notify = {
    -- Ring-buffer size for M.history()
    max_history = 100,
    -- Auto-dismiss delay in ms; 0 = sticky
    timeout = 5000,
    -- Collapse identical consecutive toasts into one with a ×N badge (refreshes timeout)
    dedup = true,
    -- Panel width bounds
    min_width = 50,
    max_width = 100,
    -- Horizontal padding inside the panel
    padding = 1,
    -- Gap (rows) ABOVE the statusline: the toast stack is anchored over `cmdheight` + the statusline, so it
    -- sits above the statusline and rides up when the msgarea / cmdline area grows `cmdheight`. 0 = adjacent.
    bottom_margin = 0,
    -- Rows between stacked level panels
    panel_gap = 0,
    -- Floating window border (passed to nvim_open_win)
    border = "none",
    -- Floating window z-index
    zindex = 1000,
    -- Character repeated across the panel width as entry separator
    separator = "─",
    -- Show separator line between individual messages in the same panel
    show_separator = false,
    -- Replace global print() as well
    override_print = true,
    -- Intercept all Neovim messages via vim.ui_attach (ext_messages)
    ext_messages = true,
    -- Timeout (ms) for echo/info-level ext messages
    ext_echo_timeout = 3000,
    -- Per-kind behaviour: "toast" = panel + history, "history" = history only, "ignore" = drop
    ext_kinds = {
        emsg = "toast",
        echoerr = "toast",
        lua_error = "toast",
        rpc_error = "toast",
        shell_err = "toast",
        wmsg = "toast",
        echomsg = "toast",
        echo = "toast",
        bufwrite = "toast",
        undo = "toast",
        -- The message that PRECEDES a blocking prompt (:confirm, confirm(), inputlist(), z=). MUST be visible
        -- (the editor then blocks in getchar with nothing else on screen); routed to a toast that notify keeps
        -- STICKY until the prompt ends (its `msg_clear`). Routing it to "history" would hide the prompt.
        confirm = "toast",
        shell_out = "history",
        lua_print = "history",
        verbose = "history",
        [""] = "history",
        search_count = "ignore",
        search_cmd = "ignore",
        wildlist = "ignore",
        completion = "ignore",
    },
    -- Active printers on load: "toast", "history", or { name, fn } / fn
    printers = { "toast", "history" },
    -- Width of the progress panel (defaults to max_width when nil)
    progress_width = nil,
    -- Level icons
    icons = {
        trace = "",
        debug = "",
        error = "",
        warn = "",
        info = "",
        hint = "",
        progress = "",
    },
    -- Singular/plural level names shown in the header bar
    level_names = {
        trace = "Trace",
        debug = "Debug",
        info = "Info",
        warn = "Warn",
        error = "Error",
    },

    -- ── Message history / :Messages zone ─────────────────────────────────────────────────────────────
    -- The styled message panel (lvim-msgarea) + its filter bar. Fully customisable here.
    history = {
        title = "Messages", -- the panel label
        -- TRANSIENT display: how many SECONDS a message stays on screen in the zone while you are NOT in it.
        -- Each message runs its OWN clock — a newer one lands on top with a fresh countdown and does not
        -- extend the older ones — and the zone closes once the last live message expires. Descending INTO the
        -- zone lists the WHOLE history (nothing is dropped, only hidden) and PAUSES every countdown while you
        -- read; leaving resumes them where they stopped.
        -- 0 = the old behaviour: every message opens the zone with the whole history, and it stays.
        hide_after = 10,
        -- The LIFE glyph in front of each message while `hide_after` is on: a Nerd Font circle that DRAINS as
        -- the message's own countdown runs out (full when it arrives, empty just before it goes), so you can
        -- see at a glance how long each one still has. The frame is picked by the REMAINING fraction — this is
        -- not a spinner. Frames go FULL → EMPTY. Set to false (or {}) to show no glyph.
        life_icons = {
            "\u{f0aa5}",
            "\u{f0aa4}",
            "\u{f0aa3}",
            "\u{f0aa2}",
            "\u{f0aa1}",
            "\u{f0aa0}",
            "\u{f0a9f}",
            "\u{f0a9e}",
        },
        statusline = true, -- true: publish the title + count to the statusline; false: show the title at the LEFT of the bar
        -- Background-tint strength of the message ROWS themselves — a blend of the LEVEL's colour toward the
        -- background (0 = plain bg, 1 = the pure level colour). The rhythm is body < accent cell < active:
        -- the row only HINTS at its level, the icon cell reads as a badge, and the focused row is the one
        -- thing that must be unmistakable (the hardware cursor is hidden in the panel).
        tints = {
            row = 0.05, -- the whole row (and its text): the level tint you read the panel by
            icon = 0.1, -- the level icon's cell (bold) — a denser badge beside the row
            active = 0.2, -- the row under the cursor while you are IN the zone (bold)
        },
        -- The ACCENT each level (and each bar action) is tinted with. A lvim-utils PALETTE KEY (so it tracks
        -- the live theme — "red", "blue", …) or a literal "#rrggbb". Every group above is derived from these,
        -- so recolouring a level here recolours its row, its icon cell, its focused row AND its filter button.
        colors = {
            error = "red",
            warn = "orange",
            info = "blue",
            debug = "purple",
            refresh = "green", -- the bar's Refresh button
            close = "yellow", -- the bar's Close button
        },
        -- The focused filter bar (rendered through ui.bar — navigable buttons + overflow chevrons).
        bar = {
            key_pad = { 1, 1 }, -- the hotkey BADGE padding { front, back }
            label_pad = { 1, 1 }, -- the NAME padding { front, back }
            gap = 0, -- extra spacing inserted between buttons
            -- Background-tint strength (blend toward the bg) per part + state. The two parts brighten together
            -- when a button is HOVERED or is the ACTIVE filter.
            tints = {
                badge = { normal = 0.2, active = 0.4 }, -- the hotkey letter
                name = { normal = 0.1, active = 0.3 }, -- the name
            },
            -- Per-button label override (keyed by id: all/error/warn/info/debug/refresh/close). nil = default.
            labels = {
                all = "All",
                error = "Error",
                warn = "Warn",
                info = "Info",
                debug = "Debug",
                refresh = "Refresh",
                close = "Close",
            },
        },
    },
}

---@class LvimHudInputConfig
---@field enable  boolean  Master switch for the input dispatcher
---@field default string   Default target when neither opts.ui nor route_next() is set: "cmdline" | "popup"

---@type LvimHudInputConfig
M.input = {
    enable = false,
    -- Default target when neither opts.ui nor route_next() is set: "cmdline" | "popup".
    default = "popup",
}

return M
