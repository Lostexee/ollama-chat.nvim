-- lua/ollama-chat/window.lua
-- Fenster-Management: Chat-Fenster erstellen, Focus toggling

local M_ref = nil

local M = {}

function M.init(main)
  M_ref = main
end

function M.save_last_working_window()
  local api = vim.api
  local current_win = api.nvim_get_current_win()
  if current_win ~= M_ref.state.chat_win and current_win ~= M_ref.state.input_win then
    M_ref.state.last_working_win = current_win
  end
end

function M.toggle_focus()
  local api = vim.api
  local current_win = api.nvim_get_current_win()
  if current_win == M_ref.state.chat_win or current_win == M_ref.state.input_win then
    if M_ref.state.last_working_win and api.nvim_win_is_valid(M_ref.state.last_working_win) then
      api.nvim_set_current_win(M_ref.state.last_working_win)
    else
      local wins = api.nvim_list_wins()
      for _, win in ipairs(wins) do
        if win ~= M_ref.state.chat_win and win ~= M_ref.state.input_win then
          api.nvim_set_current_win(win)
          M_ref.state.last_working_win = win
          return
        end
      end
      vim.notify("Kein Arbeitsfenster gefunden!", vim.log.levels.WARN)
    end
  else
    M.save_last_working_window()
    if M_ref.state.input_win and api.nvim_win_is_valid(M_ref.state.input_win) then
      api.nvim_set_current_win(M_ref.state.input_win)
      vim.cmd('startinsert')
    end
  end
end

