-- lua/ollama-chat/chat.lua
-- Nachricht senden, Datei-Änderungen erkennen und anwenden

local M_ref = nil

local M = {}

function M.init(main)
  M_ref = main
end

local function append_to_chat(lines)
  local api = vim.api
  if not M_ref.state.chat_buf or not api.nvim_buf_is_valid(M_ref.state.chat_buf) then return end
  if M_ref.state.is_in_diff_mode then return end
  local current_lines = api.nvim_buf_get_lines(M_ref.state.chat_buf, 0, -1, false)
  for _, line in ipairs(lines) do table.insert(current_lines, line) end
  api.nvim_buf_set_lines(M_ref.state.chat_buf, 0, -1, false, current_lines)
  if M_ref.state.chat_win and api.nvim_win_is_valid(M_ref.state.chat_win) then
    api.nvim_win_set_cursor(M_ref.state.chat_win, {#current_lines, 0})
  end
end

function M.send_message()
  local api = vim.api
  if M_ref.state.is_streaming then
    vim.notify("Warte auf Antwort...", vim.log.levels.WARN)
    return
  end

  local lines = api.nvim_buf_get_lines(M_ref.state.input_buf, 0, -1, false)
  local message = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
  if message == "" then return end

  local full_message = message
  if #M_ref.state.attached_files > 0 then
    local context = "\n\n--- Angehängte Dateien ---\n"
    for i, file in ipairs(M_ref.state.attached_files) do
      context = context .. string.format(
        "\n📁 Datei %d: **%s** (Pfad: %s)\n```\n%s\n```\n",
        i, file.name, file.path, file.content
      )
    end
    context = context .. "\n--- Ende der angehängten Dateien ---\n"
    context = context .. "\n⚠️ WICHTIG FÜR CODE-ÄNDERUNGEN:\n"
    context = context .. "1. Schreibe '[Datei X: DATEINAME]' vor den Code-Block\n"
    context = context .. "2. Gib IMMER den KOMPLETTEN Dateiinhalt zurück!\n"
    context = context .. "3. Behalte ALLE bestehenden Funktionen und Code-Teile bei\n"
    context = context .. "4. NIEMALS nur Teilcode oder einzelne Funktionen zurückgeben!\n\n"
    full_message = full_message .. context
  end

  table.insert(M_ref.state.chat_history, { role = "user", content = full_message })

  local display_msg = {message}
  if #M_ref.state.attached_files > 0 then
    table.insert(display_msg, string.format("📎 [mit %d Datei(en)]", #M_ref.state.attached_files))
  end

  append_to_chat({"", "**You:**"})
  for _, line in ipairs(display_msg) do append_to_chat({line}) end
  append_to_chat({"", "**" .. M_ref.state.current_model .. ":** 🔄"})

  api.nvim_buf_set_lines(M_ref.state.input_buf, 0, -1, false, {})

  if M_ref.config.auto_switch_to_file and #M_ref.state.attached_files > 0 then
    if M_ref.state.last_working_win and api.nvim_win_is_valid(M_ref.state.last_working_win) then
      vim.defer_fn(function()
        api.nvim_set_current_win(M_ref.state.last_working_win)
        vim.notify("→ Zur Datei gewechselt (Tab: zurück zum Chat)", vim.log.levels.INFO)
      end, 100)
    end
  end

  M_ref.state.is_streaming = true

  local http = require("ollama-chat.http")
  local pm   = require("ollama-chat.prompt_manager")
  local url  = string.format("http://%s/api/chat", M_ref.config.host)

  -- System-Prompt automatisch anhand des Modells waehlen
  local system_prompt = pm.get(M_ref.state.current_model)
  local messages_with_system = vim.list_extend(
    {{ role = "system", content = system_prompt }},
    vim.deepcopy(M_ref.state.chat_history)
  )

  local body = {
    model    = M_ref.state.current_model,
    messages = messages_with_system,
    stream   = true,
  }

  local response_content = ""

  http.request_stream(url, "POST", body,
    function(chunk)
      if chunk.message and chunk.message.content then
        response_content = response_content .. chunk.message.content
      end
    end,
    function(success, err)
      M_ref.state.is_streaming = false

      if success and response_content ~= "" then
        table.insert(M_ref.state.chat_history, { role = "assistant", content = response_content })

        local chat_lines = api.nvim_buf_get_lines(M_ref.state.chat_buf, 0, -1, false)
        for i = #chat_lines, 1, -1 do
          if chat_lines[i]:match("🔄") then table.remove(chat_lines, i); break end
        end

        local response_lines = vim.split(response_content, "\n")
        for _, line in ipairs(response_lines) do table.insert(chat_lines, line) end
        table.insert(chat_lines, "")
        table.insert(chat_lines, "---")
        table.insert(chat_lines, "")

        api.nvim_buf_set_lines(M_ref.state.chat_buf, 0, -1, false, chat_lines)
        if M_ref.state.chat_win and api.nvim_win_is_valid(M_ref.state.chat_win) then
          api.nvim_win_set_cursor(M_ref.state.chat_win, {#chat_lines, 0})
        end

        M_ref.check_for_file_changes(response_content)
      else
        append_to_chat({"*Fehler: " .. (err or "Unknown") .. "*", "", "---", ""})
      end
    end
  )
end

function M.check_for_file_changes(response)
  if #M_ref.state.attached_files == 0 then return end

  local changes = {}
  for i, file in ipairs(M_ref.state.attached_files) do
    local new_content = nil

    local ok1, r1 = pcall(function()
      return response:match(string.format("%[Datei %d[^%]]*%].-```[^\n]*\n(.-)\n```", i))
    end)
    if ok1 then new_content = r1 end

    if not new_content then
      local escaped = file.name:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
      local ok2, r2 = pcall(function()
        return response:match(escaped .. ".-```[^\n]*\n(.-)\n```")
      end)
      if ok2 then new_content = r2 end
    end

    if not new_content then
      local ok3, r3 = pcall(function()
        for block in response:gmatch("```[^\n]*\n(.-)\n```") do
          if block and #block > 10 then return block end
        end
        return nil
      end)
      if ok3 then new_content = r3 end
    end

    if new_content and new_content ~= file.content and #new_content > 10 then
      local old_lines = vim.split(file.content, "\n")
      local new_lines = vim.split(new_content, "\n")
      local size_ratio = #new_lines / #old_lines

      if size_ratio < 0.5 then
        vim.notify(string.format(
          "⚠️ WARNUNG: Neuer Code für '%s' ist %d%% kürzer! (alt: %d, neu: %d Zeilen)",
          file.name, math.floor((1 - size_ratio) * 100), #old_lines, #new_lines
        ), vim.log.levels.WARN)
      end

      table.insert(changes, { file_index = i, file = file, new_content = new_content, size_ratio = size_ratio })
    end
  end

  if #changes > 0 then
    vim.schedule(function() M_ref.apply_file_changes(changes) end)
  end
end

function M.apply_file_changes(changes)
  local api = vim.api
  if #changes == 0 then return end
  M_ref.state.is_in_diff_mode = true
  vim.notify(string.format("🔄 %d Dateiänderung(en) gefunden!", #changes), vim.log.levels.INFO)

  local function apply_next_change(index)
    if index > #changes then
      vim.notify("✓ Alle Änderungen verarbeitet!", vim.log.levels.INFO)
      M_ref.state.is_in_diff_mode = false
      return
    end

    local change = changes[index]
    local file = change.file
    local old_lines = vim.split(file.content, "\n")
    local new_lines = vim.split(change.new_content, "\n")

    local diff_content = {
      "═══════════════════════════════════════════════════════════",
      string.format("Änderungen für: %s", file.name),
      "═══════════════════════════════════════════════════════════",
      "",
    }

    if change.size_ratio and change.size_ratio < 0.5 then
      table.insert(diff_content, "⚠️⚠️⚠️ WARNUNG: VERDÄCHTIG KLEINER CODE! ⚠️⚠️⚠️")
      table.insert(diff_content, string.format("Neuer Code ist %d%% kürzer!", math.floor((1 - change.size_ratio) * 100)))
      table.insert(diff_content, "")
    end

    table.insert(diff_content, "LEGENDE:  🔴 - = Gelöscht   🟢 + = Hinzugefügt   ⚪ = Unverändert")
    table.insert(diff_content, "BEFEHLE:  :w = Übernehmen   :q! = Verwerfen")
    table.insert(diff_content, "")
    table.insert(diff_content, "═══════════════════════════════════════════════════════════")
    table.insert(diff_content, "")

    local ns_id = api.nvim_create_namespace('ollama_diff')
    local highlights = {}

    local function lines_similar(l1, l2)
      if not l1 or not l2 then return false end
      return l1:gsub("^%s+",""):gsub("%s+$","") == l2:gsub("^%s+",""):gsub("%s+$","")
    end

    local old_line_map = {}
    for i, line in ipairs(old_lines) do
      local t = line:gsub("^%s+",""):gsub("%s+$","")
      if not old_line_map[t] then old_line_map[t] = {} end
      table.insert(old_line_map[t], i)
    end

    local old_matched, new_matched = {}, {}

    local i_old, i_new = 1, 1
    while i_old <= #old_lines and i_new <= #new_lines do
      if lines_similar(old_lines[i_old], new_lines[i_new]) then
        old_matched[i_old] = i_new
        new_matched[i_new] = i_old
        i_old = i_old + 1; i_new = i_new + 1
      else break end
    end

    for i = 1, #new_lines do
      if not new_matched[i] then
        local t = new_lines[i]:gsub("^%s+",""):gsub("%s+$","")
        if old_line_map[t] then
          for _, oi in ipairs(old_line_map[t]) do
            if not old_matched[oi] then
              old_matched[oi] = i; new_matched[i] = oi; break
            end
          end
        end
      end
    end

    i_old, i_new = 1, 1
    while i_old <= #old_lines or i_new <= #new_lines do
      local line_num = #diff_content
      if i_old <= #old_lines and i_new <= #new_lines then
        if old_matched[i_old] == i_new then
          table.insert(diff_content, "  " .. old_lines[i_old])
          table.insert(highlights, {line_num, "Comment"})
          i_old = i_old + 1; i_new = i_new + 1
        elseif old_matched[i_old] and old_matched[i_old] > i_new then
          table.insert(diff_content, "+ " .. new_lines[i_new])
          table.insert(highlights, {line_num, "DiffAdd"})
          i_new = i_new + 1
        elseif new_matched[i_new] and new_matched[i_new] > i_old then
          table.insert(diff_content, "- " .. old_lines[i_old])
          table.insert(highlights, {line_num, "DiffDelete"})
          i_old = i_old + 1
        elseif not old_matched[i_old] and not new_matched[i_new] then
          table.insert(diff_content, "- " .. old_lines[i_old])
          table.insert(highlights, {line_num, "DiffDelete"})
          line_num = line_num + 1
          table.insert(diff_content, "+ " .. new_lines[i_new])
          table.insert(highlights, {line_num, "DiffAdd"})
          i_old = i_old + 1; i_new = i_new + 1
        elseif not old_matched[i_old] then
          table.insert(diff_content, "- " .. old_lines[i_old])
          table.insert(highlights, {line_num, "DiffDelete"})
          i_old = i_old + 1
        else
          table.insert(diff_content, "+ " .. new_lines[i_new])
          table.insert(highlights, {line_num, "DiffAdd"})
          i_new = i_new + 1
        end
      elseif i_old <= #old_lines then
        if not old_matched[i_old] then
          table.insert(diff_content, "- " .. old_lines[i_old])
          table.insert(highlights, {#diff_content, "DiffDelete"})
        end
        i_old = i_old + 1
      else
        if not new_matched[i_new] then
          table.insert(diff_content, "+ " .. new_lines[i_new])
          table.insert(highlights, {#diff_content, "DiffAdd"})
        end
        i_new = i_new + 1
      end
    end

    table.insert(diff_content, "")
    table.insert(diff_content, "═══════════════════════════════════════════════════════════")
    table.insert(diff_content, string.format("Alt: %d Zeilen  →  Neu: %d Zeilen  (%.1f%% der Originalgröße)",
      #old_lines, #new_lines, (change.size_ratio or 1) * 100))
    table.insert(diff_content, "═══════════════════════════════════════════════════════════")

    local tmp_file = string.format("/tmp/ollama_diff_%s_%d.diff",
      file.name:gsub("[^%w]", "_"), os.time())

    local f = io.open(tmp_file, "w")
    if f then f:write(table.concat(diff_content, "\n")); f:close() end

    local original_file_path = file.path
    vim.cmd('tabnew ' .. vim.fn.fnameescape(tmp_file))
    local diff_buf = api.nvim_get_current_buf()

    api.nvim_buf_set_option(diff_buf, 'filetype', 'diff')
    api.nvim_buf_set_option(diff_buf, 'buftype', 'acwrite')
    api.nvim_buf_set_option(diff_buf, 'modifiable', true)

    for _, hl_info in ipairs(highlights) do
      local li = hl_info[1]
      if li >= 0 and li < #diff_content then
        api.nvim_buf_add_highlight(diff_buf, ns_id, hl_info[2], li, 0, -1)
      end
    end
    for i = 0, math.min(10, #diff_content - 1) do
      api.nvim_buf_add_highlight(diff_buf, ns_id, "Title", i, 0, -1)
    end

    api.nvim_create_autocmd("BufWriteCmd", {
      buffer = diff_buf,
      callback = function()
        local target_buf = nil
        for _, buf in ipairs(api.nvim_list_bufs()) do
          if api.nvim_buf_get_name(buf) == file.path then target_buf = buf; break end
        end
        if target_buf then
          api.nvim_buf_set_lines(target_buf, 0, -1, false, new_lines)
          api.nvim_buf_set_option(target_buf, 'modified', true)
          local cb = api.nvim_get_current_buf()
          vim.cmd('buffer ' .. target_buf)
          vim.cmd('write')
          vim.cmd('buffer ' .. cb)
        else
          local fh = io.open(file.path, "w")
          if fh then fh:write(change.new_content); fh:close() end
        end
        file.content = change.new_content
        vim.notify(string.format("✅ Änderungen übernommen: %s", file.name), vim.log.levels.INFO)
        os.remove(tmp_file)
        vim.cmd('bdelete!')
        vim.cmd('tabclose')
        vim.schedule(function() vim.cmd('edit ' .. vim.fn.fnameescape(original_file_path)) end)
        apply_next_change(index + 1)
      end
    })

    api.nvim_create_autocmd("BufDelete", {
      buffer = diff_buf, once = true,
      callback = function()
        os.remove(tmp_file)
        local was_written = not vim.fn.filereadable(tmp_file)
        if not was_written then
          vim.notify("⏭️ Änderungen verworfen", vim.log.levels.INFO)
          vim.schedule(function()
            vim.cmd('tabclose')
            vim.cmd('edit ' .. vim.fn.fnameescape(original_file_path))
          end)
          apply_next_change(index + 1)
        end
      end
    })

    vim.notify("📝 Diff-Datei geöffnet! :w zum Übernehmen, :q! zum Verwerfen", vim.log.levels.INFO)
  end

  apply_next_change(1)
end

return M
