-- lua/ollama-chat/http.lua
-- HTTP Utilities (async + streaming via curl)

local uv = vim.loop

local M = {}

function M.request_async(url, method, body, callback)
  local curl_args = {
    "-s", "--max-time", "30",
    "-X", method,
    "-H", "Content-Type: application/json",
  }

  if body then
    table.insert(curl_args, "-d")
    table.insert(curl_args, vim.json.encode(body))
  end

  table.insert(curl_args, url)

  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle = nil
  local stdout_data = ""
  local stderr_data = ""

  handle = uv.spawn("curl", {
    args = curl_args,
    stdio = {nil, stdout, stderr}
  }, function(code, signal)
    stdout:close()
    stderr:close()
    handle:close()

    vim.schedule(function()
      if code == 0 and stdout_data ~= "" then
        local success, result = pcall(vim.json.decode, stdout_data)
        if success then
          callback(result, nil)
        else
          callback(nil, "JSON decode error: " .. tostring(result))
        end
      else
        callback(nil, stderr_data ~= "" and stderr_data or "Request failed (code=" .. code .. ")")
      end
    end)
  end)

  if not handle then
    callback(nil, "Failed to spawn curl")
    return
  end

  stdout:read_start(function(err, data)
    if data then stdout_data = stdout_data .. data end
  end)

  stderr:read_start(function(err, data)
    if data then stderr_data = stderr_data .. data end
  end)

  return handle
end

function M.request_stream(url, method, body, on_data, on_complete)
  local curl_args = {
    "-s", "-N", "--max-time", "120",
    "-X", method,
    "-H", "Content-Type: application/json",
  }

  if body then
    table.insert(curl_args, "-d")
    table.insert(curl_args, vim.json.encode(body))
  end

  table.insert(curl_args, url)

  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle = nil
  local stderr_data = ""

  handle = uv.spawn("curl", {
    args = curl_args,
    stdio = {nil, stdout, stderr}
  }, function(code, signal)
    stdout:close()
    stderr:close()
    handle:close()

    vim.schedule(function()
      if on_complete then
        on_complete(code == 0, stderr_data)
      end
    end)
  end)

  if not handle then
    if on_complete then
      vim.schedule(function() on_complete(false, "Failed to spawn curl") end)
    end
    return
  end

  local buffer = ""
  stdout:read_start(function(err, data)
    if data then
      buffer = buffer .. data
      while true do
        local newline_pos = buffer:find("\n")
        if not newline_pos then break end
        local line = buffer:sub(1, newline_pos - 1)
        buffer = buffer:sub(newline_pos + 1)
        if line ~= "" then
          local success, json_data = pcall(vim.json.decode, line)
          if success and on_data then
            vim.schedule(function() on_data(json_data) end)
          end
        end
      end
    end
  end)

  stderr:read_start(function(err, data)
    if data then stderr_data = stderr_data .. data end
  end)

  return handle
end

return M
