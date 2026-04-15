-- lua/ollama-chat/attach.lua
-- Dateien anhängen und entfernen

local M_ref = nil

local M = {}

function M.init(main)
  M_ref = main
end

function M.attach_file(filepath)
  local api = vim.api
  if not filepath then filepath = api.nvim_buf_get_name(0) end
  if filepath == "" then
    vim.notify("Keine Datei zum Anhängen!", vim.log.levels.WARN)
    return
  end
  for _, file in ipairs(M_ref.state.attached_files) do
    if file.path == filepath then
      vim.notify("Datei bereits angehängt!", vim.log.levels.WARN)
      return
    end
  end
  local lines = {}
  local file = io.open(filepath, "r")
  if file then
    for line in file:lines() do table.insert(lines, line) end
    file:close()
  else
    vim.notify("Fehler beim Lesen der Datei!", vim.log.levels.ERROR)
    return
  end
  local content = table.concat(lines, "\n")
  local filename = vim.fn.fnamemodify(filepath, ":t")
  table.insert(M_ref.state.attached_files, {
    path = filepath, name = filename,
    content = content, original_content = content,
  })
  vim.notify(string.format("📎 Datei angehängt: %s", filename), vim.log.levels.INFO)
  M_ref.update_attached_files_display()
end

function M.detach_file(index)
  if not index then
    if #M_ref.state.attached_files == 0 then
      vim.notify("Keine angehängten Dateien!", vim.log.levels.WARN)
      return
    end
    local items = { "Datei entfernen:" }
    for i, file in ipairs(M_ref.state.attached_files) do
      table.insert(items, string.format("%d. %s", i, file.name))
    end
    local choice = vim.fn.inputlist(items)
    if choice >= 1 and choice <= #M_ref.state.attached_files then
      local removed = table.remove(M_ref.state.attached_files, choice)
      vim.notify(string.format("Datei entfernt: %s", removed.name), vim.log.levels.INFO)
      M_ref.update_attached_files_display()
    end
  else
    if index > 0 and index <= #M_ref.state.attached_files then
      local removed = table.remove(M_ref.state.attached_files, index)
      vim.notify(string.format("Datei entfernt: %s", removed.name), vim.log.levels.INFO)
      M_ref.update_attached_files_display()
    end
  end
end

function M.update_attached_files_display()
  local api = vim.api
  if not M_ref.state.chat_buf or not api.nvim_buf_is_valid(M_ref.state.chat_buf) then return end
  local lines = api.nvim_buf_get_lines(M_ref.state.chat_buf, 0, -1, false)
  local start_idx = 0
  for i, line in ipairs(lines) do
    if line:match("^═+$") then start_idx = i; break end
  end
  local new_lines = {
    string.format("Chat mit %s", M_ref.state.current_model or "No Model"),
    "════════════════════════════════════════════════",
  }
  if #M_ref.state.attached_files > 0 then
    table.insert(new_lines, "")
    table.insert(new_lines, "📎 Angehängte Dateien:")
    for i, file in ipairs(M_ref.state.attached_files) do
      table.insert(new_lines, string.format("  %d. %s", i, file.name))
    end
    table.insert(new_lines, "")
    table.insert(new_lines, "════════════════════════════════════════════════")
  end
  table.insert(new_lines, "")
  if start_idx > 0 then
    for i = start_idx + 1, #lines do table.insert(new_lines, lines[i]) end
  end
  api.nvim_buf_set_lines(M_ref.state.chat_buf, 0, -1, false, new_lines)
end

function M.attach_current_file()
  local api = vim.api
  local function save_last_working_window()
    local current_win = api.nvim_get_current_win()
    if current_win ~= M_ref.state.chat_win and current_win ~= M_ref.state.input_win then
      M_ref.state.last_working_win = current_win
    end
  end
  save_last_working_window()
  local current_win = api.nvim_get_current_win()
  if current_win == M_ref.state.input_win or current_win == M_ref.state.chat_win then
    if M_ref.state.last_working_win and api.nvim_win_is_valid(M_ref.state.last_working_win) then
      api.nvim_set_current_win(M_ref.state.last_working_win)
    else
      vim.cmd('wincmd p')
    end
  end
  local filepath = api.nvim_buf_get_name(0)
  if filepath ~= "" then
    M.attach_file(filepath)
  else
    vim.notify("Keine Datei im aktuellen Buffer!", vim.log.levels.WARN)
  end
  if M_ref.state.input_win and api.nvim_win_is_valid(M_ref.state.input_win) then
    api.nvim_set_current_win(M_ref.state.input_win)
  end
end

return M
