local uv = vim.uv
local bit = require "bit"

local M = {}
local Store = {}
Store.__index = Store
local Record = {}
Record.__index = Record

local DIRECTORY_MODE = 448 -- 0700
local FILE_MODE = 384 -- 0600
-- Linux open(2) flags. O_NONBLOCK also prevents an unexpected FIFO from hanging.
local NOFOLLOW = 131072
local NONBLOCK = 2048
local DIRECTORY = 65536
local READ_FLAGS = NOFOLLOW + NONBLOCK
local WRITE_FLAGS = 2 + 64 + NOFOLLOW + NONBLOCK -- O_RDWR | O_CREAT
local LOCK_EX_NB = 2 + 4
local LOCK_UN = 8

local function pack(...)
  return { n = select("#", ...), ... }
end

local function with_fd(fd, callback)
  local result = pack(pcall(callback, fd))
  local closed = pack(pcall(uv.fs_close, fd))
  if not result[1] then
    return nil, tostring(result[2])
  end
  if not closed[1] then
    return nil, tostring(closed[2])
  end
  if not closed[2] then
    return nil, closed[3]
  end
  return unpack(result, 2, result.n)
end

local function secure_fd(fd, uid, kind, mode)
  local stat, err = uv.fs_fstat(fd)
  if not stat then
    return nil, err
  end
  if stat.type ~= kind or stat.uid ~= uid then
    return nil, "lease path must be an owned " .. kind
  end
  if kind == "file" and stat.nlink ~= 1 then
    return nil, "lease file must not have hard links"
  end
  if bit.band(stat.mode, 4095) ~= mode then
    local ok
    ok, err = uv.fs_fchmod(fd, mode)
    if not ok then
      return nil, err
    end
  end
  return stat
end

local function validate_record(record)
  if type(record) ~= "table" or type(record.owner) ~= "string" or record.owner == "" then
    return nil, "lease record must contain a nonempty owner string"
  end
  for key in pairs(record) do
    if key ~= "owner" then
      return nil, "lease record must contain only owner"
    end
  end
  return true
end

local function check_active(record)
  if not record.active then
    return nil, "lease record access requires its active lock"
  end
  return true
end

