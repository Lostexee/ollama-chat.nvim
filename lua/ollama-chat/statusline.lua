-- lua/ollama-chat/statusline.lua
-- Statuszeilen-Integration
--
-- Gibt Infos über den aktuellen Plugin-Zustand zurück:
--   - Aktives Modell
--   - Angehängte Dateien
--   - Completion-Status
--   - Streaming-Status
--
-- VERWENDUNG MIT LUALINE:
--   local sl = require("ollama-chat.statusline")
--   require("lualine").setup({
--     sections = {
--       lualine_x = {
--         { sl.full },
--       },
--     },
--   })
--
-- VERWENDUNG MIT HEIRLINE:
--   { provider = function() return require("ollama-chat.statusline").full() end }
--
-- EIGENE STATUSZEILE:
--   set statusline+=%{v:lua.require('ollama-chat.statusline').full()}

local M_ref = nil

local M = {}

function M.init(main)
  M_ref = main
end

-- Aktives Modell
function M.model()
  if not M_ref or not M_ref.state.current_model then return "" end
  return string.format("🤖 %s", M_ref.state.current_model)
end

-- Streaming-Indikator
function M.streaming()
  if not M_ref or not M_ref.state.is_streaming then return "" end
  return "⏳"
end

-- Angehängte Dateien
function M.attached_files()
  if not M_ref or #M_ref.state.attached_files == 0 then return "" end
  if #M_ref.state.attached_files == 1 then
    return string.format("📎 %s", M_ref.state.attached_files[1].name)
  end
  return string.format("📎 %d Dateien", #M_ref.state.attached_files)
end

-- Completion-Status
function M.completion()
  if not M_ref then return "" end
  if M_ref.state.completion_running then return "✏️ ..." end
  return ""
end

-- Alles zusammen
function M.full()
  if not M_ref then return "" end
  local parts = {}

  local streaming = M.streaming()
  if streaming ~= "" then table.insert(parts, streaming) end

  local model = M.model()
  if model ~= "" then table.insert(parts, model) end

  local files = M.attached_files()
  if files ~= "" then table.insert(parts, files) end

  local comp = M.completion()
  if comp ~= "" then table.insert(parts, comp) end

  return table.concat(parts, " │ ")
end

return M
