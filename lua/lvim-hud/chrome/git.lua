-- lvim-hud.chrome.git: a background git-HEAD poller for the chrome statusline / tabline.
--
-- Reads branch + abbreviated SHA + full OID + last commit subject + tag info via the git CLI (ASYNCHRONOUSLY,
-- through non-blocking `vim.system`), caches the result, and refreshes it through a libuv fs_poll watching
-- `<root>/.git/HEAD` — so the statusline reads git data synchronously FROM THE CACHE while every git fork
-- happens off the UI thread. One shared instance; started on VimEnter / DirChanged.
--
---@module "lvim-hud.chrome.git"

local uv = vim.uv

local M = {}

---@class LvimChromeGitHead
---@field branch string
---@field abbrev string  short (7-char) commit hash
---@field oid string  full 40-char commit OID
---@field commit_message string  subject line of the most recent commit
---@field detached boolean  true when HEAD is detached
---@field tag { name?: string, distance?: integer, oid?: string }

---@type { root: string, head: LvimChromeGitHead }?  the cached status (nil outside a repo)
local cache = nil
---@type uv.uv_fs_poll_t[]  the .git/HEAD + .git/logs/HEAD watchers (empty outside a repo)
local pollers = {}
---@type integer  bumped on every M.start; a scheduled root callback from a superseded start bails
local start_gen = 0

--- Stop and close every fs_poll watcher.
local function stop_pollers()
    for _, p in ipairs(pollers) do
        p:stop()
        p:close()
    end
    pollers = {}
end

--- The cached git status, or nil when the cwd is not inside a git repository.
---@return { root: string, head: LvimChromeGitHead }?
function M.get()
    return cache
end

--- Run one git subcommand asynchronously (never blocks the UI thread) and hand its trimmed stdout — or nil on
--- a non-zero exit / spawn failure — to `cb`. `cb` runs on the libuv thread; callers marshal to the main loop.
---@param root string  the repository root (cwd for the child)
---@param args string[]  the git argv (WITHOUT the leading "git")
---@param cb fun(out: string?)
local function git_async(root, args, cb)
    local ok = pcall(vim.system, { "git", unpack(args) }, { cwd = root, text = true }, function(res)
        cb((res.code == 0 and type(res.stdout) == "string" and res.stdout ~= "") and vim.trim(res.stdout) or nil)
    end)
    if not ok then
        cb(nil)
    end
end

--- Refresh the cache for `root` in the BACKGROUND — three non-blocking `vim.system` git calls (log for
--- abbrev/oid/subject, rev-parse for the branch, describe for the tag) — then, from the final scheduled
--- callback, write the cache and fire `User LvimUiChromeGit` so the chrome statusline invalidates + repaints.
---@param root string
function M.update(root)
    local pending, log_out, branch_out, desc_out = 3, nil, nil, nil
    local function done()
        pending = pending - 1
        if pending > 0 then
            return
        end
        vim.schedule(function()
            local abbrev, oid, commit_message = "unknown", "unknown", "no commit message"
            if log_out and log_out ~= "" then
                local l = vim.split(log_out, "\n", { plain = true })
                abbrev = (l[1] and l[1] ~= "") and l[1] or "unknown"
                oid = (l[2] and l[2] ~= "") and l[2] or "unknown"
                commit_message = (l[3] and l[3] ~= "") and l[3] or "no commit message"
            end
            local branch = (branch_out and branch_out ~= "") and branch_out or "unknown"
            local detached = (branch == "HEAD")

            -- "git describe" output: <tag>-<distance>-g<short-oid>
            local tag_info = desc_out or ""
            local tag_name, tag_distance, tag_oid = nil, nil, nil
            if tag_info ~= "" then
                tag_name, tag_distance, tag_oid = tag_info:match("^(.-)%-(%d+)%-g(%x+)$")
                if not tag_name then
                    tag_name, tag_distance, tag_oid = tag_info, 0, abbrev
                end
            end

            cache = {
                root = root,
                head = {
                    branch = branch,
                    abbrev = abbrev,
                    oid = oid,
                    commit_message = commit_message,
                    detached = detached,
                    tag = { name = tag_name, distance = tonumber(tag_distance), oid = tag_oid },
                },
            }
            -- Signal the chrome statusline to invalidate its git/hunks cache (heirline-style: an event drives
            -- the re-eval). The poller's own redrawstatus then repaints from the now-fresh data.
            pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LvimUiChromeGit", modeline = false })
        end)
    end
    git_async(root, { "log", "-1", "--format=%h%n%H%n%s" }, function(o)
        log_out = o
        done()
    end)
    git_async(root, { "rev-parse", "--abbrev-ref", "HEAD" }, function(o)
        branch_out = o
        done()
    end)
    git_async(root, { "describe", "--tags", "--long", "--always" }, function(o)
        desc_out = o
        done()
    end)
end

--- Start (or restart) the poller for the cwd — resolving the repo root ASYNCHRONOUSLY. Clears the cache +
--- stops the pollers outside a repo; otherwise refreshes and watches BOTH `.git/HEAD` and `.git/logs/HEAD`,
--- updating only on mtime change.
---@param interval? integer  poll interval in ms (default 1000)
function M.start(interval)
    -- A rapid DirChanged can spawn two `rev-parse` jobs; their callback order is not guaranteed, so a stale
    -- cwd's callback could otherwise install a poller for the OLD root. Tag this start with a generation and
    -- bail from any scheduled callback once a newer start has run.
    start_gen = start_gen + 1
    local gen = start_gen
    local ok = pcall(vim.system, { "git", "rev-parse", "--show-toplevel" }, { text = true }, function(res)
        local root = (res.code == 0 and type(res.stdout) == "string") and vim.trim(res.stdout) or nil
        vim.schedule(function()
            if gen ~= start_gen then
                return
            end
            if not root or root == "" then
                cache = nil
                stop_pollers()
                return
            end

            M.update(root)
            stop_pollers()

            -- Watch `.git/HEAD` (rewritten ONLY on checkout / detach) AND `.git/logs/HEAD` (the reflog —
            -- appended on EVERY HEAD movement incl. commits, resets, amends), so the abbrev / oid / subject /
            -- tag-distance refresh after a commit, not only after the next branch switch. Same callback; a repo
            -- with the reflog disabled simply never fires the second poll (and a fresh repo's missing reflog
            -- reports an err, which is ignored until the file appears).
            local function on_change(err, prev, now)
                if err then
                    return
                end
                if prev and now and prev.mtime.sec ~= now.mtime.sec then
                    vim.schedule(function()
                        if gen ~= start_gen then
                            return
                        end
                        M.update(root)
                        pcall(vim.cmd, "redrawstatus")
                    end)
                end
            end
            for _, path in ipairs({ root .. "/.git/HEAD", root .. "/.git/logs/HEAD" }) do
                local p = uv.new_fs_poll()
                if p then
                    p:start(path, interval or 1000, on_change)
                    pollers[#pollers + 1] = p
                end
            end
        end)
    end)
    if not ok then
        cache = nil
    end
end

return M
