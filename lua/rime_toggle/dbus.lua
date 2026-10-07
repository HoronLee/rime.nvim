-- Internal API: new() -> client | nil, error; ascii() -> boolean | nil, error;
-- set_ascii(boolean) -> true | nil, error; close() is idempotent.
-- context() -> focused Rime UUID | nil [, error]. Inactive/ambiguous focus is normal.
local M = {}
local Client = {}
Client.__index = Client

local ffi_ok, ffi = pcall(require, "ffi")
local dbus
local TYPE_INVALID, TYPE_BOOLEAN, TYPE_STRING
local DESTINATION = "org.fcitx.Fcitx5"
local CONTROLLER = "org.fcitx.Fcitx.Controller1"
local RIME = "org.fcitx.Fcitx.Rime1"
local TIMEOUT_MS = 100

local function load_backend()
  if not ffi_ok then
    return nil, "LuaJIT FFI is unavailable: " .. tostring(ffi)
  end

  -- The private storage type is also an initialization marker across Lua reloads.
  -- Do not allocate DBusError itself: another plugin may have declared its ABI wrong.
  if not pcall(ffi.typeof, "RimeToggleDBusErrorStorage") then
    local ok, err = pcall(ffi.cdef, [[
      typedef struct DBusConnection DBusConnection;
      typedef struct DBusMessage DBusMessage;
      typedef struct DBusError DBusError;
      DBusConnection *dbus_bus_get_private(int type, DBusError *error);
      void dbus_connection_set_exit_on_disconnect(DBusConnection *connection, unsigned int enabled);
      unsigned int dbus_connection_get_is_connected(DBusConnection *connection);
      void dbus_connection_close(DBusConnection *connection);
      void dbus_connection_unref(DBusConnection *connection);
      DBusMessage *dbus_message_new_method_call(const char *destination, const char *path,
                                                const char *interface, const char *method);
      void dbus_message_unref(DBusMessage *message);
      unsigned int dbus_message_append_args(DBusMessage *message, int first_arg_type, ...);
      unsigned int dbus_message_get_args(DBusMessage *message, DBusError *error, int first_arg_type, ...);
      int dbus_message_get_type(DBusMessage *message);
      unsigned int dbus_message_has_signature(DBusMessage *message, const char *signature);
      const char *dbus_message_get_signature(DBusMessage *message);
      DBusMessage *dbus_connection_send_with_reply_and_block(DBusConnection *connection,
                                                            DBusMessage *message,
                                                            int timeout_milliseconds, DBusError *error);
      void dbus_error_init(DBusError *error);
      void dbus_error_free(DBusError *error);
      typedef struct {
        const char *name;
        const char *message;
        unsigned int dummy1 : 1;
        unsigned int dummy2 : 1;
        unsigned int dummy3 : 1;
        unsigned int dummy4 : 1;
        unsigned int dummy5 : 1;
        void *padding1;
      } RimeToggleDBusErrorStorage;
    ]])
    if not ok then
      return nil, "Cannot declare libdbus FFI: " .. tostring(err)
    end
  end

  local ok, library = pcall(ffi.load, "libdbus-1.so.3")
  if not ok then
    return nil, "Cannot load libdbus: " .. tostring(library)
  end
  dbus = library
  -- Lua numbers become doubles in C varargs; terminators must be native ints.
  TYPE_INVALID = ffi.cast("int", 0)
  TYPE_BOOLEAN = ffi.cast("int", 98)
  TYPE_STRING = ffi.cast("int", 115)
  return true
end

local function take_error(storage, pointer, fallback)
  local name, message = storage[0].name, storage[0].message
  local text = fallback
  if name ~= nil then
    text = fallback .. ": " .. ffi.string(name)
    if message ~= nil then
      text = text .. " (" .. ffi.string(message) .. ")"
    end
  elseif message ~= nil then
    text = fallback .. ": " .. ffi.string(message)
  end
  dbus.dbus_error_free(pointer)
  return text
end

local function release_connection(connection)
  dbus.dbus_connection_close(connection)
  dbus.dbus_connection_unref(connection)
end

function Client:close()
  if self._connection ~= nil then
    local connection = self._connection
    self._connection = nil
    ffi.gc(connection, nil)
    release_connection(connection)
  end
end

