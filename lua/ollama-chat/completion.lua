-- lua/ollama-chat/completion.lua
-- Code Completion via Ollama

local M_ref = nil

local M = {}

function M.init(main)
  M_ref = main
end

local function show_completion_status(msg)
  if not M_ref.config.completion_debug then return end
  pcall(vim.api.nvim_echo, {{msg, "WarningMsg"}}, true, {})
end

local function get_comp_ns()
  return vim.api.nvim_create_namespace('ollama_completion')
end

local function clear_completion(buf)
  vim.api.nvim_buf_clear_namespace(buf or 0, get_comp_ns(), 0, -1)
  if buf and M_ref.state.pending_completions then
    M_ref.state.pending_completions[buf] = nil
  end
end

function M.setup_completion()
  local api = vim.api
  vim.api.nvim_set_hl(0, 'OllamaCompletion', { link = 'Comment' })

  local group = api.nvim_create_augroup('OllamaCompletion', { clear = true })

  api.nvim_create_autocmd({'TextChangedI'}, {
    group = group,
    callback = function()
      local buf = api.nvim_get_current_buf()
      clear_completion(buf)
      M_ref.state.completion_running = false
      M_ref.state.active_requests.completion = nil
      if M_ref.state.completion_timer then
        vim.fn.timer_stop(M_ref.state.completion_timer)
        M_ref.state.completion_timer = nil
      end
      M_ref.state.completion_timer = vim.fn.timer_start(M_ref.config.completion_delay, function()
        vim.schedule(function() M.trigger_completion() end)
      end)
    end
  })

  api.nvim_create_autocmd({'CursorMovedI'}, {
    group = group,
    callback = function()
      local buf = api.nvim_get_current_buf()
      local comp = M_ref.state.pending_completions and M_ref.state.pending_completions[buf]
      if comp and api.nvim_win_get_cursor(0)[1] ~= comp.row then
        clear_completion(buf)
      end
    end
  })

  api.nvim_create_autocmd({'InsertLeave'}, {
    group = group,
    callback = function()
      local buf = api.nvim_get_current_buf()
      clear_completion(buf)
      if M_ref.state.completion_timer then
        vim.fn.timer_stop(M_ref.state.completion_timer)
        M_ref.state.completion_timer = nil
      end
      M_ref.state.completion_running = false
      M_ref.state.active_requests.completion = nil
    end
  })

  vim.notify("✓ Code Completion aktiviert (Tab: übernehmen)", vim.log.levels.INFO)
end

