-- lua/ollama-chat/models.lua
-- Modelle laden und auswählen

local M_ref = nil  -- Referenz auf das Haupt-M aus init.lua

local M = {}

function M.init(main)
  M_ref = main
end

function M.load_models()
  local http = require("ollama-chat.http")
  local url = string.format("http://%s/api/tags", M_ref.config.host)
  http.request_async(url, "GET", nil, function(response, err)
    if err then
      vim.notify("Fehler beim Laden der Modelle: " .. err, vim.log.levels.ERROR)
      return
    end
    if response and response.models then
      M_ref.state.models = {}
      for _, model in ipairs(response.models) do
        table.insert(M_ref.state.models, model.name)
      end
      if #M_ref.state.models > 0 and not M_ref.state.current_model then
        M_ref.state.current_model = M_ref.state.models[1]
      end
      vim.notify(string.format("✓ %d Modelle geladen", #M_ref.state.models), vim.log.levels.INFO)
    end
  end)
end

function M.select_model()
  if #M_ref.state.models == 0 then
    vim.notify("Keine Modelle gefunden!", vim.log.levels.ERROR)
    return
  end
  local api = vim.api
  local items = { "Wähle ein Modell:" }
  for i, name in ipairs(M_ref.state.models) do
    table.insert(items, string.format("%d. %s", i, name))
  end
  local choice = vim.fn.inputlist(items)
  if choice >= 1 and choice <= #M_ref.state.models then
    local selected = M_ref.state.models[choice]
    M_ref.state.current_model = selected
    M_ref.state.chat_history = {}
    vim.notify(string.format("Modell gewechselt: %s", selected), vim.log.levels.INFO)
    M_ref.update_attached_files_display()
    if M_ref.state.chat_win and api.nvim_win_is_valid(M_ref.state.chat_win) then
      api.nvim_win_set_config(M_ref.state.chat_win, {
        title = string.format(' Ollama: %s ', selected),
      })
    end
  end
end

return M
