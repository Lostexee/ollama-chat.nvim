-- lua/ollama-chat/init.lua
local M = {}
local api = vim.api
local fn = vim.fn
local uv = vim.loop

-- Konfiguration
M.config = {
  host = "localhost:11434",
  default_model = nil,
  window_width = 50,
  window_height = 20,
  completion_delay = 400, -- ms (reduziert für schnellere Response)
  completion_min_chars = 3,
  enable_completion = false,
  completion_debug = true,
  auto_switch_to_file = true,
  completion_mode = "single",   -- "single" oder "multi"
  prompt_mode = "auto",          -- "small" | "large" | "auto"
  prompt_auto_threshold = 13,    -- ab wieviel Milliarden Parameter gilt "large"
}

-- State
M.state = {
  models = {},
  current_model = nil,
  chat_history = {},
  chat_buf = nil,
  chat_win = nil,
  input_buf = nil,
  input_win = nil,
  is_streaming = false,
  attached_files = {},
  completion_timer = nil,
  completion_active = false,
  active_requests = {},
  pending_completions = {},
  completion_running = false,
  last_working_win = nil,
  is_in_diff_mode = false,
  -- NEU: Letzte Cursor-Position für schnellen Vergleich
  last_completion_pos = nil,
}

-- ============================================
-- SUBMODULE LADEN & VERKNÜPFEN
-- ============================================

local _models     = require("ollama-chat.models")
local _attach     = require("ollama-chat.attach")
local _window     = require("ollama-chat.window")
local _chat       = require("ollama-chat.chat")
local _completion = require("ollama-chat.completion")
local _edit       = require("ollama-chat.edit")
local _ask          = require("ollama-chat.ask")
local _statusline   = require("ollama-chat.statusline")
local _prompt_mgr   = require("ollama-chat.prompt_manager")

_models.init(M)
_attach.init(M)
_window.init(M)
_chat.init(M)
_completion.init(M)
_edit.init(M)
_ask.init(M)
_statusline.init(M)
_prompt_mgr.init(M)

-- ============================================
-- ÖFFENTLICHE FUNKTIONEN (delegiert an Module)
-- ============================================

function M.load_models()               _models.load_models()               end
function M.select_model()              _models.select_model()               end

function M.attach_file(fp)             _attach.attach_file(fp)              end
function M.detach_file(idx)            _attach.detach_file(idx)             end
function M.attach_current_file()       _attach.attach_current_file()        end
function M.update_attached_files_display() _attach.update_attached_files_display() end

function M.save_last_working_window()  _window.save_last_working_window()   end
function M.toggle_focus()              _window.toggle_focus()               end
function M.create_chat_window()        _window.create_chat_window()         end

function M.send_message()              _chat.send_message()                 end
function M.check_for_file_changes(r)   _chat.check_for_file_changes(r)      end
function M.apply_file_changes(c)       _chat.apply_file_changes(c)          end

function M.setup_completion()          _completion.setup_completion()       end
function M.trigger_completion()        _completion.trigger_completion()     end
function M.disable_completion()        _completion.disable_completion()     end

function M.edit_current_file()         _edit.edit_current_file()            end

function M.explain_selection()         _ask.explain_selection()             end
function M.statusline()                return _statusline.full()            end
function M.get_prompt(model)            return _prompt_mgr.get(model)        end
function M.prompt_label(model)          return _prompt_mgr.label(model)      end

-- ============================================
-- TOGGLE / CLOSE
-- ============================================

function M.close()
  if M.state.chat_win and api.nvim_win_is_valid(M.state.chat_win) then
    api.nvim_win_close(M.state.chat_win, true)
  end
  if M.state.input_win and api.nvim_win_is_valid(M.state.input_win) then
    api.nvim_win_close(M.state.input_win, true)
  end
end

function M.toggle()
  if M.state.chat_win and api.nvim_win_is_valid(M.state.chat_win) then
    M.close()
  else
    if #M.state.models == 0 then
      vim.notify("⏳ Lade Modelle...", vim.log.levels.INFO)
      M.load_models()
      vim.defer_fn(function()
        if #M.state.models > 0 then
          M.create_chat_window()
        else
          vim.notify("Fehler: Ist Ollama gestartet?", vim.log.levels.ERROR)
        end
      end, 500)
    else
      M.create_chat_window()
    end
  end
end

-- ============================================
-- SETUP
-- ============================================

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.cmd([[silent! !stty -ixon 2>/dev/null]])
  vim.api.nvim_create_autocmd("VimEnter", {
    callback = function() vim.fn.system("stty -ixon 2>/dev/null") end,
    once = true,
  })

  -- Globale Navigation
  vim.keymap.set('n', '<C-Tab>', function() M.toggle_focus() end,
    { noremap = true, silent = true, desc = 'Toggle Chat/Datei Focus' })
  vim.keymap.set('n', '<leader>t', function() M.toggle_focus() end,
    { noremap = true, silent = true, desc = 'Toggle Chat/Datei Focus' })

  -- Commands
  api.nvim_create_user_command('OllamaChat', function() M.toggle() end, {})
  api.nvim_create_user_command('OllamaEdit', function() M.edit_current_file() end, {})
  api.nvim_create_user_command('OllamaModel', function() M.select_model() end, {})
  api.nvim_create_user_command('OllamaAttach', function() M.attach_current_file() end, {})
  api.nvim_create_user_command('OllamaDetach', function() M.detach_file() end, {})
  api.nvim_create_user_command('OllamaToggle', function() M.toggle_focus() end, {})
  api.nvim_create_user_command('OllamaExplain', function() M.explain_selection() end, { range = true })

  vim.keymap.set('v', '<leader>e', function() M.explain_selection() end,
    { noremap = true, silent = true, desc = 'Ollama: Code erklären' })
  api.nvim_create_user_command('OllamaCompletion', function(args)
    local input = args.args:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if input == 'on' then
      M.setup_completion()
    elseif input == 'off' then
      M.disable_completion()
    elseif input == 'single' then
      M.config.completion_mode = "single"
      vim.notify("✓ Completion-Modus: einzelne Zeile", vim.log.levels.INFO)
    elseif input == 'multi' then
      M.config.completion_mode = "multi"
      vim.notify("✓ Completion-Modus: mehrere Zeilen (max. 5)", vim.log.levels.INFO)
    else
      vim.notify("Usage: :OllamaCompletion on|off|single|multi", vim.log.levels.WARN)
    end
  end, {
    nargs = 1,
    complete = function() return { 'on', 'off', 'single', 'multi' } end,
  })

  M.load_models()

  if M.config.enable_completion then
    M.setup_completion()
  end
end

return M
