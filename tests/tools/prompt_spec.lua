-- tests/tools/prompt_spec.lua

local sandbox    = require("ollama-chat.tools.sandbox")
local prompt_mod = require("ollama-chat.tools.prompt")

-- ─────────────────────────────────────────────────────────────────────────────
-- Hilfsfunktionen
-- ─────────────────────────────────────────────────────────────────────────────

local function make_tmpdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

local function rm_tmpdir(path)
  vim.fn.delete(path, "rf")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tests
-- ─────────────────────────────────────────────────────────────────────────────

describe("prompt", function()

  local tmpdir

  before_each(function()
    tmpdir = make_tmpdir()

    package.loaded["ollama-chat.tools.sandbox"]     = nil
    package.loaded["ollama-chat.tools.definitions"] = nil
    package.loaded["ollama-chat.tools.prompt"]      = nil

    sandbox    = require("ollama-chat.tools.sandbox")
    prompt_mod = require("ollama-chat.tools.prompt")

    sandbox.set_workspace(tmpdir)
  end)

  after_each(function()
    rm_tmpdir(tmpdir)
  end)

  -- ── build_system_prompt() ─────────────────────────────────────────────────

  describe("build_system_prompt()", function()

    it("gibt einen nicht-leeren String zurück", function()
      local p = prompt_mod.build_system_prompt({})
      assert.is_string(p)
      assert.is_true(#p > 100)
    end)

    it("enthält den Workspace-Pfad", function()
      local p = prompt_mod.build_system_prompt({})
      assert.is_truthy(p:find(tmpdir, 1, true),
        "System-Prompt muss den Workspace-Pfad enthalten")
    end)

    it("enthält das Tool-Aufruf-Format (tool_call)", function()
      local p = prompt_mod.build_system_prompt({})
      assert.is_truthy(p:find("tool_call"),
        "System-Prompt muss das Aufruf-Format erklären")
    end)

    it("enthält Sicherheitsregeln", function()
      local p = prompt_mod.build_system_prompt({})
      -- Mindestens eines der Schlüsselwörter aus dem Sicherheits-Abschnitt
      local has_security = p:find("ausschließlich") or p:find("REGELN") or p:find("außerhalb")
      assert.is_truthy(has_security, "System-Prompt muss Sicherheitsregeln enthalten")
    end)

    it("enthält Tool-Beschreibungen", function()
      local p = prompt_mod.build_system_prompt({})
      -- Alle definierten Tools sollten im Prompt vorkommen
      assert.is_truthy(p:find("read_file"),        "read_file fehlt im Prompt")
      assert.is_truthy(p:find("create_file"),      "create_file fehlt im Prompt")
      assert.is_truthy(p:find("edit_file"),        "edit_file fehlt im Prompt")
      assert.is_truthy(p:find("delete_file"),      "delete_file fehlt im Prompt")
      assert.is_truthy(p:find("create_directory"), "create_directory fehlt im Prompt")
      assert.is_truthy(p:find("list_directory"),   "list_directory fehlt im Prompt")
    end)

    it("filtert Tools wenn tool_names angegeben", function()
      local p = prompt_mod.build_system_prompt({
        tool_names = { "read_file", "list_directory" }
      })
      assert.is_truthy(p:find("read_file"))
      assert.is_truthy(p:find("list_directory"))
      -- Diese dürfen NICHT im Prompt erscheinen
      assert.is_falsy(p:find("## create_file"),  "create_file darf nicht im gefilterten Prompt sein")
      assert.is_falsy(p:find("## delete_file"),  "delete_file darf nicht im gefilterten Prompt sein")
    end)

    it("enthält extra_instructions wenn angegeben", function()
      local p = prompt_mod.build_system_prompt({
        extra_instructions = "Nur Lua-Dateien erstellen."
      })
      assert.is_truthy(p:find("Nur Lua%-Dateien erstellen%."))
    end)

    it("enthält keine extra_instructions wenn leer", function()
      local p1 = prompt_mod.build_system_prompt({ extra_instructions = "" })
      local p2 = prompt_mod.build_system_prompt({})
      -- Beide sollten gleich lang sein (kein Extra-Abschnitt)
      assert.equals(#p1, #p2)
    end)

    it("enthält Parameter-Informationen für Tools", function()
      local p = prompt_mod.build_system_prompt({ tool_names = { "create_file" } })
      -- create_file hat path und content als Pflichtparameter
      assert.is_truthy(p:find("path"),    "Parameter 'path' fehlt im Prompt")
      assert.is_truthy(p:find("content"), "Parameter 'content' fehlt im Prompt")
      assert.is_truthy(p:find("PFLICHT"), "Pflichtmarkierung fehlt im Prompt")
    end)

    it("enthält Enum-Werte für edit_file", function()
      local p = prompt_mod.build_system_prompt({ tool_names = { "edit_file" } })
      assert.is_truthy(p:find("overwrite"), "Enum 'overwrite' fehlt")
      assert.is_truthy(p:find("append"),    "Enum 'append' fehlt")
    end)

    it("schlägt fehl wenn kein Workspace gesetzt", function()
      package.loaded["ollama-chat.tools.sandbox"] = nil
      local fresh_sandbox = require("ollama-chat.tools.sandbox")
      -- Kein set_workspace() → get_workspace() wirft
      package.loaded["ollama-chat.tools.prompt"] = nil
      local fresh_prompt = require("ollama-chat.tools.prompt")
      assert.has_error(function()
        fresh_prompt.build_system_prompt({})
      end)
    end)

  end)

  -- ── build_json_schemas() ──────────────────────────────────────────────────

  describe("build_json_schemas()", function()

    it("gibt valides JSON zurück", function()
      local json = prompt_mod.build_json_schemas()
      local ok, parsed = pcall(vim.fn.json_decode, json)
      assert.is_true(ok, "Kein valides JSON: " .. tostring(parsed))
      assert.is_table(parsed)
    end)

    it("gibt ein Array zurück", function()
      local json   = prompt_mod.build_json_schemas()
      local parsed = vim.fn.json_decode(json)
      assert.is_true(#parsed > 0)
    end)

    it("jedes Schema hat name, description, parameters", function()
      local schemas = vim.fn.json_decode(prompt_mod.build_json_schemas())
      for _, s in ipairs(schemas) do
        assert.is_string(s.name,        s.name .. ".name fehlt")
        assert.is_string(s.description, s.name .. ".description fehlt")
        assert.is_table(s.parameters,   s.name .. ".parameters fehlt")
      end
    end)

    it("filtert nach tool_names", function()
      local json    = prompt_mod.build_json_schemas({ "read_file" })
      local schemas = vim.fn.json_decode(json)
      assert.equals(1, #schemas)
      assert.equals("read_file", schemas[1].name)
    end)

    it("enthält keinen 'handler'-Schlüssel (sicherheitsrelevant)", function()
      local schemas = vim.fn.json_decode(prompt_mod.build_json_schemas())
      for _, s in ipairs(schemas) do
        assert.is_nil(s.handler, "JSON-Schema darf keinen handler enthalten: " .. s.name)
      end
    end)

  end)

end)
