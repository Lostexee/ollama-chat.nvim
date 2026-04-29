-- tests/tools/sandbox_spec.lua

local sandbox = require("ollama-chat.tools.sandbox")

-- ─────────────────────────────────────────────────────────────────────────────
-- Hilfsfunktionen
-- ─────────────────────────────────────────────────────────────────────────────

--- Erstellt einen echten temporären Ordner und gibt seinen Pfad zurück.
local function make_tmpdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

--- Löscht einen temporären Ordner rekursiv.
local function rm_tmpdir(path)
  vim.fn.delete(path, "rf")
end

--- Setzt Sandbox zurück (interner State via Modul-Reload).
--- Da Lua Module cached, patchen wir direkt den internen State.
local function reset_sandbox()
  -- sandbox._workspace_root ist lokal (upvalue), daher neu laden:
  package.loaded["ollama-chat.tools.sandbox"] = nil
  sandbox = require("ollama-chat.tools.sandbox")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tests
-- ─────────────────────────────────────────────────────────────────────────────

describe("sandbox", function()

  local tmpdir

  before_each(function()
    tmpdir = make_tmpdir()
    reset_sandbox()
    sandbox.set_workspace(tmpdir)
  end)

  after_each(function()
    rm_tmpdir(tmpdir)
  end)

  -- ── set_workspace ──────────────────────────────────────────────────────────

  describe("set_workspace()", function()

    it("akzeptiert einen existierenden Ordner", function()
      assert.has_no.errors(function()
        sandbox.set_workspace(tmpdir)
      end)
    end)

    it("schlägt fehl wenn der Pfad nicht existiert", function()
      assert.has_error(function()
        sandbox.set_workspace("/dieser/pfad/existiert/garantiert/nicht")
      end)
    end)

    it("schlägt fehl wenn der Pfad eine Datei ist", function()
      local file = tmpdir .. "/testfile.txt"
      io.open(file, "w"):close()
      assert.has_error(function()
        sandbox.set_workspace(file)
      end)
    end)

    it("normalisiert trailing slashes", function()
      sandbox.set_workspace(tmpdir .. "/")
      -- get_workspace() darf keinen trailing slash haben
      local ws = sandbox.get_workspace()
      assert.is_false(ws:sub(-1) == "/",
        "get_workspace() darf nicht mit / enden")
    end)

  end)

  -- ── get_workspace ──────────────────────────────────────────────────────────

  describe("get_workspace()", function()

    it("gibt den gesetzten Workspace zurück", function()
      local ws = sandbox.get_workspace()
      -- Vergleich nach Auflösung (resolve entfernt trailing slashes)
      assert.equals(vim.fn.resolve(tmpdir), ws)
    end)

    it("wirft Fehler wenn kein Workspace gesetzt wurde", function()
      reset_sandbox()  -- State zurücksetzen ohne set_workspace
      assert.has_error(function()
        sandbox.get_workspace()
      end)
    end)

  end)

  -- ── resolve() — gültige Pfade ──────────────────────────────────────────────

  describe("resolve() — gültige Pfade", function()

    it("löst einen einfachen relativen Pfad auf", function()
      local result = sandbox.resolve("foo/bar.txt")
      assert.equals(tmpdir .. "/foo/bar.txt", result)
    end)

    it("löst den Workspace-Root selbst auf (Punkt)", function()
      local result = sandbox.resolve(".")
      assert.equals(tmpdir, result)
    end)

    it("löst einen Pfad direkt im Root auf", function()
      local result = sandbox.resolve("file.lua")
      assert.equals(tmpdir .. "/file.lua", result)
    end)

    it("akzeptiert verschachtelte Pfade", function()
      local result = sandbox.resolve("a/b/c/d.txt")
      assert.equals(tmpdir .. "/a/b/c/d.txt", result)
    end)

    it("löst harmlose ./ Präfixe auf", function()
      local result = sandbox.resolve("./src/main.lua")
      assert.equals(tmpdir .. "/src/main.lua", result)
    end)

  end)

  -- ── resolve() — Path-Traversal-Angriffe ───────────────────────────────────

  describe("resolve() — Path-Traversal blockiert", function()

    it("blockiert einfaches ../", function()
      assert.has_error(function()
        sandbox.resolve("../secret.txt")
      end)
    end)

    it("blockiert verschachteltes ../../", function()
      assert.has_error(function()
        sandbox.resolve("subdir/../../etc/passwd")
      end)
    end)

    it("blockiert absoluten Pfad außerhalb des Workspace", function()
      assert.has_error(function()
        sandbox.resolve("/etc/passwd")
      end)
    end)

    it("blockiert absoluten Pfad mit Workspace-Präfix aber danach ..", function()
      -- z. B. /tmp/ws/../other — soll blockiert werden
      local evil = tmpdir .. "/../evil"
      assert.has_error(function()
        sandbox.resolve(evil)
      end)
    end)

    it("blockiert Pfad der tief beginnt und sich dann herausarbeitet", function()
      assert.has_error(function()
        sandbox.resolve("a/b/../../../outside")
      end)
    end)

    it("blockiert leeren Pfad der auf Parent verweist", function()
      assert.has_error(function()
        sandbox.resolve("..")
      end)
    end)

  end)

  -- ── is_safe() ─────────────────────────────────────────────────────────────

  describe("is_safe()", function()

    it("gibt true für Pfade innerhalb des Workspace zurück", function()
      assert.is_true(sandbox.is_safe(tmpdir .. "/some/file.txt"))
    end)

    it("gibt true für den Workspace-Root selbst zurück", function()
      assert.is_true(sandbox.is_safe(tmpdir))
    end)

    it("gibt false für Pfade außerhalb zurück", function()
      assert.is_false(sandbox.is_safe("/etc/passwd"))
    end)

    it("gibt false wenn kein Workspace gesetzt (kein Crash)", function()
      reset_sandbox()
      assert.is_false(sandbox.is_safe(tmpdir .. "/file.txt"))
    end)

  end)

end)
