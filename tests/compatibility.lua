local addon, name = ...

local function fixture()
    local s = {build = 'matched', stamp = '25480438', ready = 3, mission = false,
        host = true, reads = 0, lookups = 0, requests = 0, timers = {}, events = {}, logs = {}, pins = {}, time = 0}
    local game, world = 0x10000000, {}
    local ffi = {cdef = function() end, new = function() return {[0] = {}} end,
        copy = function() end, sizeof = function() return 32 end, string = function(value) return value end}
    function ffi.cast()
        s.lookups = s.lookups + 1
        error('unexpected gameplay FFI binding')
    end
    local bytes = {}
    function bytes.unhex(hex)
        local value = (hex:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end))
        s.pins[#value] = value
        if hex == '418b85c4180500' then s.difficulty_pin = value end
        if hex == '488b1dc7b81702' then s.hud_pin = value end
        return value
    end
    world.game, world.runtime = game, {module = function() return true end}
    world.view = {
        read = function(address, size)
            s.reads = s.reads + 1
            local rva = address - game
            if rva == s.changed then return ('\xCC'):rep(size) end
            if rva == s.unavailable then return nil end
            if rva == 0x953212 then return s.difficulty_pin end
            if rva == 0x953219 then return '\255\200' end
            if rva == 0x95321b then return '\243\15\16\68\135\48' end
            if rva == 19864682 then return s.hud_pin end
            return s.pins[size]
        end,
        pointer = function(address)
            if address == game + 0x3326468 then return 0x20000000 end
            if address == game + 0x3326D10 then return 0x30000000 end
            error('unexpected offset read ' .. address)
        end,
        u32 = function(address)
            if address == 0x20000084 then return 1 end
            if address == 0x300518C4 then return 5 end
            error('unexpected u32 read ' .. address)
        end,
    }
    local function every(_, callback)
        local timer = {callback = callback}
        s.timers[#s.timers + 1] = timer
        return {cancel = function() timer.cancelled = true end}
    end
    local hd2 = {version = '0.50.1', api_version = 1, every = every,
        build = function() return s.build, {pinned = 'TEST', reason = s.build_reason} end,
        mod = function() return {log = function(_, message) s.logs[#s.logs + 1] = message end} end,
        events = {on = function(event, callback) s.events[event] = callback end},
        game_state = function() return {mission = s.mission, host = s.host} end,
        options = function() return {slider = function() return {} end} end}
    local modules = {
        ffi = ffi, ['mods/skyeshade/hd2runtime'] = hd2,
        ['hd2runtime/runtime/event_world'] = {
            open = function() s.opens = (s.opens or 0) + 1; return world end,
            game_state = hd2.game_state,
        },
        ['hd2runtime/runtime/scheduler'] = {in_update = function() return true end},
        ['hd2runtime/runtime/hellforge'] = {backend = function()
            return {
                info = function() return {build = s.stamp, ready = s.ready} end,
                load_package = function() s.requests = s.requests + 1; error('unexpected package request') end,
            }
        end},
        ['hd2runtime/core/assets'] = {}, ['hd2runtime/core/bytes'] = bytes,
    }
    local function open_log(path)
        if not s.map_scan or not path:find('TreasureMap.log', 1, true) then return nil end
        local text = ('Treasure Map 1.4.0  (started 2026-11-22 10:00:00, written now)\n'
            .. 'platform: HellForge (game build 25480438, test)\nstatus: map open\n'
            .. 'frames 10 (map open %d)\nlist scans %d\n'
            .. 'loot list: read, 1 entries: super 1; positions known 1\nrecent events:\n')
            :format(s.map_scan, s.map_scan)
        return {read = function() return text end, close = function() end}
    end
    local env = setmetatable({CowboyBingusModLoader = {api = 1, version = 16, log_directory = '<fixture>'},
        io = {open = open_log}, os = {getenv = function() return nil end, clock = function() return s.time end},
        require = function(module) return assert(modules[module], module) end}, {__index = _G})
    env._G = env
    function s:load(policy_only)
        local code = addon
        if policy_only then
            env.ChefTreasureMap = {version = '1.4.0', status = 'map open'}
            code = code:gsub('(local sample_policy = make_sample_policy%(hd2, mod%))',
                '%1\nif true then return sample_policy end', 1)
        end
        return setfenv(assert(loadstring(code, name)), env)()
    end
    function s:tick()
        for _, timer in ipairs(self.timers) do
            if not timer.cancelled then timer.callback(0.25) end
        end
    end
    function s:logged(needle)
        local count = 0
        for _, line in ipairs(self.logs) do
            if line:find(needle, 1, true) then count = count + 1 end
        end
        return count
    end
    return s
end

local s = fixture()
s.build = 'mismatched'
s:load()
assert(s:logged('Disabled for this session') == 1, 'wrong build must explicitly disable FieldSampleDrops at startup')
assert(s:logged('25480438') == 1 and s:logged('mismatched') == 1)
assert(not s.opens and s.reads == 0 and s.lookups == 0)
s:tick()
assert(s:logged('Disabled for this session') == 1)

s = fixture()
s.build, s.build_reason = 'not_ready', 'game modules not loaded'
s:load()
assert(s:logged('not_ready') == 1 and s:logged('Disabled for this session') == 0)
s:tick()
assert(not s.opens and s.reads == 0)
s.build = 'matched'
s:tick()
assert(s:logged('Disabled for this session') == 0 and s.reads > 0)

s = fixture()
s.stamp = '99999999'
s:load()
assert(s:logged('Disabled for this session') == 1 and s:logged('99999999') == 1)
assert(s.reads == 0 and s.lookups == 0)

for _, rva in ipairs({0xFD9710, 0x4F5680}) do
    s = fixture()
    s.changed = rva
    s:load()
    assert(s:logged('Disabled for this session') == 1 and s.lookups == 0 and s.requests == 0)
end

s = fixture()
s.unavailable = 0xFD9710
s:load()
assert(s:logged('code is not readable yet') == 1 and s:logged('Disabled for this session') == 0)
s.unavailable = nil
s:tick()
assert(s:logged('Compatibility verified') == 1 and s.timers[1].cancelled)

s = fixture()
s:load()
s.mission = true
s.events.mission_started({mission = 1})
s.changed = 0x4F5680
s.host = false
s:tick()
s:tick()
assert(s:logged('Disabled for this session') == 1 and s.lookups == 0 and s.requests == 0,
    'mission timer must report a wrong pin even when host authority is unavailable')

s = fixture()
s:load()
s.mission = true
s.events.mission_started({mission = 1})
s.changed = 0x953212
s:tick()
s:tick()
assert(s:logged('Disabled for this session: Mission difficulty layout changed') == 1 and s.lookups == 0)

s = fixture()
s.map_scan, s.mission, s.unavailable = 1, true, 19864682
local policy = s:load(true)
policy.reset()
s.map_scan = 2
local allowed = assert(policy.allowed())
assert(allowed[1] and allowed[2] and not allowed[3] and s:logged('Treasure Map HUD layout changed') == 0)
s.time, s.unavailable, s.changed = 1, nil, 19864682
allowed = assert(policy.allowed())
assert(allowed[1] and allowed[2] and not allowed[3], 'HUD mismatch must preserve the D5 tier fallback')
s.time, s.map_scan = 2, 3
assert(policy.allowed())
assert(s:logged('Treasure Map HUD layout changed; using mission difficulty') == 1
    and s:logged('Disabled for this session') == 0)
