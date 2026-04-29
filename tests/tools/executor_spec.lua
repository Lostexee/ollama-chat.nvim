-- tests/tools/executor_spec.lua

local sandbox  = require("ollama-chat.tools.sandbox")
local executor = require("ollama-chat.tools.executor")

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

local function write(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

--- Baut einen tool_call-Block wie ihn das LLM ausgeben würde.
local function make_block(tool, params)
  local json = vim.fn.json_encode({ tool = tool, parameters = params })
  return "```tool_call\n" .. json .. "\n```"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tests
-- ─────────────────────────────────────────────────────────────────────────────

describe("executor", function()

  local tmpdir

  before_each(function()
    tmpdir = make_tmpdir()

    -- Sandbox + alle Module frisch laden
    package.loaded["ollama-chat.tools.sandbox"]     = nil
    package.loaded["ollama-chat.tools.definitions"] = nil
    package.loaded["ollama-chat.tools.executor"]    = nil

    sandbox  = require("ollama-chat.tools.sandbox")
    executor = require("ollama-chat.tools.executor")

    sandbox.set_workspace(tmpdir)
  end)

  after_each(function()
    rm_tmpdir(tmpdir)
  end)

  -- ── parse_tool_calls() ────────────────────────────────────────────────────

  describe("parse_tool_calls()", function()

    it("extrahiert einen einzelnen Tool-Aufruf", function()
      local response = make_block("list_directory", {})
      local calls = executor.parse_tool_calls(response)
      assert.equals(1, #calls)
      assert.equals("list_directory", calls[1].tool)
    end)

    it("extrahiert mehrere Tool-Aufrufe in Reihenfolge", function()
      local response = make_block("list_directory", {})
        .. "\n\n" .. make_block("create_file", { path = "x.txt", content = "y" })
      local calls = executor.parse_tool_calls(response)
      assert.equals(2, #calls)
      assert.equals("list_directory", calls[1].tool)
      assert.equals("create_file",    calls[2].tool)
    end)

    it("ignoriert normalen Text außerhalb der Blöcke", function()
      local response = "Ich erstelle jetzt eine Datei:\n\n"
        .. make_block("create_file", { path = "a.txt", content = "hi" })
        .. "\n\nDas war alles."
      local calls = executor.parse_tool_calls(response)
      assert.equals(1, #calls)
    end)

    it("gibt Fehler-Entry bei ungültigem JSON zurück", function()
      local response = "```tool_call\nnicht-json!!!\n```"
      local calls = executor.parse_tool_calls(response)
      assert.equals(1, #calls)
      assert.is_not_nil(calls[1].error)
    end)

    it("gibt Fehler-Entry zurück wenn 'tool'-Feld fehlt", function()
      local response = "```tool_call\n" .. vim.fn.json_encode({ action = "x" }) .. "\n```"
      local calls = executor.parse_tool_calls(response)
      assert.equals(1, #calls)
      assert.is_not_nil(calls[1].error)
    end)

    it("gibt leere Liste zurück wenn keine Blöcke vorhanden", function()
      local calls = executor.parse_tool_calls("Nur normaler Text, keine Tools.")
      assert.equals(0, #calls)
    end)

    it("parst Parameter korrekt", function()
      local response = make_block("create_file", { path = "src/a.lua", content = "-- x" })
      local calls = executor.parse_tool_calls(response)
      assert.equals("src/a.lua", calls[1].parameters.path)
      assert.equals("-- x",      calls[1].parameters.content)
    end)

    it("setzt leere Parameter-Tabelle wenn 'parameters' fehlt", function()
      local json = vim.fn.json_encode({ tool = "list_directory" })
      local response = "```tool_call\n" .. json .. "\n```"
      local calls = executor.parse_tool_calls(response)
      assert.is_table(calls[1].parameters)
    end)

  end)

  -- ── execute() — Whitelist-Check ────────────────────────────────────────────

  describe("execute() — Whitelist", function()

    it("erlaubt Tool das auf der Whitelist steht", function()
      local result = executor.execute(
        { tool = "list_directory", parameters = {} },
        { "list_directory", "read_file" }
      )
      assert.is_true(result.success)
    end)

    it("blockiert Tool das nicht auf der Whitelist steht", function()
      local result = executor.execute(
        { tool = "delete_file", parameters = { path = "x.txt" } },
        { "read_file", "list_directory" }
      )
      assert.is_false(result.success)
      assert.is_truthy(result.error:find("nicht erlaubt"))
    end)

    it("erlaubt alle Tools wenn keine Whitelist angegeben (nil)", function()
      local result = executor.execute(
        { tool = "list_directory", parameters = {} },
        nil
      )
      assert.is_true(result.success)
    end)

  end)

  -- ── execute() — unbekanntes Tool ──────────────────────────────────────────

  describe("execute() — unbekanntes Tool", function()

    it("gibt Fehler zurück bei unbekanntem Tool-Namen", function()
      local result = executor.execute({ tool = "launch_rocket", parameters = {} })
      assert.is_false(result.success)
      assert.is_truthy(result.error:find("Unbekanntes Tool"))
    end)

  end)

  -- ── execute() — Parse-Fehler weiterleiten ─────────────────────────────────

  describe("execute() — Fehler aus Parser", function()

    it("reicht Parse-Fehler als Fehler-Result weiter", function()
      local result = executor.execute({ error = "Ungültiges JSON" })
      assert.is_false(result.success)
      assert.equals("?", result.tool)
    end)

  end)

  -- ── execute() — Parameter-Validierung ────────────────────────────────────

  describe("execute() — Parametervalidierung", function()

    it("schlägt fehl wenn Pflichtparameter fehlt", function()
      -- create_file braucht 'path' und 'content'
      local result = executor.execute({
        tool       = "create_file",
        parameters = { content = "x" }  -- path fehlt
      })
      assert.is_false(result.success)
      assert.is_truthy(result.error:find("path"))
    end)

    it("schlägt fehl bei falschem Typ", function()
      local result = executor.execute({
        tool       = "create_file",
        parameters = { path = 123, content = "x" }  -- path soll string sein
      })
      assert.is_false(result.success)
    end)

    it("schlägt fehl bei ungültigem Enum-Wert", function()
      write(tmpdir .. "/f.txt", "x")
      local result = executor.execute({
        tool       = "edit_file",
        parameters = { path = "f.txt", content = "y", mode = "teleport" }
      })
      assert.is_false(result.success)
      assert.is_truthy(result.error:find("Erlaubt"))
    end)

    it("akzeptiert gültige Enum-Werte", function()
      write(tmpdir .. "/f.txt", "x")
      local result = executor.execute({
        tool       = "edit_file",
        parameters = { path = "f.txt", content = "y", mode = "append" }
      })
      assert.is_true(result.success)
    end)

  end)

  -- ── execute() — erfolgreiche Ausführung ──────────────────────────────────

  describe("execute() — erfolgreiche Ausführung", function()

    it("führt create_file aus und gibt Erfolg zurück", function()
      local result = executor.execute({
        tool       = "create_file",
        parameters = { path = "test.txt", content = "hello" }
      })
      assert.is_true(result.success)
      assert.equals("create_file", result.tool)
      assert.is_string(result.output)
    end)

    it("führt list_directory aus und gibt Dateinamen zurück", function()
      write(tmpdir .. "/listed.txt", "x")
      local result = executor.execute({
        tool       = "list_directory",
        parameters = {}
      })
      assert.is_true(result.success)
      assert.is_truthy(result.output:find("listed.txt"))
    end)

    it("result.error ist leer bei Erfolg", function()
      local result = executor.execute({
        tool       = "list_directory",
        parameters = {}
      })
      assert.equals("", result.error)
    end)

  end)

  -- ── execute_all() ─────────────────────────────────────────────────────────

  describe("execute_all()", function()

    it("führt mehrere Tools in Reihenfolge aus", function()
      local response =
        make_block("create_file", { path = "a.txt", content = "A" })
        .. "\n\n"
        .. make_block("create_file", { path = "b.txt", content = "B" })

      local results = executor.execute_all(response)
      assert.equals(2, #results)
      assert.is_true(results[1].success)
      assert.is_true(results[2].success)
    end)

    it("gibt leere Liste zurück wenn keine Tool-Blöcke vorhanden", function()
      local results = executor.execute_all("Kein Tool hier.")
      assert.equals(0, #results)
    end)

    it("fährt nach einem Fehler fort", function()
      -- Zweiter Aufruf: Datei existiert nicht → Fehler
      -- Dritter Aufruf: soll trotzdem ausgeführt werden
      write(tmpdir .. "/exists.txt", "x")
      local response =
        make_block("create_file", { path = "new1.txt", content = "x" })   -- OK
        .. "\n\n"
        .. make_block("delete_file", { path = "ghost.txt" })               -- Fehler
        .. "\n\n"
        .. make_block("create_file", { path = "new2.txt", content = "y" }) -- OK

      local results = executor.execute_all(response)
      assert.equals(3, #results)
      assert.is_true(results[1].success)
      assert.is_false(results[2].success)
      assert.is_true(results[3].success)
    end)

    it("respektiert Whitelist in execute_all", function()
      local response = make_block("delete_file", { path = "x.txt" })
      local results = executor.execute_all(response, { "read_file" })
      assert.is_false(results[1].success)
      assert.is_truthy(results[1].error:find("nicht erlaubt"))
    end)

  end)

  -- ── format_results() ─────────────────────────────────────────────────────

  describe("format_results()", function()

    it("gibt leeren String zurück bei keinen Ergebnissen", function()
      assert.equals("", executor.format_results({}))
    end)

    it("enthält Überschrift", function()
      local results = { { success = true, tool = "read_file", output = "x", error = "" } }
      local formatted = executor.format_results(results)
      assert.is_truthy(formatted:find("Tool%-Ergebnisse"))
    end)

    it("markiert Erfolge mit ✓", function()
      local results = { { success = true, tool = "read_file", output = "x", error = "" } }
      local formatted = executor.format_results(results)
      assert.is_truthy(formatted:find("✓"))
      assert.is_truthy(formatted:find("read_file"))
    end)

    it("markiert Fehler mit ✗ und enthält Fehlermeldung", function()
      local results = { { success = false, tool = "delete_file", output = "", error = "Nicht gefunden" } }
      local formatted = executor.format_results(results)
      assert.is_truthy(formatted:find("✗"))
      assert.is_truthy(formatted:find("Nicht gefunden"))
    end)

    it("enthält sowohl Erfolge als auch Fehler", function()
      local results = {
        { success = true,  tool = "create_file", output = "OK",    error = "" },
        { success = false, tool = "delete_file", output = "",      error = "Fehler" },
      }
      local formatted = executor.format_results(results)
      assert.is_truthy(formatted:find("✓"))
      assert.is_truthy(formatted:find("✗"))
    end)

  end)

end)
