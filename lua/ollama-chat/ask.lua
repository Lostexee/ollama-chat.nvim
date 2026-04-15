-- lua/ollama-chat/ask.lua
-- Code erklären (Visual Mode Selektion)
--
-- Features:
--   - Visuelles Feedback + Spam-Schutz während Anfrage läuft
--   - Fenster erscheint rechts unten neben dem Chat-Fenster
--   - Bleibt offen ohne zu stören (Fokus bleibt beim Code)
--   - Markdown Rendering via render-markdown.nvim (optional)
--     Fallback: Syntax-Highlighting

local M_ref = nil

local M = {}

-- Interner State: verhindert mehrfache gleichzeitige Anfragen
local is_running = false

local EXPLAIN_WIDTH  = 70   -- breiter als Chat (Chat = 50)
local EXPLAIN_HEIGHT = 35   -- Zeilen nach unten

-- Referenz auf offenes Erklärungs-Fenster (nur eines gleichzeitig)
local explain_win = nil
local explain_buf = nil

function M.init(main)
  M_ref = main
end

-- ============================================
-- INTERNE HILFSFUNKTIONEN
-- ============================================

-- Zeigt ein "Lädt..."-Fenster an der Zielposition
local function show_loading_win()
  local api    = vim.api
  local width  = M_ref.config.window_width
  local col    = vim.o.columns - width - 2

  -- Chat-Fenster-Höhe ermitteln für Position darunter
  local chat_height = math.floor(M_ref.config.window_height * 0.7)
  local input_height = M_ref.config.window_height - chat_height - 1
  local row = 1 + chat_height + 1 + input_height + 2  -- unter Input-Fenster

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    "",
    "  ⏳ Frage " .. (M_ref.state.current_model or "Modell") .. "...",
    "",
  })
  api.nvim_buf_set_option(buf, 'modifiable', false)

  local win = api.nvim_open_win(buf, false, {
    relative  = 'editor',
    width     = width,
    height    = 3,
    col       = col,
    row       = row,
    style     = 'minimal',
    border    = 'rounded',
    title     = ' Ollama: Code-Erklärung ',
    title_pos = 'center',
  })

  return win, buf
end

-- Öffnet das finale Erklärungs-Fenster (ersetzt Lade-Fenster)
local function show_result_win(result_lines)
  local api    = vim.api
  local width  = M_ref.config.window_width
  local col    = vim.o.columns - width - 2

  local chat_height  = math.floor(M_ref.config.window_height * 0.7)
  local input_height = M_ref.config.window_height - chat_height - 1
  local row          = 1 + chat_height + 1 + input_height + 2

  -- Maximale Höhe: vom Startpunkt bis Bildschirmende, minus etwas Rand
  local max_height = vim.o.lines - row - 2
  local height     = math.min(#result_lines, math.max(max_height, 5))

  -- Alten Buffer/Fenster wiederverwenden oder neu erstellen
  if not explain_buf or not api.nvim_buf_is_valid(explain_buf) then
    explain_buf = api.nvim_create_buf(false, true)
  end

  api.nvim_buf_set_option(explain_buf, 'modifiable', true)
  api.nvim_buf_set_lines(explain_buf, 0, -1, false, result_lines)
  api.nvim_buf_set_option(explain_buf, 'modifiable', false)
  api.nvim_buf_set_option(explain_buf, 'filetype', 'markdown')

  -- Fenster öffnen (nicht fokussieren → Fokus bleibt beim Code)
  if not explain_win or not api.nvim_win_is_valid(explain_win) then
    explain_win = api.nvim_open_win(explain_buf, false, {
      relative  = 'editor',
      width     = width,
      height    = height,
      col       = col,
      row       = row,
      style     = 'minimal',
      border    = 'rounded',
      title     = ' Ollama: Code-Erklärung ',
      title_pos = 'center',
    })
    api.nvim_win_set_option(explain_win, 'wrap', true)
    api.nvim_win_set_option(explain_win, 'cursorline', true)
  else
    -- Fenster existiert bereits → nur Größe anpassen
    api.nvim_win_set_config(explain_win, {
      relative  = 'editor',
      width     = width,
      height    = height,
      col       = col,
      row       = row,
      title     = ' Ollama: Code-Erklärung ',
      title_pos = 'center',
    })
  end

  -- render-markdown.nvim aktivieren falls vorhanden
  local ok, render_md = pcall(require, "render-markdown")
  if ok then
    pcall(render_md.enable, explain_buf)
  end

  -- q schließt das Fenster (nur wenn man manuell reinklickt/wechselt)
  vim.keymap.set('n', 'q', function()
    if explain_win and api.nvim_win_is_valid(explain_win) then
      api.nvim_win_close(explain_win, true)
      explain_win = nil
    end
  end, { buffer = explain_buf, noremap = true, silent = true })
end

-- ============================================
-- ÖFFENTLICHE API
-- ============================================

function M.explain_selection()
  local api = vim.api

  -- Spam-Schutz
  if is_running then
    vim.notify("⏳ Erklärung läuft bereits...", vim.log.levels.WARN)
    return
  end

  if not M_ref.state.current_model then
    vim.notify("Kein Modell aktiv! Erst :OllamaChat öffnen.", vim.log.levels.ERROR)
    return
  end

  -- Ausgewählten Text holen
  local start_pos = vim.fn.getpos("'<")
  local end_pos   = vim.fn.getpos("'>")
  local lines     = api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)

  if #lines > 0 then
    lines[1] = lines[1]:sub(start_pos[3])
    if #lines > 1 then
      lines[#lines] = lines[#lines]:sub(1, end_pos[3])
    end
  end

  local code = table.concat(lines, "\n")

  -- Trim leading/trailing whitespace before the emptiness check so that a
  -- selection that starts (or ends) with a blank line but contains real code
  -- in between is not rejected.
  if code:gsub("%s", "") == "" then
    vim.notify("Keine Code-Auswahl!", vim.log.levels.WARN)
    return
  end

  -- Anfrage starten
  is_running = true
  local loading_win, loading_buf = show_loading_win()

  local http   = require("ollama-chat.http")
  local url    = string.format("http://%s/api/generate", M_ref.config.host)
  local prompt = string.format(
    "Erkläre folgenden Code kurz und präzise:\n\n```\n%s\n```",
    code
  )

  http.request_async(url, "POST", {
    model  = M_ref.state.current_model,
    prompt = prompt,
    stream = false,
  }, function(response, err)
    is_running = false

    -- Lade-Fenster schließen
    if loading_win and api.nvim_win_is_valid(loading_win) then
      api.nvim_win_close(loading_win, true)
    end

    if err or not response or not response.response then
      vim.notify("Fehler: " .. (err or "Unknown"), vim.log.levels.ERROR)
      return
    end

    local result_lines = vim.split(response.response, "\n")
    -- Header
    table.insert(result_lines, 1, "")
    table.insert(result_lines, 1, string.format(
      "## Code-Erklärung · `%s`", M_ref.state.current_model
    ))

    show_result_win(result_lines)
  end)
end

return M
