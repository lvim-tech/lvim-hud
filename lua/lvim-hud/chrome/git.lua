-- lvim-hud.chrome.git: a background git-HEAD poller for the chrome statusline / tabline.
--
-- Reads branch + abbreviated SHA + full OID + last commit subject + tag info via the git CLI, caches the
-- result, and refreshes it through a libuv fs_poll watching `<root>/.git/HEAD` — so the statusline reads
-- git data SYNCHRONOUSLY without ever blocking the UI. One shared instance; started on VimEnter / DirChanged.
-- Ported 1:1 from the user's heirline git poller (`_G.LVIM.git` → a module-local cache).
--
---@module "lvim-hud.chrome.git"

local uv = vim.uv or vim.loop

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
---@type uv.uv_fs_poll_t?
local poller = nil

--- The cached git status, or nil when the cwd is not inside a git repository.
---@return { root: string, head: LvimChromeGitHead }?
function M.get()
    return cache
end

--- Run a shell command and return its single trimmed line, or nil on empty / git error output.
---@param cmd string
---@return string?
local function safe(cmd)
    local result = vim.fn.system(cmd .. " 2>/dev/null")
    if type(result) == "string" and result ~= "" then
        result = result:gsub("\n$", "")
        if result:match("^(fatal:|error:)") then
            return nil
        end
        return result
    end
    return nil
end

--- The path to `.git/HEAD` and the repository root for the cwd, or nil when not in a repo.
---@return string?  head_path
---@return string?  root
local function head_path()
    local root = safe("git rev-parse --show-toplevel")
    if root and root ~= "" then
        return root .. "/.git/HEAD", root
    end
    return nil
end

--- Query git for branch / commit / tag info and write it to the cache.
---@param root string
function M.update(root)
    local branch = safe("git rev-parse --abbrev-ref HEAD") or "unknown"
    local detached = (branch == "HEAD")
    local abbrev = safe("git rev-parse --short HEAD") or "unknown"
    local oid = safe("git rev-parse HEAD") or "unknown"
    local commit_message = safe("git log -1 --pretty=%s") or "no commit message"

    -- "git describe" output: <tag>-<distance>-g<short-oid>
    local tag_info = safe("git describe --tags --long --always") or ""
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
    -- Signal the chrome statusline to invalidate its git/hunks cache (heirline-style: an event drives the
    -- re-eval). The poller's own redrawstatus then repaints from the now-fresh data.
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LvimUiChromeGit", modeline = false })
end

--- Start (or restart) the poller for the cwd. Clears the cache + stops the poller outside a repo; otherwise
--- updates immediately and watches `.git/HEAD`, refreshing only when its mtime changes.
---@param interval? integer  poll interval in ms (default 1000)
function M.start(interval)
    local path, root = head_path()
    if not path or not root then
        cache = nil
        if poller then
            poller:stop()
            poller:close()
            poller = nil
        end
        return
    end

    M.update(root)

    if poller then
        poller:stop()
        poller:close()
        poller = nil
    end

    poller = uv.new_fs_poll()
    poller:start(path, interval or 1000, function(err, prev, now)
        if err then
            return
        end
        if prev and now and prev.mtime.sec ~= now.mtime.sec then
            vim.schedule(function()
                M.update(root)
                pcall(vim.cmd, "redrawstatus")
            end)
        end
    end)
end

return M
