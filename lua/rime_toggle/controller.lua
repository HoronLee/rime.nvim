local Controller = {}
Controller.__index = Controller

function Controller.new(backend, leases, owner)
  return setmetatable({
    backend = backend,
    leases = leases,
    owner = owner,
    enabled = true,
    focused = true,
    editable = true,
    context = nil,
    pending = {},
  }, Controller)
end

-- Fcitx exposes only the most recent context. Check again immediately before
-- a write, but do not claim atomicity: the D-Bus API has no context argument.
function Controller:set_ascii(context, value)
  local current, err = self.backend:context()
  if current ~= context then
    return nil, err or "input context changed"
  end
  return self.backend:set_ascii(value)
end

function Controller:release(context)
  return self.leases:with_lock(context, function(lease)
    local record, err = lease:read()
    if err then
      return nil, err
    end
    if not record or record.owner ~= self.owner then
      self.pending[context] = nil
      return true
    end
    -- Keep the rollback for when this context becomes focused again. Never
    -- restore the old window's Chinese state into the newly focused window.
    if self.backend:context() ~= context then
      return true
    end
    local ascii, read_err = self.backend:ascii()
    if ascii == nil then
      return nil, read_err
    end
    if ascii then
      local ok, write_err = self:set_ascii(context, false)
      if not ok then
        return nil, write_err
      end
    end
    local ok, clear_err = lease:clear()
    if ok then
      self.pending[context] = nil
    end
    return ok, clear_err
  end)
end

function Controller:drain()
  local first_error
  for context in pairs(self.pending) do
    if not (self.enabled and self.focused and not self.editable and self.context == context) then
      local _, err = self:release(context)
      first_error = first_error or err
    end
  end
  return first_error == nil, first_error
end

function Controller:update(editable, acquire)
  self.editable = editable
  if not self.enabled or not self.focused then
    return self:drain()
  end
  local context, err = self.backend:context()
  if not context then
    return nil, err
  end
  if self.context and context ~= self.context and not acquire then
    return nil, "input context changed without FocusGained"
  end
  self.context = context
  local ok, update_err = self.leases:with_lock(context, function(lease)
    local record, read_err = lease:read()
    if read_err then
      return nil, read_err
    end
    -- Only a real focus acquisition may take over another Nvim's override.
    -- This makes either ordering of old FocusLost/new FocusGained safe.
    if record and record.owner ~= self.owner and not acquire then
      return true
    end
    if record and record.owner ~= self.owner then
      local claimed, claim_err = lease:write({ owner = self.owner })
      if not claimed then
        return nil, claim_err
      end
      record.owner = self.owner
      self.pending[context] = true
    end
    if self.backend:context() ~= context then
      return nil, "input context changed"
    end
    if editable and not record then
      return true
    end
    local ascii, state_err = self.backend:ascii()
    if ascii == nil then
      return nil, state_err
    end
    if editable then
      if ascii then
        local restored, restore_err = self:set_ascii(context, false)
        if not restored then
          return nil, restore_err
        end
      end
      local cleared, clear_err = lease:clear()
      if cleared then
        self.pending[context] = nil
      end
      return cleared, clear_err
    end
    if record or not ascii then
      local saved, save_err = lease:write({ owner = self.owner })
      if not saved then
        return nil, save_err
      end
      -- Persist before setting ASCII: a timeout may mean that Fcitx applied
      -- the write but its reply was lost. The rollback must survive that.
      self.pending[context] = true
      if not ascii then
        return self:set_ascii(context, true)
      end
    end
    return true
  end)
  local _, drain_err = self:drain()
  return ok, update_err or drain_err
end

function Controller:focus(gained, editable)
  self.focused = gained
  if gained then
    self.context = nil
    return self:update(editable, true)
  end
  return self:drain()
end

function Controller:set_enabled(enabled)
  self.enabled = enabled
  if not enabled then
    return self:drain()
  end
  return true
end

return Controller
