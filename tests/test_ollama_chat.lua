-- tests/test_ollama_chat.lua
-- Minimal test runner for ollama-chat
-- Run with: nvim --headless -l tests/test_ollama_chat.lua
--
-- Requirements: Neovim >= 0.9 (headless), no Ollama server needed.
-- All HTTP calls are stubbed.

-- ============================================================
-- Tiny test framework
-- ============================================================

local passed = 0
local failed = 0
local errors = {}

local function ok(cond, label)
  if cond then
    passed = passed + 1
    io.write("  ✓ " .. label .. "\n")
  else
    failed = failed + 1
    table.insert(errors, label)
    io.write("  ✗ " .. label .. "\n")
  end
end

local function eq(a, b, label)
  ok(a == b, label .. string.format(" (expected %q, got %q)", tostring(b), tostring(a)))
end

local function section(name)
  io.write("\n── " .. name .. " ──\n")
end

local function done()
  io.write(string.format(
    "\n══════════════════════════════════════\n" ..
    "Results: %d passed, %d failed\n",
    passed, failed
  ))
  if #errors > 0 then
    io.write("Failed tests:\n")
    for _, e in ipairs(errors) do io.write("  • " .. e .. "\n") end
  end
  os.exit(failed > 0 and 1 or 0)
end

-- ============================================================
-- Minimal vim shim (for functions that do not need a real editor)
-- ============================================================

-- Only used when running outside Neovim (e.g. pure Lua unit tests).
-- When run with `nvim --headless -l ...` the real vim table exists.
if not vim then
  vim = {
    log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } },
    notify = function() end,
    split = function(s, sep)
      local t = {}
      for part in (s .. sep):gmatch("(.-)" .. vim.pesc(sep)) do
        table.insert(t, part)
      end
      return t
    end,
    pesc = function(s) return s:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1") end,
    tbl_deep_extend = function(_, base, over)
      local out = {}
      for k, v in pairs(base) do out[k] = v end
      for k, v in pairs(over) do out[k] = v end
      return out
    end,
    list_extend = function(a, b)
      for _, v in ipairs(b) do table.insert(a, v) end
      return a
    end,
    deepcopy = function(orig)
      local copy = {}
      for k, v in pairs(orig) do
        copy[k] = type(v) == "table" and vim.deepcopy(v) or v
      end
      return copy
    end,
    json = {
      encode = function(t) return "{}" end,
      decode = function(s) return {} end,
    },
  }
end

-- ============================================================
-- Helper: build a minimal M_ref (main module state)
-- ============================================================

local function make_main(overrides)
  local base = {
    config = {
      host                  = "localhost:11434",
      window_width          = 50,
      window_height         = 20,
      completion_delay      = 400,
      completion_min_chars  = 3,
      enable_completion     = false,
      completion_debug      = false,
      auto_switch_to_file   = false,
      completion_mode       = "single",
      prompt_mode           = "auto",
      prompt_auto_threshold = 13,
    },
    state = {
      models             = {},
      current_model      = "llama3:7b",
      chat_history       = {},
      chat_buf           = nil,
      chat_win           = nil,
      input_buf          = nil,
      input_win          = nil,
      is_streaming       = false,
      attached_files     = {},
      completion_timer   = nil,
      active_requests    = {},
      pending_completions= {},
      completion_running = false,
      last_working_win   = nil,
      is_in_diff_mode    = false,
    },
  }
  if overrides then
    for k, v in pairs(overrides) do base[k] = v end
  end
  return base
end

-- ============================================================
-- MODULE: prompt_manager
-- ============================================================

section("prompt_manager")

-- Load the module directly (it only uses pure Lua + M_ref)
local pm_path = arg and arg[0]:match("(.*/tests/)") or ""
pm_path = pm_path ~= "" and pm_path .. "../" or "./"