function M.create_chat_window()
  local api = vim.api
  M.save_last_working_window()

  if not M_ref.state.chat_buf or not api.nvim_buf_is_valid(M_ref.state.chat_buf) then
    M_ref.state.chat_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(M_ref.state.chat_buf, 'buftype', 'nofile')
    api.nvim_buf_set_option(M_ref.state.chat_buf, 'swapfile', false)
    api.nvim_buf_set_option(M_ref.state.chat_buf, 'filetype', 'markdown')
    api.nvim_buf_set_name(M_ref.state.chat_buf, 'Ollama Chat')
  end

  if not M_ref.state.input_buf or not api.nvim_buf_is_valid(M_ref.state.input_buf) then
    M_ref.state.input_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(M_ref.state.input_buf, 'buftype', 'nofile')
    api.nvim_buf_set_option(M_ref.state.input_buf, 'swapfile', false)
  end

  local width = M_ref.config.window_width
  local height = M_ref.config.window_height
  local chat_height = math.floor(height * 0.7)
  local input_height = height - chat_height - 1
  local col = api.nvim_get_option("columns") - width - 2
  local row = 1

  local chat_opts = {
    relative = 'editor', width = width, height = chat_height,
    col = col, row = row, style = 'minimal', border = 'rounded',
    title = string.format(' Ollama: %s ', M_ref.state.current_model or 'No Model'),
    title_pos = 'center',
  }
  M_ref.state.chat_win = api.nvim_open_win(M_ref.state.chat_buf, false, chat_opts)
  api.nvim_win_set_option(M_ref.state.chat_win, 'wrap', true)

  local input_opts = {
    relative = 'editor', width = width, height = input_height,
    col = col, row = row + chat_height + 1, style = 'minimal', border = 'rounded',
    title = ' Input (C-s:Send Tab:Switch C-m:Model C-a:Attach C-d:Detach) ',
    title_pos = 'center',
  }
  M_ref.state.input_win = api.nvim_open_win(M_ref.state.input_buf, true, input_opts)

  -- *** FIX: Verhindere dass :e/:edit/:vs/:sp Befehle im Input-Fenster ausgeführt werden ***
  -- winfixbuf (Neovim >= 0.10) verhindert Buffer-Wechsel auf API-Ebene
  pcall(api.nvim_win_set_option, M_ref.state.input_win, 'winfixbuf', true)

  -- CmdlineLeave: Fängt :e, :edit, :vs, :sp ab wenn sie im Input-Fenster getippt werden
  -- Wir speichern den Befehl und führen ihn im Working-Fenster aus
  api.nvim_create_autocmd("CmdlineLeave", {
    callback = function()
      -- Nur wenn wir im Input-Fenster sind
      if not M_ref.state.input_win or not api.nvim_win_is_valid(M_ref.state.input_win) then return end
      if api.nvim_get_current_win() ~= M_ref.state.input_win then return end

      -- Befehl aus Cmdline auslesen
      local cmdline = vim.fn.getcmdline()
      local cmdtype = vim.fn.getcmdtype()
      if cmdtype ~= ":" then return end

      -- Prüfen ob es ein Datei-Öffnen-Befehl ist
      local file_cmds = {"^e%s+", "^edit%s+", "^vs%s*", "^vsp%s+", "^vsplit%s+",
                         "^sp%s+", "^split%s+", "^tabe%s+", "^tabedit%s+"}
      local is_file_cmd = false
      local filepath = nil

      for _, pat in ipairs(file_cmds) do
        local match = cmdline:match(pat .. "(.*)")
        if match then
          is_file_cmd = true
          filepath = match ~= "" and match or nil
          break
        end
        -- Auch ohne Dateiname (z.B. :e allein)
        if cmdline:match("^" .. pat:gsub("%s%+$", "%s*$"):gsub("%s%+", "%s*")) then
          is_file_cmd = true
          break
        end
      end

      if not is_file_cmd then return end

      -- Befehl merken und nach CmdlineLeave im richtigen Fenster ausführen
      local saved_cmd = cmdline
      vim.schedule(function()
        -- Input-Buffer sicherstellen
        if M_ref.state.input_win and api.nvim_win_is_valid(M_ref.state.input_win) then
          pcall(api.nvim_win_set_buf, M_ref.state.input_win, M_ref.state.input_buf)
        end

        -- Zum Working-Fenster wechseln
        local target_win = M_ref.state.last_working_win
        if not target_win or not api.nvim_win_is_valid(target_win) then
          for _, win in ipairs(api.nvim_list_wins()) do
            if win ~= M_ref.state.input_win and win ~= M_ref.state.chat_win then
              target_win = win
              M_ref.state.last_working_win = win
              break
            end
          end
        end

        if target_win and api.nvim_win_is_valid(target_win) then
          api.nvim_set_current_win(target_win)
          -- Befehl im richtigen Fenster ausführen
          local ok, err = pcall(vim.cmd, saved_cmd)
          if not ok then
            vim.notify("Fehler beim Öffnen: " .. tostring(err), vim.log.levels.WARN)
          end
        end
      end)
    end,
    desc = "Redirect file-open commands from input window to working window"
  })

  -- BufEnter als zusätzlicher Schutz: falls doch ein Buffer reinrutscht
  api.nvim_create_autocmd("BufEnter", {
    callback = function(ev)
      if not M_ref.state.input_win or not api.nvim_win_is_valid(M_ref.state.input_win) then return end
      if api.nvim_get_current_win() ~= M_ref.state.input_win then return end
      local buf = ev.buf
      if buf == M_ref.state.input_buf or buf == M_ref.state.chat_buf then return end
      -- Sofort zurücksetzen
      pcall(api.nvim_win_set_buf, M_ref.state.input_win, M_ref.state.input_buf)
    end,
    desc = "Fallback: restore input buffer if displaced"
  })

  -- Auto-Insert beim Betreten des Input-Fensters
  api.nvim_create_autocmd("WinEnter", {
    buffer = M_ref.state.input_buf,
    callback = function()
      if api.nvim_get_current_win() == M_ref.state.input_win then
        vim.cmd('startinsert')
      end
    end
  })

  -- Keybindings
  local opts = { noremap = true, silent = true, buffer = M_ref.state.input_buf }

  vim.keymap.set('i', '<C-s>', function() M_ref.send_message() end, opts)
  vim.keymap.set('n', '<C-s>', function() M_ref.send_message() end, opts)
  vim.keymap.set('i', '<M-CR>', function() M_ref.send_message() end, opts)
  vim.keymap.set('n', '<M-CR>', function() M_ref.send_message() end, opts)
  vim.keymap.set('n', '<CR>', function() M_ref.send_message() end, opts)

  vim.keymap.set('n', '<Tab>', function() M_ref.toggle_focus() end, opts)
  -- Im Insert Mode: Tab nur für toggle wenn Zeile leer
  vim.keymap.set('i', '<Tab>', function()
    local line = api.nvim_get_current_line()
    if line:match("^%s*$") then
      M_ref.toggle_focus()
    else
      local keys = api.nvim_replace_termcodes('<Tab>', true, false, true)
      api.nvim_feedkeys(keys, 'n', false)
    end
  end, opts)

  vim.keymap.set('i', '<C-m>', function() M_ref.select_model() end, opts)
  vim.keymap.set('n', '<C-m>', function() M_ref.select_model() end, opts)
  vim.keymap.set('i', '<C-a>', function() M_ref.attach_current_file() end, opts)
  vim.keymap.set('n', '<C-a>', function() M_ref.attach_current_file() end, opts)
  vim.keymap.set('i', '<C-d>', function() M_ref.detach_file() end, opts)
  vim.keymap.set('n', '<C-d>', function() M_ref.detach_file() end, opts)
  vim.keymap.set('n', 'q', function() M_ref.close() end, opts)

  M_ref.update_attached_files_display()
end

return M
