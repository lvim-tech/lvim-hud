-- lvim-hud.overlay: the PUBLIC path for the transient finder/echo statusline overlay. The implementation
-- lives in the (internal) chrome submodule as `lvim-hud.chrome.overlay`; this thin re-export gives the
-- cross-plugin consumers (lvim-ui / lvim-picker / lvim-msgarea — which publish a title + match counter to
-- the bottom line) one stable public path, `require("lvim-hud.overlay")`, without reaching into chrome.
--
---@module "lvim-hud.overlay"

return require("lvim-hud.chrome.overlay")