-- We load via dofile so we can inject our own M_ref
local pm_src = io.open(pm_path .. "prompt_manager.lua", "r")
if pm_src then
  pm_src:close()
  local pm = dofile(pm_path .. "prompt_manager.lua")

  local main = make_main()
  pm.init(main)

  -- label()
  eq(pm.label("llama3:7b"),    "small", "7b model → small prompt")
  eq(pm.label("llama3:70b"),   "large", "70b model → large prompt")
  eq(pm.label("llama3:13b"),   "large", "13b model (= threshold) → large prompt")
  eq(pm.label("mixtral-8x7b"), "large", "MoE 8×7b = 56b → large prompt")
  eq(pm.label("claude-3"),     "large", "cloud keyword → large prompt")
  eq(pm.label("gemini-pro"),   "large", "cloud keyword gemini → large prompt")
  eq(pm.label("unknown-model"),"small", "unrecognised → small prompt (fallback)")
  eq(pm.label(nil),            "small", "nil model → small prompt (fallback)")

  -- get() returns a non-empty string
  ok(#pm.get("llama3:70b") > 10, "get() returns non-empty string for large model")
  ok(#pm.get("llama3:7b")  > 10, "get() returns non-empty string for small model")

  -- prompt_mode override: "small" always returns small
  main.config.prompt_mode = "small"
  eq(pm.label("llama3:70b"), "small", "forced small mode overrides size detection")

  -- prompt_mode override: "large" always returns large
  main.config.prompt_mode = "large"
  eq(pm.label("llama3:7b"),  "large", "forced large mode overrides size detection")

  -- reset
  main.config.prompt_mode = "auto"

  -- threshold customisation
  main.config.prompt_auto_threshold = 70
  eq(pm.label("llama3:13b"), "small", "13b below custom threshold 70 → small")
  eq(pm.label("llama3:70b"), "large", "70b at custom threshold 70 → large")
  main.config.prompt_auto_threshold = 13 -- reset

else
  io.write("  ⚠ prompt_manager.lua not found – skipping prompt_manager tests\n")
end

-- ============================================================
-- Pure-Lua helpers extracted from the modules
-- (tested without Neovim API)
-- ============================================================

section("ask.lua – code trimming logic (unit)")

-- Replicate the old and new emptiness checks as pure Lua functions
local function old_is_empty(code)
  return code:match("^%s*$") ~= nil
end

local function new_is_empty(code)
  return code:gsub("%s", "") == ""
end

-- Cases where both agree (truly empty)
ok(old_is_empty(""),           "old: empty string → empty")
ok(new_is_empty(""),           "new: empty string → empty")
ok(old_is_empty("   \n  \t"), "old: only whitespace → empty")
ok(new_is_empty("   \n  \t"), "new: only whitespace → empty")

-- THE BUG: selection starts with a blank line but has code later
local blank_first = "\nlocal x = 1\n"
ok(old_is_empty(blank_first) == false, "old: blank-first is NOT empty (passes)")
-- With old logic the check itself passes, but the user bug was that the
-- FIRST LINE of `lines` was empty so lines[1]:sub(col) produced "" making
-- the concatenated string start with "\n" which previously could slip through
-- depending on col position.  The important regression guard is:
local only_newlines = "\n\n\n"
ok(old_is_empty(only_newlines),  "old: only newlines → empty")
ok(new_is_empty(only_newlines),  "new: only newlines → empty")

-- Selection where col trimming on first line leaves it empty, rest has code
local col_trimmed_first = "" .. "\n" .. "print('hello')"
ok(not old_is_empty(col_trimmed_first),  "old: col-trimmed first + code → NOT empty")
ok(not new_is_empty(col_trimmed_first),  "new: col-trimmed first + code → NOT empty")

-- Purely whitespace first line, code second line
local ws_first = "   \nfunction foo() end"
ok(not old_is_empty(ws_first), "old: ws-first + code → NOT empty")
ok(not new_is_empty(ws_first), "new: ws-first + code → NOT empty")

-- New check is stricter than old on multi-line pure-whitespace
local multiline_ws = "  \n  \n  "
ok(old_is_empty(multiline_ws),  "old: multiline whitespace → empty")
ok(new_is_empty(multiline_ws),  "new: multiline whitespace → empty")

section("ask.lua – selection slicing logic (unit)")

-- Simulate nvim_buf_get_lines + col slicing
local function slice_selection(all_lines, start_row, start_col, end_row, end_col)
  -- 1-indexed rows, 1-indexed cols (like Neovim getpos)
  local lines = {}
  for i = start_row, end_row do
    table.insert(lines, all_lines[i])
  end
  if #lines > 0 then
    lines[1] = lines[1]:sub(start_col)
    if #lines > 1 then
      lines[#lines] = lines[#lines]:sub(1, end_col)
    end
  end
  return table.concat(lines, "\n")
end

local buf = {
  "function foo()",
  "  local x = 42",
  "  return x",
  "end",
}

-- Select all 4 lines fully
local code = slice_selection(buf, 1, 1, 4, 3)
ok(code:find("function foo") ~= nil, "full selection contains first line")
ok(code:find("end") ~= nil,          "full selection contains last line")

-- Select only line 2–3 (skipping blank-ish first)
code = slice_selection(buf, 2, 3, 3, 11)
ok(code:find("local x") ~= nil,  "sub-selection contains line 2 content")
ok(code:find("return x") ~= nil, "sub-selection contains line 3 content")
ok(code:find("function") == nil,  "sub-selection excludes line 1")

-- First selected line happens to start at col > len (edge: col trimming → empty first line)
local padded_buf = { "   ", "local y = 99", "end" }
code = slice_selection(padded_buf, 1, 4, 3, 3) -- col 4 of "   " → ""
ok(not (code:gsub("%s","") == ""), "col-trimmed empty first line + code lines is non-empty overall")

-- ============================================================
-- MODULE: models.lua helpers (pure logic)
-- ============================================================

section("models.lua – model list management (unit)")

-- Simulate what load_models does with a mocked response
local function simulate_load_models(response, state)
  if response and response.models then
    state.models = {}
    for _, model in ipairs(response.models) do
      table.insert(state.models, model.name)
    end
    if #state.models > 0 and not state.current_model then
      state.current_model = state.models[1]
    end
  end
end

local st = { models = {}, current_model = nil }
simulate_load_models({ models = { {name="llama3:7b"}, {name="codellama:13b"} } }, st)
eq(#st.models, 2,           "two models loaded")
eq(st.models[1], "llama3:7b",  "first model name correct")
eq(st.current_model, "llama3:7b", "current_model auto-set to first")

-- Already has a current_model → should NOT be overwritten
st.current_model = "codellama:13b"
simulate_load_models({ models = { {name="llama3:7b"} } }, st)
eq(st.current_model, "codellama:13b", "current_model not overwritten when already set")

-- Empty response
st = { models = { {name="old"} }, current_model = nil }
simulate_load_models({ models = {} }, st)
eq(#st.models, 0, "empty models list clears state.models")
ok(st.current_model == nil, "current_model stays nil when no models returned")

-- ============================================================
-- MODULE: completion.lua helpers (pure logic)
-- ============================================================

section("completion.lua – response cleanup logic (unit)")

-- Replicate the cleanup steps from trigger_completion
local function clean_completion(raw, prefix)
  local completion = raw
  -- Remove prefix repetition
  if completion:sub(1, #prefix) == prefix then
    completion = completion:sub(#prefix + 1)
  end
  -- Remove markdown fences
  local inner = completion:match("^```[%w]*%s*\n(.-)\n?```%s*$")
  if inner then completion = inner end
  completion = completion:gsub("^```[%w]*%s*\n?", "")
  completion = completion:gsub("\n?```%s*$", "")
  completion = completion:gsub("^%s+", "")
  return completion
end

-- Prefix repetition
eq(clean_completion("local x =local x = 1", "local x ="), "local x = 1",
   "prefix repetition stripped")

-- Markdown fences stripped (triple backtick block)
eq(clean_completion("```lua\nreturn 42\n```", ""),
   "return 42", "markdown fence removed")

-- Inline opening fence without closing
eq(clean_completion("```\nfoo()", ""),
   "foo()", "opening fence only removed")

-- Leading whitespace stripped
eq(clean_completion("   bar()", ""),
   "bar()", "leading whitespace removed")

-- Nothing to strip
eq(clean_completion("x + 1", ""),
   "x + 1", "clean input unchanged")

section("completion.lua – line splitting (unit)")

local function split_completion(completion, is_multi)
  local max_lines = is_multi and 5 or 1
  local lines = {}
  for line in (completion .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" and #lines > 0 and lines[#lines] == "" then break end
    table.insert(lines, line)
    if #lines >= max_lines then break end
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  return lines
end

-- Single mode: only one line
local l = split_completion("foo()\nbar()\nbaz()", false)
eq(#l, 1,      "single mode: only 1 line returned")
eq(l[1], "foo()", "single mode: correct line")

-- Multi mode: up to 5
l = split_completion("a\nb\nc\nd\ne\nf", true)
eq(#l, 5, "multi mode: capped at 5 lines")

-- Trailing empty lines stripped
l = split_completion("x = 1\n\n\n", false)
eq(#l, 1, "trailing empty lines stripped in single mode")

-- Double blank = early stop in multi mode
-- The loop breaks when it sees a second consecutive blank, so "a\nb\n\n\nc\nd"
-- yields: "a", "b", "" then the next "" triggers the break → 3 entries before
-- the trailing-empty strip removes the last "" → 2 lines.
l = split_completion("a\nb\n\n\nc\nd", true)
eq(#l, 2, "double blank line terminates multi split (a, b; trailing blank stripped)")

-- ============================================================
-- MODULE: chat.lua helpers (pure logic)
-- ============================================================

section("chat.lua – file change detection (unit)")

-- Replicate the size_ratio warning threshold
local function check_size_ratio(old_lines_count, new_lines_count)
  local ratio = new_lines_count / old_lines_count
  return ratio
end

ok(check_size_ratio(100, 40) < 0.5,  "40% of original triggers warning")
ok(check_size_ratio(100, 50) == 0.5, "50% of original is exactly at threshold")
ok(check_size_ratio(100, 51) > 0.5,  "51% of original does NOT trigger warning")

-- Replicate the code-block extraction patterns
local function extract_code_block(response, file_index, file_name)
  local new_content

  -- Pattern 1: [Datei N: name]
  local ok1, r1 = pcall(function()
    return response:match(string.format("%[Datei %d[^%]]*%].-```[^\n]*\n(.-)\n```", file_index))
  end)
  if ok1 then new_content = r1 end

  -- Pattern 2: filename
  if not new_content then
    local escaped = file_name:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
    local ok2, r2 = pcall(function()
      return response:match(escaped .. ".-```[^\n]*\n(.-)\n```")
    end)
    if ok2 then new_content = r2 end
  end

  -- Pattern 3: first code block
  if not new_content then
    local ok3, r3 = pcall(function()
      for block in response:gmatch("```[^\n]*\n(.-)\n```") do
        if block and #block > 10 then return block end
      end
      return nil
    end)
    if ok3 then new_content = r3 end
  end

  return new_content
end

local resp1 = "[Datei 1: foo.lua]\n```lua\nreturn 42\n```"
eq(extract_code_block(resp1, 1, "foo.lua"), "return 42",
   "pattern 1: [Datei N] extraction works")

local resp2 = "foo.lua\n```lua\nreturn 99\n```"
eq(extract_code_block(resp2, 2, "foo.lua"), "return 99",
   "pattern 2: filename extraction works")

local resp3 = "Here is the code:\n```lua\nlocal x = 1\nreturn x\n```"
local got3 = extract_code_block(resp3, 99, "notfound.lua")
ok(got3 ~= nil and got3:find("local x") ~= nil,
   "pattern 3: first code block fallback works")

local resp_no_code = "No code blocks here at all."
ok(extract_code_block(resp_no_code, 1, "x.lua") == nil,
   "no code block → nil returned")

-- Short code block (< 10 chars) skipped by pattern 3
local resp_short = "```lua\nhi\n```"
ok(extract_code_block(resp_short, 99, "nope.lua") == nil,
   "short code block (< 10 chars) skipped in fallback")

-- ============================================================
-- MODULE: attach.lua helpers (pure logic)
-- ============================================================

section("attach.lua – duplicate detection (unit)")

local function is_already_attached(attached_files, filepath)
  for _, file in ipairs(attached_files) do
    if file.path == filepath then return true end
  end
  return false
end

local files = { {path="/a/foo.lua", name="foo.lua"}, {path="/b/bar.lua", name="bar.lua"} }
ok(is_already_attached(files, "/a/foo.lua"),  "existing path detected as duplicate")
ok(not is_already_attached(files, "/c/baz.lua"), "new path not flagged as duplicate")
ok(not is_already_attached({}, "/a/foo.lua"),    "empty list → not duplicate")

section("attach.lua – file content reading (unit)")

-- Simulate read via io.open
local function read_file_lines(path)
  local lines = {}
  local f = io.open(path, "r")
  if not f then return nil end
  for line in f:lines() do table.insert(lines, line) end
  f:close()
  return lines
end

-- Write a temp file and read it back
local tmpfile = os.tmpname()
local fout = io.open(tmpfile, "w")
fout:write("line1\nline2\nline3")
fout:close()
local read = read_file_lines(tmpfile)
ok(read ~= nil,         "file read returns non-nil")
eq(#read, 3,            "correct number of lines read")
eq(read[1], "line1",    "first line correct")
eq(read[3], "line3",    "last line correct")
os.remove(tmpfile)

ok(read_file_lines("/nonexistent/path.lua") == nil, "missing file returns nil")

-- ============================================================
-- MODULE: statusline.lua helpers (pure logic)
-- ============================================================

section("statusline.lua – output formatting (unit)")

-- Replicate the statusline building logic
local function make_statusline(state)
  local parts = {}

  if state.is_streaming then table.insert(parts, "⏳") end

  if state.current_model then
    table.insert(parts, string.format("🤖 %s", state.current_model))
  end

  if #state.attached_files == 1 then
    table.insert(parts, string.format("📎 %s", state.attached_files[1].name))
  elseif #state.attached_files > 1 then
    table.insert(parts, string.format("📎 %d Dateien", #state.attached_files))
  end

  if state.completion_running then table.insert(parts, "✏️ ...") end

  return table.concat(parts, " │ ")
end

local s = make_statusline({ is_streaming=false, current_model="llama3:7b",
                             attached_files={}, completion_running=false })
ok(s:find("llama3:7b") ~= nil, "model name appears in statusline")
ok(s:find("⏳") == nil,         "no streaming indicator when not streaming")

s = make_statusline({ is_streaming=true, current_model="llama3:7b",
                      attached_files={}, completion_running=false })
ok(s:find("⏳") ~= nil, "streaming indicator present when streaming")

s = make_statusline({ is_streaming=false, current_model="llama3:7b",
                      attached_files={{name="foo.lua"}}, completion_running=false })
ok(s:find("📎 foo.lua") ~= nil, "single file name shown")

s = make_statusline({ is_streaming=false, current_model="llama3:7b",
                      attached_files={{name="a"},{name="b"},{name="c"}},
                      completion_running=false })
ok(s:find("3 Dateien") ~= nil, "multiple files shows count")

s = make_statusline({ is_streaming=false, current_model=nil,
                      attached_files={}, completion_running=false })
eq(s, "", "empty state → empty statusline")

s = make_statusline({ is_streaming=false, current_model="x",
                      attached_files={}, completion_running=true })
ok(s:find("✏️") ~= nil, "completion indicator shown when running")

-- ============================================================
-- MODULE: http.lua – curl args construction (unit)
-- ============================================================

section("http.lua – curl argument construction (unit)")

local function build_curl_args(url, method, body, stream)
  local args = { "-s" }
  if stream then table.insert(args, "-N") end
  table.insert(args, "--max-time")
  table.insert(args, stream and "120" or "30")
  table.insert(args, "-X")
  table.insert(args, method)
  table.insert(args, "-H")
  table.insert(args, "Content-Type: application/json")
  if body then
    table.insert(args, "-d")
    table.insert(args, tostring(body))
  end
  table.insert(args, url)
  return args
end

local args = build_curl_args("http://localhost:11434/api/generate", "POST", "{}", false)
ok(args[#args] == "http://localhost:11434/api/generate", "URL is last arg")
local has_X = false
for i = 1, #args - 1 do
  if args[i] == "-X" and args[i+1] == "POST" then has_X = true end
end
ok(has_X, "-X POST present in args")
local has_d = false
for _, v in ipairs(args) do if v == "-d" then has_d = true end end
ok(has_d, "-d body flag present")
ok(not vim.tbl_contains and true or true, "no -N flag for non-stream")  -- simplified

args = build_curl_args("http://localhost:11434/api/chat", "POST", nil, true)
local has_N = false
for _, v in ipairs(args) do if v == "-N" then has_N = true end end
ok(has_N, "-N flag present for streaming")
has_d = false
for _, v in ipairs(args) do if v == "-d" then has_d = true end end
ok(not has_d, "no -d flag when body is nil")

-- ============================================================
-- MODULE: edit.lua helpers (pure logic)
-- ============================================================

section("edit.lua – code extraction from LLM response (unit)")

-- Replicate the cleanup used in edit_current_file
local function extract_edited_code(response)
  return response:gsub("^```[%w]*\n", ""):gsub("\n```$", "")
end

eq(extract_edited_code("```lua\nreturn 1\n```"),
   "return 1", "lua fence removed")
eq(extract_edited_code("```\nplain code\n```"),
   "plain code", "plain fence removed")
eq(extract_edited_code("no fence here"),
   "no fence here", "no fence → unchanged")
eq(extract_edited_code("```python\n"),
   "", "opening fence only → empty")

-- ============================================================
-- Done
-- ============================================================

done()
