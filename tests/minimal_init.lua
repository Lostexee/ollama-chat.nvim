-- tests/minimal_init.lua
-- Setzt runtimepath und sourct plenary, damit PlenaryBustedDirectory verfügbar ist.
-- Wird über: nvim --headless -u tests/minimal_init.lua aufgerufen.

-- Plugin-Root (lua/ liegt hier → require("ollama-chat.tools.*") funktioniert)
vim.opt.rtp:append(".")

-- Plenary finden: lazy → packer → standard pack path
local candidates = {
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"),
}

local plenary_path
for _, p in ipairs(candidates) do
  if vim.fn.isdirectory(p) == 1 then
    plenary_path = p
    break
  end
end

assert(plenary_path,
  "plenary.nvim nicht gefunden! Kandidaten:\n  " .. table.concat(candidates, "\n  "))

vim.opt.rtp:append(plenary_path)

-- Plugin-Dateien sourcen → registriert PlenaryBustedDirectory als Vim-Command
vim.cmd("runtime plugin/plenary.vim")

vim.o.swapfile = false
vim.o.backup   = false
