vim.opt.rtp:append(vim.fn.getcwd())
local Controller = require("rime_toggle.controller")
local total = 0
local function check(name, run)
  local ok, err = pcall(run)
  assert(ok, name .. ": " .. tostring(err))
  total = total + 1
  print("PASS " .. name)
end

local function fixture(initial)
  local state = { context = "a", modes = { a = initial, b = false }, writes = {}, records = {} }
  local backend = {}
  function backend:context()
    return state.context
  end
  function backend:ascii()
    if state.read_error then
      return nil, "read failed"
    end
    return state.modes[state.context]
  end
  function backend:set_ascii(value)
    if state.write_error then
      return nil, "write failed"
    end
    state.modes[state.context] = value
    table.insert(state.writes, { state.context, value })
    return true
  end
  local leases = {}
  function leases:with_lock(context, run)
    return run({
      read = function()
        return state.records[context] and vim.deepcopy(state.records[context])
      end,
      write = function(_, record)
        if state.save_error then
          return nil, "save failed"
        end
        state.records[context] = vim.deepcopy(record)
        return true
      end,
      clear = function()
        state.records[context] = nil
        return true
      end,
    })
  end
  return state, Controller.new(backend, leases, "one"), Controller.new(backend, leases, "two")
end

check("Chinese survives Normal then text entry", function()
  local s, c = fixture(false)
  assert(c:update(false, false))
  assert(s.modes.a == true and s.records.a.owner == "one")
  assert(c:update(true, false))
  assert(s.modes.a == false and s.records.a == nil)
end)

check("user-selected ASCII is never converted to Chinese", function()
  local s, c = fixture(true)
  assert(c:update(false, false))
  assert(c:update(true, false))
  assert(c:focus(false, false))
  assert(s.modes.a == true and #s.writes == 0)
end)

check("same-context pane exit restores Chinese", function()
  local s, c = fixture(false)
  assert(c:update(false, false))
  assert(c:focus(false, false))
  assert(s.modes.a == false and s.records.a == nil)
  assert(c:focus(true, false))
  assert(s.modes.a == true)
end)

check("cross-window rollback waits for the original context", function()
  local s, c = fixture(false)
  assert(c:update(false, false))
  s.context = "b"
  assert(c:focus(false, false))
  assert(s.modes.a == true and s.modes.b == false and c.pending.a)
  assert(c:update(false, false))
  assert(s.modes.b == false)
  s.context = "a"
  assert(c:drain())
  assert(s.modes.a == false and not c.pending.a)
end)

check("late FocusLost cannot undo a new owner's Normal mode", function()
  local s, a, b = fixture(false)
  assert(a:update(false, false))
  assert(b:focus(true, false))
  assert(s.records.a.owner == "two")
  assert(a:focus(false, false))
  assert(s.modes.a == true and s.records.a.owner == "two")
  assert(b:focus(false, false))
  assert(s.modes.a == false)
end)

check("new Insert pane consumes the prior owner's override", function()
  local s, a, b = fixture(false)
  assert(a:update(false, false))
  assert(b:focus(true, true))
  assert(s.modes.a == false and not s.records.a)
  assert(a:focus(false, false))
  assert(s.modes.a == false)
end)

check("opposite focus ordering preserves the new owner", function()
  local s, a, b = fixture(false)
  assert(a:update(false, false))
  assert(a:focus(false, false))
  assert(b:focus(true, false))
  assert(s.modes.a == true and s.records.a.owner == "two")
end)

check("ordinary mode events cannot steal another pane's lease", function()
  local s, a, b = fixture(false)
  assert(a:update(false, false))
  assert(b:focus(true, false))
  assert(a:update(true, false))
  assert(s.modes.a == true and s.records.a.owner == "two")
end)

check("query failure is not interpreted as Chinese", function()
  local s, c = fixture(false)
  s.read_error = true
  local ok = c:update(false, false)
  assert(not ok and #s.writes == 0 and not s.records.a)
end)

check("no active Rime context produces no writes", function()
  local s, c = fixture(false)
  s.context = nil
  assert(not c:update(false, false))
  assert(#s.writes == 0)
end)

check("context change without focus cannot modify another window", function()
  local s, c = fixture(false)
  assert(c:update(false, false))
  s.context = "b"
  assert(not c:update(false, false))
  assert(s.modes.b == false)
end)

check("disabling releases an override and suppresses mode changes", function()
  local s, c = fixture(false)
  assert(c:update(false, false))
  assert(c:set_enabled(false))
  assert(c:update(false, false))
  assert(s.modes.a == false and not s.records.a)
end)

check("failed lease persistence prevents an untracked ASCII write", function()
  local s, c = fixture(false)
  s.save_error = true
  assert(not c:update(false, false))
  assert(#s.writes == 0 and s.modes.a == false)
end)

check("ambiguous write failure retains a recoverable rollback", function()
  local s, c = fixture(false)
  s.write_error = true
  assert(not c:update(false, false))
  assert(c.pending.a and s.records.a.owner == "one")
  s.write_error = false
  s.modes.a = true -- The timed-out write may actually have reached Fcitx.
  assert(c:focus(false, false))
  assert(s.modes.a == false and not s.records.a)
end)

check("failed takeover restoration remains owned and recoverable", function()
  local s, a, b = fixture(false)
  assert(a:update(false, false))
  s.write_error = true
  assert(not b:focus(true, true))
  assert(s.records.a.owner == "two" and b.pending.a)
  assert(a:focus(false, false))
  s.write_error = false
  assert(b:drain())
  assert(s.modes.a == false and not s.records.a)
end)

print(string.format("%d controller regressions passed", total))
