-- tests/tools/definitions_spec.lua

local sandbox     = require("ollama-chat.tools.sandbox")
local definitions = require("ollama-chat.tools.definitions")

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

--- Schreibt eine Datei direkt (ohne Tool) — für Test-Setup.
local function write(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

--- Liest eine Datei direkt — für Assertions.
local function read(path)
  local f = assert(io.open(path, "r"))
  local c = f:read("*a")
  f:close()
  return c
end

--- Ruft einen Tool-Handler direkt auf.
local function call(tool_name, params)
  local tool = definitions.get(tool_name)
  assert(tool, "Tool nicht gefunden: " .. tool_name)
  return tool.handler(params)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tests
-- ─────────────────────────────────────────────────────────────────────────────

describe("definitions", function()

  local tmpdir

  before_each(function()
    tmpdir = make_tmpdir()
    package.loaded["ollama-chat.tools.sandbox"] = nil
    sandbox = require("ollama-chat.tools.sandbox")
    sandbox.set_workspace(tmpdir)

    -- definitions neu laden damit es die frische sandbox-Instanz nutzt
    package.loaded["ollama-chat.tools.definitions"] = nil
    definitions = require("ollama-chat.tools.definitions")
  end)

  after_each(function()
    rm_tmpdir(tmpdir)
  end)

  -- ── definitions.get() ─────────────────────────────────────────────────────

  describe("get()", function()

    it("findet ein existierendes Tool", function()
      local t = definitions.get("create_file")
      assert.is_not_nil(t)
      assert.equals("create_file", t.name)
    end)

    it("gibt nil für unbekannte Tools zurück", function()
      assert.is_nil(definitions.get("fly_to_moon"))
    end)

  end)

  -- ── definitions.schemas() ─────────────────────────────────────────────────

  describe("schemas()", function()

    it("gibt alle Tools zurück wenn keine Whitelist angegeben", function()
      local s = definitions.schemas()
      assert.is_true(#s >= 6)  -- mindestens die 6 definierten Tools
    end)

    it("filtert nach Tool-Namen", function()
      local s = definitions.schemas({ "read_file", "create_file" })
      assert.equals(2, #s)
      assert.equals("read_file",   s[1].name)
      assert.equals("create_file", s[2].name)
    end)

    it("enthält kein 'handler'-Feld (nur für den Prompt gedacht)", function()
      local s = definitions.schemas()
      for _, schema in ipairs(s) do
        assert.is_nil(schema.handler, "Schema enthält handler: " .. schema.name)
      end
    end)

    it("jedes Schema hat name, description und parameters", function()
      for _, schema in ipairs(definitions.schemas()) do
        assert.is_string(schema.name,        schema.name .. ".name fehlt")
        assert.is_string(schema.description, schema.name .. ".description fehlt")
        assert.is_table(schema.parameters,   schema.name .. ".parameters fehlt")
      end
    end)

  end)

  -- ── read_file ─────────────────────────────────────────────────────────────

  describe("read_file", function()

    it("liest eine existierende Datei", function()
      write(tmpdir .. "/hello.txt", "Inhalt hier")
      local result = call("read_file", { path = "hello.txt" })
      assert.equals("Inhalt hier", result)
    end)

    it("liest mehrzeiligen Inhalt korrekt", function()
      write(tmpdir .. "/multi.txt", "Zeile 1\nZeile 2\nZeile 3")
      local result = call("read_file", { path = "multi.txt" })
      assert.equals("Zeile 1\nZeile 2\nZeile 3", result)
    end)

    it("schlägt fehl bei nicht existierender Datei", function()
      assert.has_error(function()
        call("read_file", { path = "ghost.txt" })
      end)
    end)

    it("schlägt fehl bei Pfad-Traversal", function()
      assert.has_error(function()
        call("read_file", { path = "../outside.txt" })
      end)
    end)

    it("schlägt fehl wenn Pfad ein Ordner ist", function()
      vim.fn.mkdir(tmpdir .. "/mydir", "p")
      assert.has_error(function()
        call("read_file", { path = "mydir" })
      end)
    end)

  end)

  -- ── create_file ───────────────────────────────────────────────────────────

  describe("create_file", function()

    it("erstellt eine neue Datei", function()
      call("create_file", { path = "new.txt", content = "Hallo" })
      assert.equals("Hallo", read(tmpdir .. "/new.txt"))
    end)

    it("erstellt Datei in nicht-existentem Unterordner", function()
      call("create_file", { path = "a/b/c.txt", content = "tief" })
      assert.equals("tief", read(tmpdir .. "/a/b/c.txt"))
    end)

    it("schlägt fehl wenn Datei bereits existiert", function()
      write(tmpdir .. "/existing.txt", "alt")
      assert.has_error(function()
        call("create_file", { path = "existing.txt", content = "neu" })
      end)
      -- Originaldatei muss unberührt bleiben
      assert.equals("alt", read(tmpdir .. "/existing.txt"))
    end)

    it("schlägt fehl bei Pfad-Traversal", function()
      assert.has_error(function()
        call("create_file", { path = "../evil.txt", content = "x" })
      end)
    end)

    it("Rückgabewert enthält den Pfad", function()
      local result = call("create_file", { path = "info.txt", content = "" })
      assert.is_truthy(result:find("info.txt"))
    end)

  end)

  -- ── edit_file ─────────────────────────────────────────────────────────────

  describe("edit_file", function()

    before_each(function()
      write(tmpdir .. "/edit_me.txt", "Original")
    end)

    it("überschreibt eine Datei (overwrite, Standard)", function()
      call("edit_file", { path = "edit_me.txt", content = "Neu" })
      assert.equals("Neu", read(tmpdir .. "/edit_me.txt"))
    end)

    it("überschreibt eine Datei explizit (overwrite)", function()
      call("edit_file", { path = "edit_me.txt", content = "Neu", mode = "overwrite" })
      assert.equals("Neu", read(tmpdir .. "/edit_me.txt"))
    end)

    it("hängt Inhalt an (append)", function()
      call("edit_file", { path = "edit_me.txt", content = "\nAnhang", mode = "append" })
      assert.equals("Original\nAnhang", read(tmpdir .. "/edit_me.txt"))
    end)

    it("schlägt fehl wenn Datei nicht existiert", function()
      assert.has_error(function()
        call("edit_file", { path = "ghost.txt", content = "x" })
      end)
    end)

    it("schlägt fehl bei Pfad-Traversal", function()
      assert.has_error(function()
        call("edit_file", { path = "../../etc/cron.d/evil", content = "x" })
      end)
    end)

  end)

  -- ── delete_file ───────────────────────────────────────────────────────────

  describe("delete_file", function()

    it("löscht eine existierende Datei", function()
      write(tmpdir .. "/del.txt", "weg")
      call("delete_file", { path = "del.txt" })
      assert.is_nil(vim.loop.fs_stat(tmpdir .. "/del.txt"))
    end)

    it("schlägt fehl wenn Datei nicht existiert", function()
      assert.has_error(function()
        call("delete_file", { path = "nope.txt" })
      end)
    end)

    it("schlägt fehl wenn Pfad ein Ordner ist", function()
      vim.fn.mkdir(tmpdir .. "/mydir", "p")
      assert.has_error(function()
        call("delete_file", { path = "mydir" })
      end)
    end)

    it("schlägt fehl bei Pfad-Traversal", function()
      assert.has_error(function()
        call("delete_file", { path = "../wichtig.txt" })
      end)
    end)

  end)

  -- ── create_directory ──────────────────────────────────────────────────────

  describe("create_directory", function()

    it("erstellt einen Ordner", function()
      call("create_directory", { path = "newdir" })
      local stat = vim.loop.fs_stat(tmpdir .. "/newdir")
      assert.is_not_nil(stat)
      assert.equals("directory", stat.type)
    end)

    it("erstellt verschachtelte Ordner", function()
      call("create_directory", { path = "a/b/c" })
      local stat = vim.loop.fs_stat(tmpdir .. "/a/b/c")
      assert.is_not_nil(stat)
      assert.equals("directory", stat.type)
    end)

    it("schlägt bei bereits existierendem Ordner nicht fehl (idempotent)", function()
      vim.fn.mkdir(tmpdir .. "/exists", "p")
      assert.has_no.errors(function()
        call("create_directory", { path = "exists" })
      end)
    end)

    it("schlägt fehl bei Pfad-Traversal", function()
      assert.has_error(function()
        call("create_directory", { path = "../evil_dir" })
      end)
    end)

  end)

  -- ── list_directory ────────────────────────────────────────────────────────

  describe("list_directory", function()

    before_each(function()
      write(tmpdir .. "/file_a.txt", "a")
      write(tmpdir .. "/file_b.txt", "b")
      vim.fn.mkdir(tmpdir .. "/subdir", "p")
    end)

    it("listet den Workspace-Root (Standard: '.')", function()
      local result = call("list_directory", {})
      assert.is_truthy(result:find("file_a.txt"))
      assert.is_truthy(result:find("file_b.txt"))
      assert.is_truthy(result:find("subdir"))
    end)

    it("markiert Ordner mit [dir] und Dateien mit [file]", function()
      local result = call("list_directory", {})
      assert.is_truthy(result:find("%[dir%].*subdir") or result:find("subdir.*%[dir%]"))
      assert.is_truthy(result:find("%[file%].*file_a") or result:find("file_a.*%[file%]"))
    end)

    it("listet einen Unterordner", function()
      write(tmpdir .. "/subdir/inner.txt", "x")
      local result = call("list_directory", { path = "subdir" })
      assert.is_truthy(result:find("inner.txt"))
      assert.is_falsy(result:find("file_a.txt"))  -- nur Unterordner-Inhalt
    end)

    it("schlägt fehl bei nicht-existentem Ordner", function()
      assert.has_error(function()
        call("list_directory", { path = "ghost_dir" })
      end)
    end)

    it("schlägt fehl bei Pfad-Traversal", function()
      assert.has_error(function()
        call("list_directory", { path = "../" })
      end)
    end)

  end)

  -- ── move_file ─────────────────────────────────────────────────────────────

  describe("move_file", function()

    before_each(function()
      write(tmpdir .. "/original.txt", "Inhalt")
    end)

    it("verschiebt eine Datei", function()
      call("move_file", { source = "original.txt", destination = "moved.txt" })
      assert.is_nil(vim.loop.fs_stat(tmpdir .. "/original.txt"))
      assert.equals("Inhalt", read(tmpdir .. "/moved.txt"))
    end)

    it("verschiebt in einen Unterordner", function()
      vim.fn.mkdir(tmpdir .. "/sub", "p")
      call("move_file", { source = "original.txt", destination = "sub/original.txt" })
      assert.equals("Inhalt", read(tmpdir .. "/sub/original.txt"))
    end)

    it("erstellt Ziel-Unterordner automatisch", function()
      call("move_file", { source = "original.txt", destination = "new/sub/file.txt" })
      assert.equals("Inhalt", read(tmpdir .. "/new/sub/file.txt"))
    end)

    it("schlägt fehl wenn Quelle nicht existiert", function()
      assert.has_error(function()
        call("move_file", { source = "ghost.txt", destination = "dest.txt" })
      end)
    end)

    it("blockiert Pfad-Traversal in der Quelle", function()
      assert.has_error(function()
        call("move_file", { source = "../outside.txt", destination = "dest.txt" })
      end)
    end)

    it("blockiert Pfad-Traversal im Ziel", function()
      assert.has_error(function()
        call("move_file", { source = "original.txt", destination = "../outside.txt" })
      end)
    end)

  end)

end)
