-- `print` is a global the whole editor shares.
--
-- notify.override_print is on by DEFAULT, and the first version replaced `print` without keeping
-- the editor's own. The option could therefore be switched on but never off: a later
-- setup({ override_print = false }) left the replacement in place for the rest of the session, and
-- nothing could reach the real print again.

local notify = require("lvim-hud.notify")

--- Run `fn` with no override in place to begin with, and whatever `print` was before restored
--- afterwards. The baseline spec calls setup() first and the option is ON by default, so a case
--- that assumed a pristine global would be comparing one override against another — which is how
--- this helper got written wrong the first time.
---@param fn fun()
local function with_print(fn)
    local saved = print
    notify.setup({ override_print = false, ext_messages = false })
    local ok, err = pcall(fn)
    notify.setup({ override_print = false, ext_messages = false })
    print = saved
    if not ok then
        error(err, 0)
    end
end

describe("lvim-hud.notify: the print override")

it("replaces print when asked", function()
    with_print(function()
        local original = print
        notify.setup({ override_print = true, ext_messages = false })
        truthy(print ~= original, "print should have been replaced")
    end)
end)

it("hands the editor its own print back when turned off", function()
    with_print(function()
        local original = print
        notify.setup({ override_print = true, ext_messages = false })
        notify.setup({ override_print = false, ext_messages = false })
        eq(original, print, "print must be the editor's own again")
    end)
end)

it("does not nest one override inside another", function()
    with_print(function()
        local original = print
        notify.setup({ override_print = true, ext_messages = false })
        local first = print
        notify.setup({ override_print = true, ext_messages = false })
        truthy(print ~= original, "still overridden")
        notify.setup({ override_print = false, ext_messages = false })
        eq(original, print, "one restore is enough however many times it was set")
        truthy(first ~= original, "the first override was not the original")
    end)
end)