function Record:read()
  local active, err = check_active(self)
  if not active then
    return nil, err
  end
  local fd, code
  fd, err, code = uv.fs_open(self.path, READ_FLAGS, FILE_MODE)
  if not fd then
    if code == "ENOENT" then
      return nil
    end
    return nil, err
  end
  return with_fd(fd, function()
    local stat, stat_err = secure_fd(fd, self.uid, "file", FILE_MODE)
    if not stat then
      return nil, stat_err
    end
    local chunks, offset = {}, 0
    while offset < stat.size do
      local data, read_err = uv.fs_read(fd, stat.size - offset, offset)
      if not data then
        return nil, read_err
      end
      if data == "" then
        return nil, "corrupt lease record: unexpected end of file"
      end
      chunks[#chunks + 1] = data
      offset = offset + #data
    end
    local decoded, record = pcall(vim.json.decode, table.concat(chunks))
    if not decoded then
      return nil, "corrupt lease record: " .. tostring(record)
    end
    local valid, validation_err = validate_record(record)
    if not valid then
      return nil, "corrupt lease record: " .. validation_err
    end
    return record
  end)
end

function Record:write(record)
  local active, err = check_active(self)
  if not active then
    return nil, err
  end
  local valid
  valid, err = validate_record(record)
  if not valid then
    return nil, err
  end
  -- Never replace a malformed record, including a previous interrupted write.
  local _, read_err = self:read()
  if read_err then
    return nil, read_err
  end
  local encoded, data = pcall(vim.json.encode, { owner = record.owner })
  if not encoded then
    return nil, tostring(data)
  end
  local fd
  fd, err = uv.fs_open(self.path, WRITE_FLAGS, FILE_MODE)
  if not fd then
    return nil, err
  end
  return with_fd(fd, function()
    local stat, stat_err = secure_fd(fd, self.uid, "file", FILE_MODE)
    if not stat then
      return nil, stat_err
    end
    local truncated, truncate_err = uv.fs_ftruncate(fd, 0)
    if not truncated then
      return nil, truncate_err
    end
    local offset = 0
    while offset < #data do
      local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
      if not written then
        return nil, write_err
      end
      if written == 0 then
        return nil, "lease write made no progress"
      end
      offset = offset + written
    end
    return true
  end)
end

function Record:clear()
  local active, err = check_active(self)
  if not active then
    return nil, err
  end
  local record
  record, err = self:read()
  if err then
    return nil, err
  end
  if record == nil then
    return true
  end
  local removed, remove_err, code = uv.fs_unlink(self.path)
  if not removed and code ~= "ENOENT" then
    return nil, remove_err
  end
  return true
end

function Store:with_lock(context_uuid, callback)
  if type(context_uuid) ~= "string" or #context_uuid ~= 32 or not context_uuid:match "^[0-9a-f]+$" then
    return nil, "context UUID must be 32 lowercase hexadecimal characters"
  end
  if type(callback) ~= "function" then
    return nil, "lease callback must be a function"
  end
  local path = self.root .. "/" .. context_uuid
  local fd, err = uv.fs_open(path .. ".lock", WRITE_FLAGS, FILE_MODE)
  if not fd then
    return nil, err
  end
  return with_fd(fd, function()
    local stat, stat_err = secure_fd(fd, self.uid, "file", FILE_MODE)
    if not stat then
      return nil, stat_err
    end
    if self.flock(fd, LOCK_EX_NB) ~= 0 then
      local errno = self.ffi.errno()
      if errno == 11 then -- EAGAIN / EWOULDBLOCK on Linux
        return nil, "lease lock busy"
      end
      return nil, "lease flock failed (errno " .. errno .. ")"
    end
    local record = setmetatable({ path = path .. ".json", uid = self.uid, active = true }, Record)
    local result = pack(pcall(callback, record))
    record.active = false
    local unlocked = self.flock(fd, LOCK_UN)
    local unlock_errno = unlocked ~= 0 and self.ffi.errno() or nil
    if not result[1] then
      return nil, tostring(result[2])
    end
    if unlocked ~= 0 then
      return nil, "lease unlock failed (errno " .. unlock_errno .. ")"
    end
    return unpack(result, 2, result.n)
  end)
end

local function new(root)
  local ffi = require "ffi"
  if ffi.os ~= "Linux" then
    return nil, "lease locks require Linux"
  end
  ffi.cdef [[int flock(int fd, int operation);]]
  -- Resolve the symbol now so initialization reports unsupported runtimes.
  local flock = ffi.C.flock
  if root == nil then
    local runtime = vim.env.XDG_RUNTIME_DIR
    root = (runtime and runtime ~= "" and runtime or vim.fn.stdpath "state") .. "/rime.nvim"
  end
  if type(root) ~= "string" or root == "" or root:find("\0", 1, true) then
    return nil, "lease root must be a nonempty directory path"
  end
  root = root:gsub("/+$", "")
  if root == "" then
    return nil, "lease root must not be the filesystem root"
  end
  local passwd, err = uv.os_get_passwd()
  if not passwd then
    return nil, err
  end
  vim.fn.mkdir(root, "p", DIRECTORY_MODE)
  local fd
  fd, err = uv.fs_open(root, DIRECTORY + NOFOLLOW, DIRECTORY_MODE)
  if not fd then
    return nil, err
  end
  return with_fd(fd, function()
    local stat, stat_err = secure_fd(fd, passwd.uid, "directory", DIRECTORY_MODE)
    if not stat then
      return nil, stat_err
    end
    return setmetatable({ root = root, uid = passwd.uid, ffi = ffi, flock = flock }, Store)
  end)
end

function M.new(root)
  local result = pack(pcall(new, root))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return unpack(result, 2, result.n)
end

return M
