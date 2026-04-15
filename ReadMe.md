# ollama-chat.nvim

A Neovim plugin for local LLM support directly inside your editor — chat, code completion, file editing, and code explanations, all powered by [Ollama](https://ollama.com).

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Feature Overview](#feature-overview)
- [Chat](#chat)
- [Attaching Files](#attaching-files)
- [Editing Files with the LLM](#editing-files-with-the-llm)
- [Explaining Code](#explaining-code)
- [Code Completion](#code-completion)
- [Switching Models](#switching-models)
- [Statusline Integration](#statusline-integration)
- [All Commands & Keymaps](#all-commands--keymaps)
- [Running Tests](#running-tests)
- [Project Structure](#project-structure)
- [Troubleshooting](#troubleshooting)

---

## Requirements

- **Neovim** >= 0.9
- **Ollama** installed and running locally — [ollama.com](https://ollama.com)
- At least one Ollama model pulled, e.g.:
  ```bash
  ollama pull llama3
  ollama pull codellama
  ```
- **curl** available in your PATH (used for all HTTP requests)
- Optional: [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) for nicer Markdown rendering in the chat window

---

## Installation

### With lazy.nvim (recommended)

```lua
{
  "lostexee/ollama-chat.nvim",
  dependencies = {
    -- Optional but recommended for Markdown rendering in the chat
    {
      "MeanderingProgrammer/render-markdown.nvim",
      dependencies = { "nvim-treesitter/nvim-treesitter" },
      opts = {},
    },
  },
  config = function()
    require("ollama-chat").setup({
      -- configuration goes here, all options are optional
    })
  end,
}
```

### Minimal example (from `init.lua`)

```lua
require("lazy").setup({
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    opts = {},
  },
})

require("ollama-chat").setup()
```

---

## Configuration

All options are passed to `setup()`. Any value not specified falls back to its default.

```lua
require("ollama-chat").setup({
  -- Address of the Ollama server
  host = "localhost:11434",

  -- By default the first available model is used.
  -- Set a preferred model here to pre-select it on startup:
  default_model = nil,  -- e.g. "llama3:70b"

  -- Width and height of the floating chat window (in columns/lines)
  window_width  = 50,
  window_height = 20,

  -- Code Completion
  enable_completion    = false,    -- activate automatically on startup?
  completion_delay     = 400,      -- delay after typing stops, in ms
  completion_min_chars = 3,        -- minimum characters before triggering
  completion_mode      = "single", -- "single" (1 line) or "multi" (up to 5)
  completion_debug     = true,     -- show status messages in the command line

  -- Automatically switch focus back to the working window after attaching a file
  auto_switch_to_file = true,

  -- System prompt mode
  -- "auto"  → chosen automatically based on model size
  -- "small" → always use the short, compact prompt (faster)
  -- "large" → always use the detailed prompt with code quality rules
  prompt_mode = "auto",

  -- Threshold in billions of parameters above which "large" is used in auto mode
  prompt_auto_threshold = 13,  -- e.g. 13 → models >= 13b get the "large" prompt
})
```

The plugin automatically selects between two system prompts:

| Mode | When | Content |
|------|------|---------|

### Prompt Mode in Detail

The plugin automatically selects between two system prompts:

| Mode | When | Content |
|------|------|---------|
| `small` | Models below the threshold | Short, precise instruction. Ideal for fast, smaller models. |
| `large` | Models at or above the threshold, cloud models | Detailed prompt covering code quality, explanations, and formatting rules. |

Cloud keywords (`claude`, `gpt`, `gemini`, etc.) always trigger `large`, regardless of the threshold. Mixture-of-Experts models like `mixtral-8x7b` are correctly counted as 56B.

---

## Feature Overview

| Feature | Command | Keymap |
|---------|---------|--------|
| Open / close chat | `:OllamaChat` | — |
| Toggle focus (chat ↔ editor) | `:OllamaToggle` | `<C-Tab>` / `<leader>t` |
| Switch model | `:OllamaModel` | `<C-m>` in chat |
| Attach current file | `:OllamaAttach` | `<C-a>` in chat |
| Detach file | `:OllamaDetach` | `<C-d>` in chat |
| Edit file with LLM | `:OllamaEdit` | — |
| Explain code (visual) | `:OllamaExplain` | `<leader>e` (Visual Mode) |
| Toggle completion on/off | `:OllamaCompletion on\|off` | — |
| Change completion mode | `:OllamaCompletion single\|multi` | — |

---

## Chat

`:OllamaChat` opens two floating windows on the right side of your editor:

```
┌─────────────────────────────────────────────┐
│           Ollama: llama3:7b                 │  ← chat history (Markdown)
│                                             │
│  **You:** How does Quicksort work?          │
│                                             │
│  **llama3:7b:** Quicksort is a divide...    │
│                                             │
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│  Input (C-s:Send Tab:Switch C-m:Model ...)  │  ← input field
│                                             │
└─────────────────────────────────────────────┘
```

### Keymaps in the Chat Window

| Key | Mode | Action |
|-----|------|--------|
| `<C-s>` | Insert / Normal | Send message |
| `<M-CR>` | Insert / Normal | Send message |
| `<CR>` | Normal | Send message |
| `<Tab>` | Normal | Switch focus to editor |
| `<Tab>` | Insert | Switch focus (only if current line is empty) |
| `<C-m>` | Insert / Normal | Switch model |
| `<C-a>` | Insert / Normal | Attach current file |
| `<C-d>` | Insert / Normal | Detach a file |
| `q` | Normal | Close chat |

### Switching Focus

`<C-Tab>` or `<leader>t` toggles between the chat window and the last active editor window. When jumping to the chat, insert mode is entered automatically.

> **Tip:** File-opening commands like `:e file.lua` typed inside the input window are automatically intercepted and executed in the correct editor window instead.

---

## Attaching Files

You can attach files to the chat so the model has their full content as context and can suggest changes to them.

```
:OllamaAttach      ← attaches the current buffer
<C-a>              ← same thing, from inside the chat window
```

The chat window shows a list of all attached files:

```
📎 Attached Files:
  1. init.lua
  2. completion.lua
```

### File Changes

When the model suggests changes to an attached file and returns the updated code inside a code block, the plugin detects this automatically and opens a **diff view** in a new tab:

```
═══════════════════════════════════════════
Changes for: completion.lua
═══════════════════════════════════════════

LEGEND:  🔴 - = Deleted   🟢 + = Added   ⚪ = Unchanged
COMMANDS: :w = Apply   :q! = Discard

  local function foo()
- local x = 1
+ local x = 42
  end
```

- `:w` — apply the changes and save the file
- `:q!` — discard the changes

> **Note:** If the new code is more than 50% shorter than the original, a warning is displayed — as a safeguard against accidental data loss.

### Detaching Files

```
:OllamaDetach      ← opens a selection menu of all attached files
<C-d>              ← same, from inside the chat window
```

---

## Editing Files with the LLM

`:OllamaEdit` opens a small input popup for the current buffer:

```
┌────────────────────────────────────────────────────┐
│                   File Editing                     │
│ Describe the changes you want for:                 │
│ completion.lua                                     │
│                                                    │
│ (Ctrl-S to send to LLM, q to cancel)              │
└────────────────────────────────────────────────────┘
```

Describe the desired changes in natural language, for example:

> *"Add error handling when the HTTP request fails"*

The model receives the complete file content plus the instruction and returns a revised version. This is shown immediately in a **side-by-side diff** (`diffthis`). At the end the plugin asks whether to apply the changes.

---

## Explaining Code

Select a code region in Visual Mode and press `<leader>e` (or `:OllamaExplain`).

The plugin sends the selection to the active model and shows the explanation in a separate floating window at the bottom right — without moving focus away from your code:

```
┌──────────────────────────────────────────────────┐
│             Ollama: Code Explanation             │
│ ## Code Explanation · `llama3:7b`                │
│                                                  │
│ The `trigger_completion` function is invoked     │
│ by a timer after the user stops typing...        │
│                                                  │
└──────────────────────────────────────────────────┘
```

- The explanation window stays open until you press `q` inside it.
- Consecutive calls while a request is already running are blocked (spam protection).
- If `render-markdown.nvim` is installed, Markdown is rendered automatically.

> **Bug fix (v1.1):** Selections that start with a blank line are now handled correctly. Previously the selection was incorrectly rejected as "empty" when the first selected line was blank — even if real code existed on subsequent lines.

---

## Code Completion

The plugin offers AI-powered inline completion directly in insert mode.

### Enabling

```vim
:OllamaCompletion on
```

Or permanently in your configuration:

```lua
require("ollama-chat").setup({
  enable_completion = true,
})
```

### How It Works

Once you have typed at least `completion_min_chars` characters in insert mode, a request is sent to the model after a short delay (`completion_delay` ms). The suggestion appears as **grey virtual text** directly after the cursor:

```lua
local result = http.request_async(   ← cursor here
                                   url, "POST", body, callback)   ← suggestion
```

### Keymaps with an Active Suggestion

| Key | Action |
|-----|--------|
| `<Tab>` | Accept suggestion |
| `<Esc>` | Dismiss suggestion |

### Mode: single vs. multi

```vim
:OllamaCompletion single    ← complete only the current line (default)
:OllamaCompletion multi     ← suggest up to 5 lines
```

```lua
-- In your configuration:
completion_mode = "multi"
```

### Disabling

```vim
:OllamaCompletion off
```

> **Note:** Completion only runs in regular editor buffers. The chat and input buffers are automatically excluded.

---

## Switching Models

```vim
:OllamaModel
<C-m>        ← inside the chat window
```

A `vim.ui.select` menu opens with all models available on the Ollama server. After selecting a model the chat history is reset, since the new model has no knowledge of the previous conversation.

---

## Statusline Integration

The plugin exposes a statusline function that shows the active model, streaming status, attached files, and completion status.

### With lualine

```lua
local sl = require("ollama-chat.statusline")

require("lualine").setup({
  sections = {
    lualine_x = {
      { sl.full },
    },
  },
})
```

### With heirline

```lua
{ provider = function() return require("ollama-chat.statusline").full() end }
```

### Native statusline (Vimscript)

```vim
set statusline+=%{v:lua.require('ollama-chat.statusline').full()}
```

### Example Output

```
⏳ │ 🤖 llama3:7b │ 📎 init.lua │ ✏️ ...
```

Each part can also be accessed individually:

```lua
local sl = require("ollama-chat.statusline")
sl.model()          -- "🤖 llama3:7b"
sl.streaming()      -- "⏳" or ""
sl.attached_files() -- "📎 init.lua" / "📎 3 files" / ""
sl.completion()     -- "✏️ ..." or ""
sl.full()           -- everything combined, separated by " │ "
```

---

## All Commands & Keymaps

### User Commands

| Command | Description |
|---------|-------------|
| `:OllamaChat` | Open / close the chat |
| `:OllamaEdit` | Edit the current file with the LLM |
| `:OllamaModel` | Select a model |
| `:OllamaAttach` | Attach the current buffer as context |
| `:OllamaDetach` | Remove an attached file |
| `:OllamaToggle` | Toggle focus between chat and editor |
| `:OllamaExplain` | Explain selected code (also as range: `:'<,'>OllamaExplain`) |
| `:OllamaCompletion on` | Enable code completion |
| `:OllamaCompletion off` | Disable code completion |
| `:OllamaCompletion single` | Completion mode: single line |
| `:OllamaCompletion multi` | Completion mode: multiple lines (up to 5) |

### Global Keymaps

| Keymap | Mode | Action |
|--------|------|--------|
| `<C-Tab>` | Normal | Toggle focus chat ↔ editor |
| `<leader>t` | Normal | Toggle focus chat ↔ editor |
| `<leader>e` | Visual | Explain selection |

### Keymaps in the Input Buffer

| Keymap | Mode | Action |
|--------|------|--------|
| `<C-s>` | Insert / Normal | Send message |
| `<M-CR>` | Insert / Normal | Send message |
| `<CR>` | Normal | Send message |
| `<Tab>` | Normal | Switch to editor |
| `<Tab>` | Insert | Switch to editor (only if line is empty) |
| `<C-m>` | Insert / Normal | Switch model |
| `<C-a>` | Insert / Normal | Attach file |
| `<C-d>` | Insert / Normal | Detach file |
| `q` | Normal | Close chat |

### Keymaps with Active Completion

| Keymap | Mode | Action |
|--------|------|--------|
| `<Tab>` | Insert | Accept suggestion |
| `<Esc>` | Insert | Dismiss suggestion |

---

## Running Tests

The plugin ships with a test suite in `tests/test_ollama_chat.lua` that runs without a live Ollama server — all HTTP calls are stubbed out.

### Prerequisites

```bash
# LuaJIT (recommended, fast)
sudo apt install luajit        # Debian/Ubuntu
brew install luajit            # macOS

# or use Neovim headless (no extra install needed)
```

### Running

```bash
# With LuaJIT (no Neovim required)
luajit tests/test_ollama_chat.lua

# With Neovim headless
nvim --headless -l tests/test_ollama_chat.lua
```

### Example Output

```
── prompt_manager ──
  ✓ 7b model → small prompt
  ✓ 70b model → large prompt
  ✓ MoE 8×7b = 56b → large prompt
  ✓ cloud keyword → large prompt
  ...

── completion.lua – response cleanup logic (unit) ──
  ✓ prefix repetition stripped
  ✓ markdown fence removed
  ...

══════════════════════════════════════
Results: 82 passed, 0 failed
```

### What Is Tested

| Module | Test cases |
|--------|-----------|
| `prompt_manager` | Size detection, cloud keywords, MoE params, forced modes, custom threshold |
| `ask` | Blank-first-line fix, column trimming, selection slicing |
| `models` | Loading, auto-selection, no overwrite, empty response |
| `completion` | Response cleanup, line splitting, single/multi mode |
| `chat` | Size-ratio warning, all 3 code-block extraction patterns |
| `attach` | Duplicate detection, file reading, missing file handling |
| `statusline` | All indicator combinations, separator format |
| `http` | Curl argument construction (sync + streaming) |
| `edit` | Code-block extraction from LLM responses |

---

## Project Structure

```
lua/ollama-chat/
├── init.lua           # Entry point, setup(), state, command registration
├── models.lua         # Load and select models
├── chat.lua           # Send messages, detect and apply file changes
├── completion.lua     # AI-powered inline code completion
├── attach.lua         # Attach and detach files
├── window.lua         # Chat window creation, focus management
├── edit.lua           # Edit files with the LLM + diff preview
├── ask.lua            # Explain code (Visual Mode selection)
├── statusline.lua     # Statusline integration
├── prompt_manager.lua # System prompt selection (small / large / auto)
└── http.lua           # HTTP utilities (async + streaming via curl)

tests/
└── test_ollama_chat.lua  # Test suite (82 tests, runs with LuaJIT or nvim --headless)
```

---

## Troubleshooting

**"Error: Is Ollama running?"**
Ollama must be running. Verify with:
```bash
ollama list
curl http://localhost:11434/api/tags
```

**Chat opens but the model list is empty**
No model has been pulled yet. Download at least one:
```bash
ollama pull llama3
```

**Completion doesn't trigger**
Make sure `completion_debug = true` is set — status messages will then appear in the command line. Also verify that you are not inside the chat or input buffer, and that at least `completion_min_chars` characters are present on the current line before the cursor.

**`<C-s>` scrolls the terminal instead of sending**
The plugin automatically runs `stty -ixon` on startup to disable XON/XOFF flow control. If it still doesn't work, add it to your shell config:
```bash
# ~/.bashrc or ~/.zshrc
stty -ixon
```

**Diff shows no changes / new code is much shorter**
The model probably returned only a partial snippet instead of the full file. The yellow warning message indicates this. Discard with `:q!` and retry the request with an explicit instruction like: *"Return the complete file, not just the changed part."*

**render-markdown.nvim is not being applied**
Make sure the plugin is installed and `nvim-treesitter` is available as a dependency. The plugin is loaded optionally via `pcall` and silently falls back to standard syntax highlighting if it is not found.
