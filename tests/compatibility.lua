local addon, name = ...

local function u32(raw, offset)
    local a, b, c, d = raw:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function b32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function fixture()
    local s = {build = 'matched', stamp = '25480438', ready = 3, mission = false,
        host = true, reads = 0, lookups = 0, requests = 0, timers = {}, events = {}, logs = {}, pins = {}, time = 0}
    local game, world = 0x10000000, {}
    local ffi = {cdef = function() end, new = function() return {[0] = {}} end,
        copy = function() end, sizeof = function() return 32 end, string = function(value) return value end}
    local pointer = setmetatable({}, {__add = function(raw) return raw end})
    local common_type = '64B49B9D8A445266'
    function ffi.new(ctype)
        if ctype == 'uint8_t[?]' then return pointer end
        return {[0] = {}}
    end
    function ffi.cast(ctype, address)
        if s.spawn_fixture then
            if ctype == 'const uint8_t *(*)(uint64_t)' then return function() return 0x60000000 end end
            if ctype == 'uintptr_t' then return address == pointer and 16 or address end
            if ctype == 'uint32_t *' or ctype == 'float *' then return {} end
            if ctype == 'uint32_t *(*)(uint32_t *, uint64_t, void *)' then
                return function(out)
                    s.submitted = (s.submitted or 0) + 1
                    out[0] = 301
                    return out
                end
            end
        end
        s.lookups = s.lookups + 1
        error('unexpected gameplay FFI binding')
    end
    local bytes = {u32 = u32}
    bytes.pointer = u32
    function bytes.unhex(hex)
        local value = (hex:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end))
        s.pins[#value] = value
        if hex == '418b85c4180500' then s.difficulty_pin = value end
        if hex == '488b1dc7b81702' then s.hud_pin = value end
        return value
    end
    local entity_manager, network_slots, network_map, records = 0x40000000, 0x50000000, -0x200, 0x4D00000
    local entity_map, entity_slots, types = 0x4D40000, 0x51000000, 0x52000000
    local network_pins = {
        [0xFD9BF9] = '\x49\x8B\xBB' .. b32(network_map),
        [0xFD9BC9] = '\x45\x8B\x93' .. b32(network_map + 8),
        [0xFD9C00] = '\x41\x8B\xB3' .. b32(network_map + 12),
        [0xFD9BD7] = '\x41\x8B\x9B' .. b32(network_map + 16),
        [0xFD9DDB] = '\x48\x8D\x80' .. b32(records / 8),
        [0xFD9C50] = '\x48\x8D\x80' .. b32(records / 8 + 1),
        [0xFD9D83] = '\x49\x8B\x9A' .. b32(entity_map),
        [0xFD9D68] = '\x45\x8B\x8A' .. b32(entity_map + 8),
    }
    world.game, world.runtime = game, {module = function() return true end}
    world.view = {
        read = function(address, size)
            s.reads = s.reads + 1
            local rva = address - game
            if rva == s.changed then return ('\xCC'):rep(size) end
            if rva == s.unavailable then return nil end
            if s.relocated then
                if network_pins[rva] then return network_pins[rva] end
                if address == entity_manager + network_map then
                    return b32(network_slots) .. b32(0) .. b32(8192) .. b32(0xFFFFFFFF) .. b32(1)
                end
                if address == network_slots + 41 * 8 then return b32(41) .. b32(2049) end
                if address == network_slots + 42 * 8 then return b32(42) .. b32(2050) end
                if address == network_slots + 77 * 8 then return b32(77) .. b32(2510) end
                if address == entity_manager + 0xF3EF28 then return ('\0'):rep(size) end
                if address == entity_manager + entity_map then
                    return b32(entity_slots) .. b32(0) .. b32(8192) .. b32(0xFFFFFFFF) .. b32(1)
                end
                if address == entity_slots + 301 * 8 then return b32(301) .. b32(2510) end
                if address == entity_manager + records + 2510 * 24 then
                    return bytes.unhex(common_type):reverse() .. b32(301) .. b32(199) .. b32(77) .. b32(1)
                end
                if address == 0x60000008 then return bytes.unhex('BB6AC645C30F0266'):reverse() end
                if address == types + 0x266 * 32 then return bytes.unhex(common_type):reverse() end
            end
            if rva == 0x953212 then return s.difficulty_pin end
            if rva == 0x953219 then return '\255\200' end
            if rva == 0x95321b then return '\243\15\16\68\135\48' end
            if rva == 19864682 then return s.hud_pin end
            return s.pins[size]
        end,
        pointer = function(address)
            if address == game + 0x3326468 then return 0x20000000 end
            if address == game + 0x3326D10 then return 0x30000000 end
            if s.relocated and address == game + 0x346BF98 then return entity_manager end
            if s.spawn_fixture and address == entity_manager + 0xF12EA0 then return types end
            error('unexpected offset read ' .. address)
        end,
        u32 = function(address)
            if address == 0x20000084 then return s.player_count or 1 end
            if address == 0x300518C4 then return 5 end
            if s.relocated then
                if address == entity_manager + records + 8 + 2049 * 24 then return 101 end
                if address == entity_manager + records + 8 + 2050 * 24 then return 102 end
            end
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
        local_player = function() return {position = function() return nil end} end,
        game_state = function() return {mission = s.mission, host = s.host} end,
        options = function() return {slider = function() return {} end} end}
    local modules = {
        ffi = ffi, ['mods/skyeshade/hd2runtime'] = hd2,
        ['hd2runtime/runtime/event_world'] = {
            open = function() s.opens = (s.opens or 0) + 1; return world end,
            game_state = hd2.game_state,
            players = function()
                return {{['local'] = true, avatar_network_id = s.network_id}}
            end,
            mul32 = function(key, multiplier) return key * multiplier % 4294967296 end,
            entity_exists = function(_, id) return id == 101 or id == 102 end,
            entity_state = function(_, id)
                return {life = 0, descriptor = {entity = id, goid = id - 60, owned = not s.foreign_avatar,
                    type = '4D1C334D294DFA97', unit = id}}
            end,
            type_info = function() return {avatar = true} end,
            unit_position = function(_, id) return {x = id == 101 and 100 or 200, y = 0, z = 0} end,
            entity_type = function() return nil end, -- HD2Runtime reads the old table.
        },
        ['hd2runtime/runtime/scheduler'] = {in_update = function() return true end},
        ['hd2runtime/runtime/hellforge'] = {backend = function()
            return {
                info = function() return {build = s.stamp, ready = s.ready, sdk = s.relocated and 20 or 16} end,
                mod = function() return {} end,
                load_package = function()
                    s.requests = s.requests + 1
                    if s.spawn_fixture then return 0 end
                    error('unexpected package request')
                end,
            }
        end},
        ['hd2runtime/core/assets'] = {state = function() return s.package_state end},
        ['hd2runtime/core/bytes'] = bytes,
    }
    local function open_log(path)
        if s.relocated and path:find('FieldSampleDrops_CONFIG.ini', 1, true) then
            return {lines = function() return ('threshold_1 = 1\nshow_ui = 0'):gmatch('[^\n]+') end,
                close = function() end}
        end
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

s = fixture()
s.relocated, s.mission, s.network_id = true, true, 41
s:load()
s.events.mission_started({mission = 1})
local function nearby_kill(id, x)
    s.events.entity_killed({enemy = true, local_killer = true, mission = 1, entity_id = id,
        position = {x = x, y = 0, z = 0}})
end
nearby_kill(1, 130.01)
assert(s.lookups == 0, 'relocated avatar still obeys the configured radius')
nearby_kill(2, 130)
assert(s.lookups == 1, 'SDK 20 relocated avatar at the radius boundary must reach pickup preparation')
s.network_id = 0x7FFF
nearby_kill(3, 100)
assert(s.lookups == 1, 'no avatar must not reuse a previous position')
s.network_id, s.foreign_avatar = 42, true
nearby_kill(4, 200)
assert(s.lookups == 1, 'a mismatched avatar must not count')
s.foreign_avatar = false
nearby_kill(5, 200)
assert(s.lookups == 2, 'a reinforcement must resolve the new avatar')

s = fixture()
s.relocated, s.mission, s.network_id, s.spawn_fixture = true, true, 41, true
s.package_state, s.player_count = 'absent', 2
s:load()
s.events.mission_started({mission = 1})
nearby_kill(1, 100)
assert(s.requests == 1 and not s.submitted and s:logged('is absent and HellForge could not hold it') == 1)
s.package_state = 'resident'
s:tick()
assert(s.submitted == 1 and s:logged('spawned tier 1') == 1,
    'a map-resident sample must be confirmed through the relocated entity table after one submission')
assert(s:logged('co-op entity=301 network_id=77') == 1, 'co-op readback must follow the relocated network map')
s:tick()
assert(s.submitted == 1)

s = fixture()
s.relocated, s.mission, s.network_id, s.changed = true, true, 41, 0xFD9D83
s:load()
s.events.mission_started({mission = 1})
nearby_kill(1, 100)
nearby_kill(2, 100)
assert(s.lookups == 0 and s:logged('HellForge entity layout could not be verified') == 1,
    'an unverified layout must block the kill before spawning and log once')
