# lvim-hud

The editor **HUD** (heads-up display) of the **lvim-tech** set — everything on screen that is *not* the text
buffer, in one plugin:

- **chrome** — the `statusline`, `winbar`, `tabline` and `statuscolumn` components (a segment engine you drive
  from your own config, like heirline), plus a transient finder/echo **overlay** that lets the bottom line act
  as the command/echo area.
- **cmdline** — a self-rendered command-line: the built-in cmdline is externalised (`ext_cmdline`) and drawn in
  an owned float + buffer, so a padded, coloured mode badge (` <icon> Command `) can precede the text.
- **notify** — the notification hub: it intercepts `vim.notify` (and optionally `print`), routes every message
  through pluggable printers, ships per-severity **toast** panels and a browsable `:Messages` **history**.
- **input** — a `vim.ui.input` dispatcher that routes each prompt to either the self-rendered cmdline or a
  styled popup, per call.

## Requirements

Requires **Neovim >= 0.12.x**, [lvim-utils](https://github.com/lvim-tech/lvim-utils) (base: utils / colors /
highlight / cursor) and [lvim-ui](https://github.com/lvim-tech/lvim-ui) (the notify toasts and the input popup
build on its float toolkit). Optional: [lvim-msgarea](https://github.com/lvim-tech/lvim-msgarea) — when present
the cmdline docks into the unified message zone and `:Messages` browses the log inside it; lvim-hud never
depends on it (msgarea registers itself with the cmdline/notify seams).

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-hud" },
})
require("lvim-hud").setup({})
```

## Usage

`setup()` activates the periphery. **notify** and **chrome** are on by default; **cmdline** and **input** are
opt-in (set their `enable`). Pass `notify = false` / `chrome = false` to opt a component out entirely. The
chrome components render nothing until you give them `segments` — a list of segment specs, or a function
returning one (see `lvim-hud.chrome.engine`, and the `chrome.parts` / `chrome.utils` / `chrome.gutter`
helpers).

```lua
require("lvim-hud").setup({
    cmdline = { enable = true }, -- self-rendered command-line
    input = { enable = true }, -- vim.ui.input → cmdline / popup
    chrome = {
        statusline = {
            segments = function()
                return {}
            end,
        }, -- build your segment specs here
        winbar = {
            segments = function()
                return {}
            end,
        },
    },
})
```

The submodules are re-exported through the aggregate — `require("lvim-hud").notify`, `.chrome`, `.cmdline`,
`.input` — so `require("lvim-hud").notify.history()` opens the message log, etc.

## Configuration

`setup()` merges your options into the live config in place (each of `chrome` / `cmdline` / `notify` / `input`
merges into its own subtable; a shorter override list replaces the default wholesale). It is optional — the
defaults below work as-is. The full default config:

```lua
require("lvim-hud").setup({
    -- ── chrome: statusline / winbar / tabline / statuscolumn + the finder/echo overlay ──────────────────
    chrome = {
        -- The bottom line (global, laststatus=3). Define `segments` yourself — a list of specs OR a function
        -- returning one; each spec: { name, content = fn(ctx) -> str, hl?, when?, events?, click?, buf?, align? }.
        statusline = {
            enabled = true,
            segments = nil,
            -- global line ⇒ no per-buffer blacklist (it always renders for the current window).
            exclude = { buftype = {}, filetype = {} },
        },
        -- The per-window top line (terminal label / filename + breadcrumb). ctx = { buf, win, active }.
        winbar = {
            enabled = true,
            segments = nil,
            exclude = {
                buftype = { "nofile", "prompt", "help", "terminal" },
                filetype = { "lvim-dashboard", "Outline", "NvimTree", "neo-tree", "toggleterm", "qf", "..." },
            },
        },
        -- The top tabline. ctx per cell; use engine.click_region(key, fn, text) for clickable window/tab cells.
        tabline = {
            enabled = true,
            showtabline = 2, -- 0 never / 1 when >=2 tabpages / 2 always
            segments = nil,
            exclude = {
                buftype = { "nofile", "prompt", "help", "terminal" },
                filetype = { "lvim-dashboard", "Outline", "NvimTree", "neo-tree", "toggleterm", "qf", "..." },
            },
        },
        -- The per-line gutter. ctx = { buf, win, lnum, relnum, virtnum }; compose from chrome.gutter + chrome.parts.
        statuscolumn = {
            enabled = true,
            segments = nil,
            exclude = {
                buftype = { "nofile", "prompt", "help", "terminal" },
                filetype = { "lvim-dashboard", "Outline", "NvimTree", "neo-tree", "toggleterm", "qf", "..." },
            },
        },
        -- The transient finder/echo overlay: a navigator / the cmdline publishes a title + counter here and the
        -- statusline DISPLAYS it, so the bottom line is the echo/info area. Off ⇒ each UI draws its own title.
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
        -- Shared git poller (the .git/HEAD fs_poll interval, ms).
        git = { poll_ms = 1000 },
        -- Single-width Nerd-font glyphs for every component (override any with a literal glyph).
        icons = {
            vim = "", -- mode pill leader / tabline logo
            folder = "󰉖", -- cwd
            git = "", -- branch
            commit = "", -- hunk position
            separator = "➤", -- breadcrumb / sequence separator
            lock = "", -- readonly
            save = "", -- modified
            vline = "▌", -- statuscolumn git gutter bar
            terminal = "", -- winbar terminal label
            lsp = "", -- lsp / lint / format segment
            unix = "",
            dos = "",
            mac = "",
            git_status = { added = "", deleted = "", modified = "" },
            diagnostics = { error = "", warn = "", info = "", hint = "󰌵", global = "" },
            -- the 8 scrollbar block chars, tallest (top) -> shortest (bottom)
            scrollbar = { "█", "▇", "▆", "▅", "▄", "▃", "▂", "▁" },
        },
    },

    -- ── cmdline: the self-rendered command-line (opt-in) ────────────────────────────────────────────────
    cmdline = {
        enable = false, -- master switch
        -- Messages routed here (notify ext_kinds -> "cmdline") show in the float.
        message = {
            enable = true,
            glyph = "",
            hl = "LvimUiCmdlineInput",
            timeout = 0, -- 0 = persist until a dismiss key; >0 = auto-hide after N ms
            dismiss_keys = { "<Esc>" },
        },
        -- Publish the cmdline MODE (label + glyph) + the match counter to the bottom statusline (chrome.overlay);
        -- the float then keeps only the glyph. false = keep the full mode badge in the float, nothing published.
        statusline = true,
        badge_pad_left = 2, -- spaces left of the mode-badge glyph (when the badge shows in the float)
        badge_pad_right = 2, -- spaces right of the mode-badge glyph
        row_offset = 0, -- rows of extra offset above the cmdheight area
        caret = "▎", -- the caret glyph drawn in the externalised cmdline (no real cursor there)
        max_height = false, -- max float height; false = auto (~ half the screen)
        newline_keys = { "<M-CR>" }, -- cmdline-mode keys that insert a literal newline ({} to disable)
        -- firstc -> { glyph, label, hl }. The left panel shows " <glyph> <label> ".
        modes = {
            [":"] = { glyph = "", label = "Command", hl = "LvimUiCmdlineCommand" },
            ["/"] = { glyph = "", label = "Search ↓ down", hl = "LvimUiCmdlineSearch" },
            ["?"] = { glyph = "", label = "Search ↑ up", hl = "LvimUiCmdlineSearch" },
            ["="] = { glyph = "", label = "Expr", hl = "LvimUiCmdlineEval" },
            ["@"] = { glyph = "", label = "", hl = "LvimUiCmdlineInput" },
        },
        fallback = { glyph = "", label = "", hl = "LvimUiCmdlineCommand" },
        -- Content sub-modes for ":" commands (first match wins): a mode entry + a Lua-pattern `match`.
        patterns = {
            { match = "^lua[ =]", strip = "^lua%s*=?%s*", glyph = "", label = "Lua", hl = "LvimUiCmdlineLua" },
            { match = "^=", strip = "^=%s*", glyph = "", label = "Expr", hl = "LvimUiCmdlineEval" },
            { match = "^!", strip = "^!%s*", glyph = "", label = "Shell", hl = "LvimUiCmdlineShell" },
            { match = "^%S*s/", glyph = "", label = "Substitute", hl = "LvimUiCmdlineSubstitute" },
            { match = "^setl?%a* ", strip = "^set%a*%s+", glyph = "", label = "Set", hl = "LvimUiCmdlineSet" },
        },
    },

    -- ── notify: the notification hub (toasts + :Messages history) ────────────────────────────────────────
    notify = {
        max_history = 100, -- ring-buffer size for notify.history()
        timeout = 5000, -- auto-dismiss delay in ms; 0 = sticky
        dedup = true, -- collapse identical consecutive toasts into one with a ×N badge
        min_width = 50, -- panel width bounds
        max_width = 100,
        padding = 1, -- horizontal padding inside the panel
        bottom_margin = 0, -- gap (rows) above the statusline
        panel_gap = 0, -- rows between stacked level panels
        border = "none", -- floating window border
        zindex = 1000, -- floating window z-index
        separator = "─", -- char repeated across the panel width as entry separator
        show_separator = false, -- separator line between messages in the same panel
        override_print = true, -- replace global print() as well
        ext_messages = true, -- intercept all Neovim messages via vim.ui_attach (ext_messages)
        ext_echo_timeout = 3000, -- timeout (ms) for echo/info-level ext messages
        -- per-kind behaviour: "toast" = panel + history, "history" = history only, "ignore" = drop
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
            confirm = "toast", -- :confirm / confirm() / inputlist() / z= prompt text — kept sticky until answered
            shell_out = "history",
            lua_print = "history",
            verbose = "history",
            [""] = "history",
            search_count = "ignore",
            search_cmd = "ignore",
            wildlist = "ignore",
            completion = "ignore",
        },
        printers = { "toast", "history" }, -- active printers on load: "toast" / "history" / { name, fn } / fn
        progress_width = nil, -- width of the progress panel (nil = max_width)
        icons = {
            trace = "",
            debug = "",
            error = "",
            warn = "",
            info = "",
            hint = "",
            progress = "",
        },
        level_names = { trace = "Trace", debug = "Debug", info = "Info", warn = "Warn", error = "Error" },
        -- The :Messages history zone (rendered in lvim-msgarea when installed) + its filter bar.
        history = {
            title = "Messages", -- the panel label
            -- Seconds a message stays PASSIVELY visible in the zone while you are NOT in it (each runs its own
            -- clock; descending into the zone lists the whole history and pauses the countdowns). 0 = always.
            hide_after = 10,
            -- The circle glyph in front of each message that DRAINS (FULL → EMPTY) as its countdown runs out.
            -- Set to false (or {}) for no glyph.
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
            statusline = true, -- true: publish title + count to the statusline; false: title at the LEFT of the bar
            -- Background-tint strength of the message rows (blend of the level colour toward the bg).
            tints = {
                row = 0.05, -- the whole row + its text
                icon = 0.1, -- the level icon's cell (bold badge)
                active = 0.2, -- the row under the cursor while you are IN the zone
            },
            -- The accent each level (and each bar action) is tinted with: a palette KEY or a literal "#rrggbb".
            colors = {
                error = "red",
                warn = "orange",
                info = "blue",
                debug = "purple",
                refresh = "green", -- the bar's Refresh button
                close = "yellow", -- the bar's Close button
            },
            bar = {
                key_pad = { 1, 1 }, -- the hotkey BADGE padding { front, back }
                label_pad = { 1, 1 }, -- the NAME padding { front, back }
                gap = 0, -- extra spacing between buttons
                tints = {
                    badge = { normal = 0.2, active = 0.4 }, -- the hotkey letter
                    name = { normal = 0.1, active = 0.3 }, -- the name
                },
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
    },

    -- ── input: the vim.ui.input dispatcher (opt-in) ─────────────────────────────────────────────────────
    input = {
        enable = false, -- master switch
        default = "popup", -- target when neither opts.ui nor route_next() is set: "cmdline" | "popup"
    },
})
```

> The four component `exclude` lists share one blacklist of special-buffer filetypes (the start dashboard,
> tool panels, terminals, …) plus a per-component `qf` entry — abbreviated above with `"..."`; see
> `lua/lvim-hud/config.lua` for the full list.

## License

BSD-3-Clause.
