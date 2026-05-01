-- ---------------------------------------------------------------------------
-- core/log.lua
--
-- File logger for WarMachine.  Writes timestamped diagnostic lines to
-- WarMachine/warmachine_debug.log in the script root.  Mirrors the
-- pattern used by UniversalRotation/core/logger.lua so the workflow is
-- familiar.
--
-- Usage:
--   local log = require 'core.log'
--   log.enable()
--   log.line('foo bar baz')
--   log.snapshot{ t = 12.34, zone = 'PIT_Subzone', pp = '...', ... }
--   log.disable()
--
-- Snapshot vs line: `line` writes a free-form string; `snapshot` accepts
-- a key/value table and serializes it as `key=value` pairs sorted by
-- key.  Both timestamp the entry with `get_time_since_inject()`.
--
-- Repeat-suppression: identical consecutive lines collapse into a
-- "... repeated Nx" marker.  Snapshot lines are full key/value dumps
-- so they typically don't repeat.
-- ---------------------------------------------------------------------------

local M = {}

local _file        = nil
local _enabled     = false
local _path        = nil
local _last_line   = nil
local _repeat_n    = 0

local function _script_root()
    -- Same trick as UniversalRotation/logger -- pull the first entry of
    -- package.path, replace the '?' wildcard, and we're at the script
    -- root.  Works whether the host is on Windows or *nix.
    local root = string.gmatch(package.path, '.*?\\?')()
    return root and root:gsub('?', '') or ''
end

local function _now()
    local t = 0
    pcall(function () t = get_time_since_inject() end)
    return t
end

local function _flush_repeat()
    if _repeat_n > 0 and _file then
        _file:write(string.format('[%.2f]   ... repeated %dx\n', _now(), _repeat_n))
    end
    _repeat_n = 0
end

M.enable = function ()
    if _file then return end
    _path = _script_root() .. 'warmachine_debug.log'
    local f = io.open(_path, 'w')
    if not f then return end
    _file      = f
    _enabled   = true
    _last_line = nil
    _repeat_n  = 0
    f:write(string.format('[%s] WarMachine logger started\n',
        os.date('%Y-%m-%d %H:%M:%S')))
    f:flush()
end

M.disable = function ()
    if _file then
        _flush_repeat()
        pcall(function () _file:close() end)
        _file = nil
    end
    _enabled = false
end

M.is_enabled = function ()
    return _enabled
end

M.path = function ()
    return _path
end

M.line = function (msg)
    if not _enabled or not _file then return end
    msg = tostring(msg)
    if msg == _last_line then
        _repeat_n = _repeat_n + 1
        return
    end
    _flush_repeat()
    _last_line = msg
    _file:write(string.format('[%.2f] %s\n', _now(), msg))
    _file:flush()
end

-- Sort keys for deterministic line shape so a diff between two
-- snapshots reads cleanly.
local function _sorted_keys(t)
    local keys = {}
    for k, _ in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return keys
end

local function _stringify(v)
    if v == nil then return 'nil' end
    if type(v) == 'string' then return v end
    if type(v) == 'number' or type(v) == 'boolean' then return tostring(v) end
    if type(v) == 'table' then
        -- Shallow flatten: a=b c=d (nested tables flattened to ?)
        local parts = {}
        for k, vv in pairs(v) do
            local ks = tostring(k)
            local vs = (type(vv) == 'string' or type(vv) == 'number' or type(vv) == 'boolean')
                and tostring(vv) or '?'
            parts[#parts + 1] = ks .. ':' .. vs
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return tostring(v)
end

M.snapshot = function (kv)
    if not _enabled or not _file then return end
    if type(kv) ~= 'table' then return end
    local keys = _sorted_keys(kv)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. '=' .. _stringify(kv[k])
    end
    M.line(table.concat(parts, ' '))
end

return M