-- Synchronous calls do not yield; each client can reuse its native argument buffers.
function Client:_call(path, interface, method, signature, value)
  local connection = self._connection
  if connection == nil then
    return nil, "D-Bus connection is closed"
  end
  if dbus.dbus_connection_get_is_connected(connection) == 0 then
    self:close()
    return nil, "D-Bus session connection is disconnected"
  end

  local message = dbus.dbus_message_new_method_call(DESTINATION, path, interface, method)
  if message == nil then
    return nil, method .. ": cannot allocate D-Bus message"
  end
  if value ~= nil then
    self._boolean[0] = value and 1 or 0
    if dbus.dbus_message_append_args(message, TYPE_BOOLEAN,
        ffi.cast("const unsigned int *", self._boolean), TYPE_INVALID) == 0 then
      dbus.dbus_message_unref(message)
      return nil, method .. ": cannot append D-Bus boolean"
    end
  end

  dbus.dbus_error_init(self._error_pointer)
  local reply = dbus.dbus_connection_send_with_reply_and_block(connection, message, TIMEOUT_MS, self._error_pointer)
  dbus.dbus_message_unref(message)
  if reply == nil then
    local err = take_error(self._error, self._error_pointer, method .. ": D-Bus call failed")
    if dbus.dbus_connection_get_is_connected(connection) == 0 then
      self:close()
    end
    return nil, err
  end
  dbus.dbus_error_free(self._error_pointer)

  if dbus.dbus_message_get_type(reply) ~= 2 then
    dbus.dbus_message_unref(reply)
    return nil, method .. ": expected a D-Bus method return"
  end
  if dbus.dbus_message_has_signature(reply, signature) == 0 then
    local actual = ffi.string(dbus.dbus_message_get_signature(reply))
    dbus.dbus_message_unref(reply)
    return nil, method .. ": expected reply signature '" .. signature .. "', got '" .. actual .. "'"
  end
  if signature == "" then
    dbus.dbus_message_unref(reply)
    return true
  end

  local arg_type, output
  if signature == "b" then
    arg_type = TYPE_BOOLEAN
    output = ffi.cast("unsigned int *", self._boolean)
  else
    arg_type = TYPE_STRING
    output = ffi.cast("const char **", self._string)
  end
  dbus.dbus_error_init(self._error_pointer)
  local parsed = dbus.dbus_message_get_args(reply, self._error_pointer, arg_type, output, TYPE_INVALID)
  if parsed == 0 then
    local err = take_error(self._error, self._error_pointer, method .. ": cannot read D-Bus reply")
    dbus.dbus_message_unref(reply)
    return nil, err
  end
  dbus.dbus_error_free(self._error_pointer)

  local result, err
  if signature == "b" then
    local boolean = self._boolean[0]
    if boolean == 0 or boolean == 1 then
      result = boolean == 1
    else
      err = method .. ": invalid D-Bus boolean"
    end
  elseif self._string[0] ~= nil then
    -- The string belongs to the reply; copy it before releasing the message.
    result = ffi.string(self._string[0])
  else
    err = method .. ": null D-Bus string"
  end
  dbus.dbus_message_unref(reply)
  return result, err
end

function Client:context()
  local info, err = self:_call("/controller", CONTROLLER, "DebugInfo", "s")
  if info == nil then
    return nil, err
  end

  local focused_line, count = nil, 0
  for line in info:gmatch("[^\r\n]+") do
    if line:match("%sfocus:1%s*$") or line:match("^focus:1%s*$") then
      count = count + 1
      focused_line = line
    end
  end
  if count ~= 1 then
    return nil
  end
  local uuid = focused_line:match("^%s*IC%s+%[([%x]+)%]")
  if uuid == nil or #uuid ~= 32 then
    return nil, "DebugInfo: focused context has an invalid UUID"
  end

  -- Controller and Rime methods are global: this is a best-effort, non-atomic guard.
  local input_method
  input_method, err = self:_call("/controller", CONTROLLER, "CurrentInputMethod", "s")
  if input_method == nil then
    return nil, err
  end
  if input_method ~= "rime" then
    return nil
  end
  return uuid:lower()
end

function Client:ascii()
  return self:_call("/rime", RIME, "IsAsciiMode", "b")
end

function Client:set_ascii(value)
  if type(value) ~= "boolean" then
    return nil, "SetAsciiMode requires a boolean"
  end
  return self:_call("/rime", RIME, "SetAsciiMode", "", value)
end

function M.new()
  -- libdbus would otherwise spawn dbus-launch to discover/start a session bus.
  local address = os.getenv("DBUS_SESSION_BUS_ADDRESS")
  if address == nil or address == "" then
    return nil, "DBUS_SESSION_BUS_ADDRESS is unset; session bus autolaunch is disabled"
  end
  for transport in address:gmatch("[^;]+") do
    if transport:match("^autolaunch:") then
      return nil, "Session bus autolaunch is disabled; use an existing D-Bus session address"
    end
  end

  if dbus == nil then
    local ok, err = load_backend()
    if not ok then
      return nil, err
    end
  end

  local storage = ffi.new("RimeToggleDBusErrorStorage[1]")
  local pointer = ffi.cast("DBusError *", storage)
  local boolean = ffi.new("unsigned int[1]") -- dbus_bool_t is a native 32-bit integer, not C bool.
  local string = ffi.new("const char *[1]")
  dbus.dbus_error_init(pointer)
  local connection = dbus.dbus_bus_get_private(0, pointer) -- DBUS_BUS_SESSION
  if connection == nil then
    return nil, take_error(storage, pointer, "Cannot connect to the D-Bus session bus")
  end
  dbus.dbus_error_free(pointer)
  dbus.dbus_connection_set_exit_on_disconnect(connection, 0)

  return setmetatable({
    _connection = ffi.gc(connection, release_connection),
    _error = storage,
    _error_pointer = pointer,
    _boolean = boolean,
    _string = string,
  }, Client)
end

return M