function M.trigger_completion()
  local api = vim.api
  local uv = vim.loop
  local buf = api.nvim_get_current_buf()
  local cursor = api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]

  if api.nvim_get_mode().mode ~= 'i' then return end
  if buf == M_ref.state.chat_buf or buf == M_ref.state.input_buf then return end
  if col < M_ref.config.completion_min_chars then return end

  local context_lines = api.nvim_buf_get_lines(buf, math.max(0, row - 20), row, false)
  local context = table.concat(context_lines, "\n")
  local current_line = api.nvim_get_current_line()
  local prefix = current_line:sub(1, col)
  local suffix = current_line:sub(col + 1)

  if prefix:match("^%s*$") or #prefix < M_ref.config.completion_min_chars then return end
  if M_ref.state.pending_completions and M_ref.state.pending_completions[buf] then return end
  if M_ref.state.completion_running then return end

  M_ref.state.completion_running = true
  show_completion_status("⏳ Completion läuft...")

  local is_multi = M_ref.config.completion_mode == "multi"
  local request_id = tostring(uv.hrtime())
  M_ref.state.active_requests.completion = request_id

  local http = require("ollama-chat.http")
  local url = string.format("http://%s/api/generate", M_ref.config.host)

  -- System-Prompt: Completion-spezifische Anweisungen werden dem
  -- prompt_manager-Prompt vorangestellt, damit auch grosse Modelle
  -- nur rohen Code ausgeben und nicht erklaeren.
  local filetype = vim.bo[buf].filetype or "code"
  local pm = require("ollama-chat.prompt_manager")
  local base_system = pm.get(M_ref.state.current_model)
  local system = base_system .. "\n\n" ..
    "COMPLETION MODE: " ..
    "You are now acting as a code completion engine. " ..
    "Output ONLY the raw code that comes directly after the cursor. " ..
    "NEVER write prose, explanations, comments, or markdown fences. " ..
    "NEVER repeat code that is already written. " ..
    "Output ONLY the missing code tokens, nothing else."

  local body = {
    model = M_ref.state.current_model,
    system = system,
    prompt = context .. prefix,
    stream = false,
    options = {
      temperature = 0.1,
      top_p = 0.9,
      top_k = 40,
      num_predict = is_multi and 100 or 50,
      stop = is_multi and {"\n\n", "```"} or {"\n", "```"},
      repeat_penalty = 1.15,
    }
  }

  http.request_async(url, "POST", body, function(response, err)
    M_ref.state.completion_running = false
    if M_ref.state.active_requests.completion ~= request_id then return end
    M_ref.state.active_requests.completion = nil

    if err then
      show_completion_status("❌ Fehler: " .. err)
      return
    end

    local completion = response and response.response or ""
    if completion == "" then
      show_completion_status("❌ Keine Antwort vom Server")
      return
    end

    -- Führende Wiederholung des Prefix entfernen
    -- (manche Modelle wiederholen den Kontext)
    if completion:sub(1, #prefix) == prefix then
      completion = completion:sub(#prefix + 1)
    end

    -- Cleanup: Markdown entfernen
    local inner = completion:match("^```[%w]*%s*\n(.-)\n?```%s*$")
    if inner then completion = inner end
    completion = completion:gsub("^```[%w]*%s*\n?", "")
    completion = completion:gsub("\n?```%s*$", "")
    completion = completion:gsub("^%s+", "")

    if completion == "" then
      show_completion_status("⚠️ Completion leer nach Bereinigung")
      return
    end

    -- Zeilen parsen
    local max_lines = is_multi and 5 or 1
    local lines = {}
    for line in (completion .. "\n"):gmatch("([^\n]*)\n") do
      if line == "" and #lines > 0 and lines[#lines] == "" then break end
      table.insert(lines, line)
      if #lines >= max_lines then break end
    end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end

    if #lines == 0 then
      show_completion_status("⚠️ Completion leer")
      return
    end

    -- Prüfen ob Buffer/Mode noch stimmt
    if not api.nvim_buf_is_valid(buf) then return end
    if api.nvim_win_get_cursor(0)[1] ~= row then return end
    if api.nvim_get_mode().mode ~= 'i' then return end
    if M_ref.state.pending_completions and M_ref.state.pending_completions[buf] then return end

    -- Virtual Text anzeigen
    local ns_id = get_comp_ns()
    api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

    local virt_lines = {}
    if is_multi then
      local indent = prefix:match("^(%s*)") or ""
      for i = 2, #lines do
        table.insert(virt_lines, {{indent .. lines[i], 'OllamaCompletion'}})
      end
    end

    local ok = pcall(api.nvim_buf_set_extmark, buf, ns_id, row - 1, col, {
      virt_text = {{lines[1], 'OllamaCompletion'}},
      virt_text_pos = 'overlay',
      virt_lines = #virt_lines > 0 and virt_lines or nil,
      hl_mode = 'combine',
    })

    if not ok then
      show_completion_status("❌ Fehler beim Anzeigen")
      return
    end

    if not M_ref.state.pending_completions then M_ref.state.pending_completions = {} end
    M_ref.state.pending_completions[buf] = { lines = lines, row = row, col = col }

    local info = (#lines > 1) and (#lines .. " Zeilen") or "1 Zeile"
    show_completion_status("✅ Completion bereit (" .. info .. ") – Tab: übernehmen, Esc: verwerfen")

    -- Tab-Handler registrieren (nur einmal pro Buffer)
    local maps = api.nvim_buf_get_keymap(buf, 'i')
    for _, m in ipairs(maps) do
      if (m.lhs == '<Tab>' or m.lhs == '\t') and m.desc == 'ollama_accept' then return end
    end

    vim.keymap.set('i', '<Tab>', function()
      local cbuf = api.nvim_get_current_buf()
      local comp = M_ref.state.pending_completions and M_ref.state.pending_completions[cbuf]
      if comp and api.nvim_win_get_cursor(0)[1] == comp.row then
        M_ref.state.pending_completions[cbuf] = nil
        api.nvim_buf_clear_namespace(cbuf, get_comp_ns(), 0, -1)
        local cur_line = api.nvim_get_current_line()
        if #comp.lines == 1 then
          api.nvim_set_current_line(cur_line:sub(1, comp.col) .. comp.lines[1] .. cur_line:sub(comp.col + 1))
          api.nvim_win_set_cursor(0, {comp.row, comp.col + #comp.lines[1]})
        else
          local all = {cur_line:sub(1, comp.col) .. comp.lines[1]}
          for i = 2, #comp.lines - 1 do table.insert(all, comp.lines[i]) end
          table.insert(all, comp.lines[#comp.lines] .. cur_line:sub(comp.col + 1))
          api.nvim_buf_set_lines(cbuf, comp.row - 1, comp.row, false, all)
          api.nvim_win_set_cursor(0, {comp.row + #comp.lines - 1, #comp.lines[#comp.lines]})
        end
        return
      end
      if comp then clear_completion(cbuf) end
      api.nvim_feedkeys(api.nvim_replace_termcodes('<Tab>', true, false, true), 'n', false)
    end, { buffer = buf, noremap = true, silent = true, desc = 'ollama_accept' })

    vim.keymap.set('i', '<Esc>', function()
      local cbuf = api.nvim_get_current_buf()
      clear_completion(cbuf)
      api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
    end, { buffer = buf, noremap = true, silent = true, desc = 'ollama_cancel' })
  end)
end

function M.disable_completion()
  local api = vim.api
  api.nvim_clear_autocmds({ group = 'OllamaCompletion' })
  local ns_id = get_comp_ns()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(b) then api.nvim_buf_clear_namespace(b, ns_id, 0, -1) end
  end
  M_ref.state.pending_completions = {}
  M_ref.state.completion_running = false
  M_ref.state.active_requests.completion = nil
  if M_ref.state.completion_timer then
    vim.fn.timer_stop(M_ref.state.completion_timer)
    M_ref.state.completion_timer = nil
  end
  vim.notify("✓ Code Completion deaktiviert", vim.log.levels.INFO)
end

return M
