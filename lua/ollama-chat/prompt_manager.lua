-- lua/ollama-chat/prompt_manager.lua
-- Waehlt automatisch einen kurzen oder langen System-Prompt
-- basierend auf dem aktiven Modellnamen.
--
-- Konfiguration in setup():
--   prompt_mode = "auto"   -- "small" | "large" | "auto"
--   prompt_auto_threshold = 13  -- ab wieviel B gilt "large"
--
-- Auto-Logik:
--   1. Enthaelt der Name ein Cloud-Keyword (claude, gpt, gemini...)? -> large
--   2. Enthaelt der Name eine Parameteranzahl (7b, 13b, 70b...)?
--      >= threshold -> large,  < threshold -> small
--   3. Nicht erkennbar -> small (sicherer Fallback)

local M_ref = nil
local M = {}

function M.init(main)
  M_ref = main
end

-- ============================================
-- PROMPTS
-- ============================================

M.small_prompt =
  "You are a helpful coding assistant. " ..
  "Answer concisely and precisely. " ..
  "Always output code in markdown code blocks."

M.large_prompt =
  "You are an experienced senior software developer and coding assistant.\n\n" ..
  "BEHAVIOR:\n" ..
  "- Always answer in the same language the user writes in.\n" ..
  "- Briefly explain your approach before providing code.\n" ..
  "- Point out potential problems, edge cases and performance issues.\n" ..
  "- Suggest better alternatives if you know them.\n\n" ..
  "CODE QUALITY:\n" ..
  "- Write clean, readable and maintainable code.\n" ..
  "- Follow best practices of the respective language.\n" ..
  "- Comment complex parts clearly.\n" ..
  "- Use descriptive variable and function names.\n\n" ..
  "FORMAT:\n" ..
  "- Always wrap code in markdown code blocks with language tag.\n" ..
  "- For multiple files, separate them with headings.\n" ..
  "- Number steps in instructions.\n\n" ..
  "RESTRICTIONS:\n" ..
  "- Never invent libraries or APIs that do not exist.\n" ..
  "- If you are unsure, say so clearly."

-- ============================================
-- HILFSFUNKTIONEN
-- ============================================

local CLOUD_KEYWORDS = {
  "claude", "gpt", "gemini", "palm", "titan",
  "mistral-large", "command-r-plus",
}

local function is_cloud_model(name)
  local lower = name:lower()
  for _, kw in ipairs(CLOUD_KEYWORDS) do
    if lower:find(kw, 1, true) then return true end
  end
  return false
end

-- Gibt Parameteranzahl in Milliarden zurueck oder nil
-- Beispiele: "llama3:7b"->7  "mixtral-8x7b"->56  "qwen2.5:123b"->123
local function extract_params(name)
  local lower = name:lower()
  -- Mixture-of-Experts: 8x7b -> 56
  local experts, per = lower:match("(%d+)x(%d+)b")
  if experts and per then
    return tonumber(experts) * tonumber(per)
  end
  -- Normal: 7b, 13b, 70b, 123b
  local p = lower:match("(%d+%.?%d*)b")
  if p then return tonumber(p) end
  return nil
end

-- ============================================
-- OEFFENTLICHE API
-- ============================================

-- Gibt den passenden System-Prompt als String zurueck
function M.get(model_name)
  if not model_name then return M.small_prompt end

  local mode      = (M_ref and M_ref.config.prompt_mode) or "auto"
  local threshold = (M_ref and M_ref.config.prompt_auto_threshold) or 13

  if mode == "small" then return M.small_prompt end
  if mode == "large" then return M.large_prompt end

  -- AUTO
  if is_cloud_model(model_name) then return M.large_prompt end

  local params = extract_params(model_name)
  if params then
    return params >= threshold and M.large_prompt or M.small_prompt
  end

  return M.small_prompt  -- Fallback
end

-- Gibt "small" oder "large" als Label zurueck (fuer Statusline)
function M.label(model_name)
  return M.get(model_name) == M.large_prompt and "large" or "small"
end

return M
