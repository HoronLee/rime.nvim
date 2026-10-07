local M = {}
local controller, backend, timer, retry_acquire

local function editable(mode)
  return mode:match("^[iRct]") ~= nil
end

local function report(err)
  if err and err ~= "lease lock busy" then
    vim.notify_once("rime.nvim: " .. err, vim.log.levels.WARN)
  end
end

local function tick()
  if controller then
    if retry_acquire ~= nil and controller.enabled and controller.focused then
      local _, retry_err = controller:update(editable(vim.api.nvim_get_mode().mode), retry_acquire)
      if retry_err ~= "lease lock busy" then
        retry_acquire = nil
      end
      report(retry_err)
    end
    local _, err = controller:drain()
    report(err)
    if next(controller.pending) == nil and retry_acquire == nil and timer then
      timer:stop()
    end
  end
end

local function track_pending()
  -- Finish deferred rollbacks and serialize simultaneous pane transitions.
  -- Once the original context returns, restore even if focus is on a shell.
  if next(controller.pending) ~= nil or retry_acquire ~= nil then
    if not timer then
      timer = vim.uv.new_timer()
    end
    if not timer:is_active() then
      timer:start(100, 100, vim.schedule_wrap(tick))
    end
  elseif timer then
    timer:stop()
  end
end

local function update(mode, acquire)
  if controller then
    local _, err = controller:update(editable(mode), acquire)
    if err == "lease lock busy" then
      retry_acquire = acquire
    else
      retry_acquire = nil
    end
    report(err)
    track_pending()
  end
end

function M.enable()
  if controller then
    controller:set_enabled(true)
    if #vim.api.nvim_list_uis() > 0 then
      update(vim.api.nvim_get_mode().mode, false)
    end
  end
end

function M.disable()
  if controller then
    retry_acquire = nil
    local _, err = controller:set_enabled(false)
    report(err)
    track_pending()
  end
end

function M.toggle()
  if controller and controller.enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.setup(opts)
  opts = opts or {}
  if controller then
    if opts.enabled ~= nil then
      if opts.enabled then
        M.enable()
      else
        M.disable()
      end
    end
    return
  end
  -- A remote/headless editor must not alter the local desktop's input method.
  if vim.fn.has("linux") ~= 1 or vim.env.SSH_TTY or vim.env.SSH_CONNECTION
    or not (vim.env.DISPLAY or vim.env.WAYLAND_DISPLAY) then
    return
  end
  local err
  backend, err = require("rime_toggle.dbus").new()
  if not backend then
    report(err)
    return
  end
  local leases
  leases, err = require("rime_toggle.lease").new()
  if not leases then
    backend:close()
    backend = nil
    report(err)
    return
  end
  local owner = tostring(vim.fn.getpid()) .. ":" .. tostring(vim.uv.hrtime())
  controller = require("rime_toggle.controller").new(backend, leases, owner)
  controller.enabled = opts.enabled ~= false
  local group = vim.api.nvim_create_augroup("RimeAutoMode", { clear = true })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      if #vim.api.nvim_list_uis() > 0 and
        editable(vim.v.event.old_mode) ~= editable(vim.v.event.new_mode) then
        update(vim.v.event.new_mode, false)
      end
    end,
    desc = "Temporarily use ASCII outside text entry",
  })
  vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost", "VimSuspend", "VimResume" }, {
    group = group,
    callback = function(event)
      if #vim.api.nvim_list_uis() == 0 then
        return
      end
      local gained = event.event == "FocusGained" or event.event == "VimResume"
      local _, focus_err = controller:focus(gained, editable(vim.api.nvim_get_mode().mode))
      retry_acquire = gained and focus_err == "lease lock busy" and true or nil
      report(focus_err)
      track_pending()
    end,
    desc = "Restore the original context on focus loss or suspend",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      controller:focus(false, true)
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end
      backend:close()
      controller = nil
      backend = nil
    end,
    desc = "Release Rime override and D-Bus connection",
  })
end

return M
