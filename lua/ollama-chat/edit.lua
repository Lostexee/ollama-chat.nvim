-- lua/ollama-chat/edit.lua
-- Datei bearbeiten mit LLM + Diff-Preview

local M_ref = nil

local M = {}

function M.init(main)
  M_ref = main
end

function M.edit_current_file()
  local api = vim.api
  local buf = api.nvim_get_current_buf()
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  local filename = api.nvim_buf_get_name(buf)

  if filename == "" then
    vim.notify("Keine Datei im Buffer!", vim.log.levels.WARN)
    return
  end

  local temp_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(temp_buf, 0, -1, false, {
    "Beschreibe die gewünschten Änderungen für:",
    vim.fn.fnamemodify(filename, ":t"), "",
    "(Ctrl-S zum Senden an LLM, q zum Abbrechen)"
  })

  local width, height = 60, 10
  local win = api.nvim_open_win(temp_buf, true, {
    relative = 'editor', width = width, height = height,
    col = (api.nvim_get_option("columns") - width) / 2,
    row = (api.nvim_get_option("lines") - height) / 2,
    style = 'minimal', border = 'rounded',
    title = ' Datei-Bearbeitung ',
  })

  api.nvim_win_set_cursor(win, {4, 0})
  vim.cmd('startinsert')

  local opts = { noremap = true, silent = true, buffer = temp_buf }

  vim.keymap.set('i', '<C-s>', function()
    local instruction_lines = api.nvim_buf_get_lines(temp_buf, 3, -1, false)
    local instruction = table.concat(instruction_lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
    if instruction == "" then
      vim.notify("Keine Anweisung angegeben!", vim.log.levels.WARN)
      return
    end
    api.nvim_win_close(win, true)

    local prompt = string.format(
      "Hier ist der Code aus der Datei '%s':\n\n```\n%s\n```\n\nAnweisung: %s\n\nGib nur den vollständigen geänderten Code zurück, ohne Erklärungen.",
      vim.fn.fnamemodify(filename, ":t"), content, instruction
    )

    vim.notify("⏳ Sende an LLM...", vim.log.levels.INFO)

    local http = require("ollama-chat.http")
    local url = string.format("http://%s/api/generate", M_ref.config.host)
    http.request_async(url, "POST", { model = M_ref.state.current_model, prompt = prompt, stream = false },
      function(response, err)
        if err or not response or not response.response then
          vim.notify("Fehler: " .. (err or "Unknown"), vim.log.levels.ERROR)
          return
        end
        local new_code = response.response:gsub("^```[%w]*\n", ""):gsub("\n```$", "")
        local preview_buf = api.nvim_create_buf(false, true)
        local new_lines = vim.split(new_code, "\n")
        api.nvim_buf_set_lines(preview_buf, 0, -1, false, new_lines)
        api.nvim_buf_set_option(preview_buf, 'filetype', api.nvim_buf_get_option(buf, 'filetype'))
        vim.cmd('tabnew')
        api.nvim_win_set_buf(api.nvim_get_current_win(), preview_buf)
        vim.cmd('diffthis')
        vim.cmd('vsplit ' .. vim.fn.fnameescape(filename))
        vim.cmd('diffthis')
        local answer = vim.fn.inputlist({
          'Änderungen übernehmen?',
          '1. Ja - Übernehmen',
          '2. Nein - Verwerfen',
        })
        if answer == 1 then
          api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
          vim.cmd('write')
          vim.notify("✓ Gespeichert!", vim.log.levels.INFO)
        end
        vim.cmd('tabclose')
      end)
  end, opts)

  vim.keymap.set('n', 'q', function() api.nvim_win_close(win, true) end, opts)
end

return M
