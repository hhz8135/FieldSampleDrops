local addon, chunk_name = ...
local config_file = 'FieldSampleDrops_CONFIG.ini'
local status_file = 'FieldSampleDrops_STATUS.txt'

local function new_fixture()
    local state = {subscriptions = {}, timers = {}, logs = {}, files = {}, menu = {}, sliders = {},
        attempts = {}, drops = {}, preloads = 0, time = 0, epoch = 0, total_players = 1,
        policy_allowed = {true, true, true}, policy_resets = 0, policy_refreshes = 0}
    state.config = 'show_ui = 0'
    state.player_position = {x = 0, y = 0, z = 0}

    local function open_virtual_file(path, mode)
        local name = assert(path:match('[^/\\]+$'), 'expected a virtual file name')
        if name == config_file and mode == 'r' then
            if not state.config then return nil end
            return {lines = function() return string.gmatch(state.config, '[^\n]+') end, close = function() end}
        end
        assert(mode == 'w' and (name == status_file or name == config_file),
            'unexpected virtual file: ' .. name)
        local contents = {}
        return {
            write = function(_, value) contents[#contents + 1] = value end,
            close = function()
                local text = table.concat(contents)
                state.files[name] = text
                if name == config_file then state.config = text end
            end,
        }
    end

    local events = {}
    function events.on(name, callback)
        local listeners = state.subscriptions[name] or {}
        listeners[#listeners + 1] = callback
        state.subscriptions[name] = listeners
    end

    function state:emit(name, payload)
        for _, callback in ipairs(self.subscriptions[name] or {}) do callback(payload) end
    end

    function state:start(host)
        self.in_mission = true
        self.host = host
        self.epoch = self.epoch + 1
        self:emit('mission_started', {host = host, mission = self.epoch})
    end

    function state:finish()
        self.in_mission = false
        self:emit('mission_ended', {mission = self.epoch})
        for _, timer in ipairs(self.timers) do
            if timer.scope == 'mission' then timer.cancelled = true end
        end
    end

    function state:kill(id, position, fields)
        local event = {entity_id = id, position = position, enemy = true, local_killer = true, mission = self.epoch}
        for key, value in pairs(fields or {}) do event[key] = value end
        self:emit('entity_killed', event)
    end

    local player = {peer = 'fixture-local-peer', is_local = true}
    function player:position() return state.player_position end

    local mod = {}
    function mod:log(message) state.logs[#state.logs + 1] = message end
    function mod:on(name, callback, opts) return events.on(name, callback, opts) end

    local function every(interval, callback, opts)
        assert(interval > 0, 'timer interval must be positive')
        local timer = {interval = interval, callback = callback, next_tick = state.time + interval,
            scope = opts and opts.scope}
        state.timers[#state.timers + 1] = timer
        return {cancel = function() timer.cancelled = true end}
    end
    function mod:every(interval, callback, opts) return every(interval, callback, opts) end

    local page = {}
    function page:slider(spec)
        state.sliders[spec.id] = spec
        local function setting() return state.menu[spec.id] or {} end
        return {
            describe = function() return setting() end,
            get = function() return setting().value or spec.default end,
        }
    end

    local hd2 = {
        api_version = 1,
        version = '0.50.1',
        build = function() return 'matched' end,
        mod = function() return mod end,
        local_player = function() return player end,
        players = function()
            local players = {player}
            for peer = 2, state.total_players do players[peer] = {is_local = false} end
            return players
        end,
        events = events,
        every = every,
        options = function(spec)
            state.menu_id = spec.id
            return page
        end,
        game_state = function() return {mission = state.in_mission, host = state.host} end,
    }

    -- Both the packaged adapters and replaced adapters receive virtual bindings.
    local function unhex(hex)
        return (hex:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end))
    end

    local modules = {
        ffi = {C = {GetCurrentProcess = function() return {} end}, cdef = function() end,
            new = function() return {[0] = {}} end, copy = function() end, sizeof = function() return 1 end},
        ['mods/skyeshade/hd2runtime'] = hd2,
        ['hd2runtime/runtime/event_world'] = {open = function() return nil, 'offline fixture' end},
        ['hd2runtime/runtime/scheduler'] = {in_update = function() return true end},
        ['hd2runtime/core/assets'] = {},
        ['hd2runtime/core/bytes'] = {unhex = unhex},
    }
    local env = {
        assert = assert, error = error, ipairs = ipairs, math = math, next = next,
        pairs = pairs, pcall = pcall, rawget = rawget, rawset = rawset, select = select,
        setmetatable = setmetatable, string = string, table = table, tonumber = tonumber,
        tostring = tostring, type = type, unpack = unpack, xpcall = xpcall,
        io = {open = open_virtual_file},
        os = {getenv = function() return '<fixture>' end, clock = function() return state.time end},
        require = function(name) return assert(modules[name], 'unexpected addon import: ' .. name) end,
        update = function() end,
        CowboyBingusModLoader = {api = 1, version = 16},
    }
    env._G = env

    function state:advance(seconds)
        local target = self.time + seconds
        while self.time < target do
            local next_tick = target
            for _, timer in ipairs(self.timers) do
                if not timer.cancelled then next_tick = math.min(next_tick, timer.next_tick) end
            end
            local elapsed = next_tick - self.time
            self.time = next_tick
            for _, timer in ipairs(self.timers) do
                if not timer.cancelled and timer.next_tick <= self.time then
                    timer.next_tick = timer.next_tick + timer.interval
                    timer.callback(elapsed)
                end
            end
            env.update(elapsed)
        end
    end

    env.fixture_pickups = function(tier, position)
        local attempt = {tier = tier, x = position.x, y = position.y, z = position.z}
        state.attempts[#state.attempts + 1] = attempt
        if state.spawn_failure then return state.spawn_failure() end
        state.drops[#state.drops + 1] = attempt
        return true
    end
    env.fixture_host_session = function()
        if state.host ~= true then return false, 'fixture does not have host authority' end
        return true, nil, state.total_players
    end
    env.fixture_preload = function() state.preloads = state.preloads + 1 end
    env.fixture_sample_policy = {
        reset = function() state.policy_resets = state.policy_resets + 1 end,
        allowed = function() return state.policy_allowed, 'fixture sample policy blocked' end,
        refresh = function() state.policy_refreshes = state.policy_refreshes + 1 end,
    }

    local function replace_once(code, original, replacement)
        local start, finish = code:find(original, 1, true)
        assert(start and not code:find(original, finish + 1, true), 'expected a single adapter seam: ' .. original)
        return code:sub(1, start - 1) .. replacement .. code:sub(finish + 1)
    end

    function state:load_addon(replace)
        env['HD2RuntimeMod:mods/custom/monster_sample_drop'] = self.legacy_loaded
        env.__MONSTER_SAMPLE_DROP_INSTALLED = self.legacy_original
        local body = addon
        if replace then
            local binding = assert(body:match('\n(local pickups[%w_, ]* = make_pickups%(hd2, mod%))'),
                'expected the packaged pickup adapter binding')
            local replacement = binding:gsub('make_pickups%(hd2, mod%)$',
                'fixture_pickups, fixture_host_session, fixture_preload')
            body = replace_once(body, binding, replacement)
            body = replace_once(body, 'local sample_policy = make_sample_policy(hd2, mod)',
                'local sample_policy = fixture_sample_policy')
        end
        local chunk = assert(loadstring(body, chunk_name))
        setfenv(chunk, env)()
    end

    return state
end

local function assert_drop(drop, tier, position)
    assert(drop, 'expected a sample pickup')
    assert(drop.tier == tier, 'wrong sample tier: ' .. tostring(drop.tier))
    assert(drop.x == position.x and drop.y == position.y and drop.z == position.z,
        'sample pickup must use the enemy death position')
end

local function assert_count(items, count, context)
    assert(#items == count, ('%s: expected %d, got %d'):format(context, count, #items))
end

local function packaged_addon_loads()
    assert(chunk_name == '@mods/custom/field_sample_drops', 'expected the independent FieldSampleDrops resource')
    local state = new_fixture()
    state:load_addon(false)
    assert(state.menu_id == 'field_sample_drops', 'expected an independent FieldSampleDrops menu ID')
    assert_count(state.subscriptions.entity_killed or {}, 1, 'packaged entity_killed listeners')
    assert_count(state.subscriptions.player_kill_credited or {}, 0, 'packaged aggregate-kill listeners')
    state:start(true)
    state:kill(1, {x = 10, y = 0, z = 0})
    assert(state.logs[#state.logs]:find('[FieldSampleDrops] Game world unavailable', 1, true),
        'packaged addon must skip pickup submission when the game world is unavailable')
end

local function default_thresholds()
    local state = new_fixture()
    state:load_addon(true)
    state:start(true)
    for kill = 1, 75 do
        state:kill(kill, {x = 10, y = 0, z = kill / 100})
        if kill == 19 then assert_count(state.drops, 0, 'before common threshold') end
    end
    assert_count(state.drops, 5, 'common / rare / super default thresholds at 75 kills')
    assert_drop(state.drops[1], 1, {x = 10, y = 0, z = 0.20})
    assert_drop(state.drops[2], 1, {x = 10, y = 0, z = 0.40})
    assert_drop(state.drops[3], 2, {x = 10, y = 0, z = 0.40})
    assert_drop(state.drops[4], 1, {x = 10, y = 0, z = 0.60})
    assert_drop(state.drops[5], 3, {x = 10, y = 0, z = 0.75})
end

local function qualifying_kills_and_ini()
    local state = new_fixture()
    state.config = 'show_ui = 0\nthreshold_1 = 2\nthreshold_2 = 3\nthreshold_3 = 4'
    state.player_position = {x = 100, y = 10, z = 0}
    state:load_addon(true)
    state:start(true)
    local near = {x = 110, y = 10, z = 0}
    state:kill(1, near)
    state:kill(1, near)
    state:kill(2, {x = 130.01, y = 10, z = 0})
    state:kill(3, near, {enemy = false})
    state:kill(4, near, {local_killer = false})
    state:kill(5, nil)
    state:kill(nil, near)
    state:kill(6, {x = 0 / 0, y = 0, z = 0})
    state:kill(10, near, {mission = state.epoch - 1})
    state:emit('player_kill_credited', {kills = 100, total = 100})
    assert_count(state.drops, 0, 'only the first event qualifies')

    local boundary = {x = 118, y = 34, z = 0}
    state:kill(7, boundary)
    state:kill(8, near)
    state:kill(9, near)
    assert_count(state.drops, 4, 'INI thresholds')
    assert_drop(state.drops[1], 1, boundary)
    assert_drop(state.drops[2], 2, near)
    assert_drop(state.drops[3], 1, near)
    assert_drop(state.drops[4], 3, near)
end

local function menu_overrides_and_mission_reset()
    local state = new_fixture()
    state.config = 'show_ui = 0\nthreshold_1 = 3'
    state.menu.threshold_1 = {registered = true, value = 2}
    state:load_addon(true)
    assert(state.sliders.threshold_1 and state.sliders.threshold_2 and state.sliders.threshold_3,
        'expected a slider for all three sample thresholds')
    local near = {x = 10, y = 0, z = 0}
    state:kill(1, near)
    state:start(false)
    state:kill(1, near)
    state:kill(2, near)
    state:finish()
    assert_count(state.drops, 0, 'ship and non-host do not spawn pickups')

    state:start(true)
    state:kill(1, near)
    state:finish()
    state:start(true)
    state:kill(1, near)
    assert_count(state.drops, 0, 'count resets and an entity ID can be used in a new mission')
    state:kill(2, near)
    assert_count(state.drops, 1, 'menu override persists across missions')
    assert_drop(state.drops[1], 1, near)

    state:finish()
    state.menu.threshold_1 = {source = 'saved', value = 1}
    state:start(true)
    state:kill(1, near)
    assert_count(state.drops, 2, 'saved thresholds work without a registered menu')
end

local function team_authority_updates()
    local state = new_fixture()
    state.total_players = 2
    state.config = 'show_ui = 0\nthreshold_1 = 1'
    state:load_addon(true)
    state:start(false)
    local near = {x = 10, y = 0, z = 0}
    state:kill(1, near)
    state:advance(3)
    assert_count(state.attempts, 0, 'a client does not submit pickups')
    assert(state.preloads == 0, 'a client does not preload pickup resources')

    state.host = true
    state:kill(2, near, {local_killer = false})
    assert_count(state.attempts, 0, 'a teammate kill does not submit a pickup')
    state:kill(3, near)
    assert_count(state.drops, 1, 'the host earns pickups in a two-player mission')
    assert_drop(state.drops[1], 1, near)
    state:advance(3)
    assert(state.preloads > 0, 'the host periodically preloads pickup resources')

    state.host = false
    local preloads = state.preloads
    state:kill(4, near)
    state:advance(3)
    assert_count(state.attempts, 1, 'losing authority prevents additional pickup submissions')
    assert(state.preloads == preloads, 'losing authority stops resource preloading')
end

local function legacy_coexistence()
    local near = {x = 10, y = 0, z = 0}
    local state = new_fixture()
    state.config = 'show_ui = 0\nthreshold_1 = 1'
    state.legacy_loaded = true
    state:load_addon(true)
    state:start(true)
    state:kill(1, near)
    state:advance(3)
    assert_count(state.attempts, 0, 'MonsterSampleDrop 1.1 handles solo rewards when both are enabled')
    assert(state.preloads == 0, 'the inactive addon does not preload on a solo mission')

    state.total_players = 2
    state:kill(2, near)
    assert_count(state.drops, 1, 'FieldSampleDrops handles co-op rewards with MonsterSampleDrop 1.1 enabled')
    assert_drop(state.drops[1], 1, near)

    state = new_fixture()
    state.config = 'show_ui = 0\nthreshold_1 = 1'
    state.legacy_loaded, state.legacy_original, state.total_players = true, true, 2
    state:load_addon(true)
    state:start(true)
    state:kill(1, near)
    state:advance(3)
    assert_count(state.attempts, 0, 'the original MonsterSampleDrop exclusively handles rewards while loaded')
    assert(state.preloads == 0, 'the inactive addon does not preload with the original MonsterSampleDrop')
end

local function radius_applies_next_mission()
    local state = new_fixture()
    state.config = 'show_ui = 0\nthreshold_1 = 1\ndrop_radius_m = 60 # meters'
    state:load_addon(true)
    local slider = assert(state.sliders.drop_radius_m, 'expected a radius slider')
    assert(slider.min == 1 and slider.max == 300 and slider.step == 1 and slider.default == 60,
        'expected the integer slider bounds and INI default')
    state:start(true)
    state:kill(1, {x = 60.01, y = 0, z = 0})
    state:kill(2, {x = 60, y = 0, z = 0})
    assert_count(state.drops, 1, '60 m INI radius is inclusive')
    assert_drop(state.drops[1], 1, {x = 60, y = 0, z = 0})
    assert(table.concat(state.logs, '\n'):find('radius 60 m', 1, true), 'mission log must show the effective INI radius')

    state.config = 'show_ui = 0\nthreshold_1 = 1\ndrop_radius_m = 55'
    state.menu.drop_radius_m = {source = 'menu', registered = true, value = 5}
    state:kill(3, {x = 60, y = 0, z = 0})
    assert_count(state.drops, 2, 'INI and menu adjustments do not affect the active mission')
    state:finish()
    state:start(true)
    state:kill(3, {x = 5.01, y = 0, z = 0})
    state:kill(4, {x = 5, y = 0, z = 0})
    assert_count(state.drops, 3, 'applied menu radius overrides INI in the next mission')
    assert_drop(state.drops[3], 1, {x = 5, y = 0, z = 0})
    assert(table.concat(state.logs, '\n'):find('radius 5 m', 1, true), 'mission log must show the effective menu radius')

    state:finish()
    state.config = 'show_ui = 0\nthreshold_1 = 1\ndrop_radius_m = 300'
    state.menu.drop_radius_m = {source = 'default', registered = false, value = 60}
    state:start(true)
    state:kill(1, {x = 300.01, y = 0, z = 0})
    state:kill(2, {x = 300, y = 0, z = 0})
    assert_count(state.drops, 4, 'current INI radius applies when the menu is unavailable')
    assert_drop(state.drops[4], 1, {x = 300, y = 0, z = 0})

    state:finish()
    state.menu.drop_radius_m = {source = 'saved', value = 1}
    state:start(true)
    state:kill(1, {x = 1.01, y = 0, z = 0})
    state:kill(2, {x = 1, y = 0, z = 0})
    assert_count(state.drops, 5, 'saved radius lower bound is inclusive')
    assert_drop(state.drops[5], 1, {x = 1, y = 0, z = 0})
end

local function invalid_radius_falls_back()
    for _, value in ipairs({'0', '301', '90.5', '90m', '90 = 50', 'abc', '-4'}) do
        local state = new_fixture()
        state.config = 'show_ui = 0\nthreshold_1 = 1\ndrop_radius_m = ' .. value
        state.menu.drop_radius_m = {source = 'saved', value = 299.5}
        state:load_addon(true)
        state:start(true)
        state:kill(1, {x = 30.01, y = 0, z = 0})
        state:kill(2, {x = 30, y = 0, z = 0})
        assert_count(state.drops, 1, 'invalid radius falls back to 30 m for ' .. value)
        assert_drop(state.drops[1], 1, {x = 30, y = 0, z = 0})
    end

    local state = new_fixture()
    state.config = nil
    state:load_addon(true)
    assert(state.config and state.config:find('drop_radius_m = 30\n', 1, true),
        'new INI must write the 30 m default')
end

local function deferred_pickup_at_most_once()
    local state = new_fixture()
    state.config = 'show_ui = 0\nthreshold_1 = 1'
    local near = {x = 9, y = 8, z = 7}
    state:load_addon(true)
    state:start(true)
    state.spawn_failure = function()
        state.spawn_failure = nil
        return false, 'fixture packages loading', true
    end
    state:kill(1, near)
    state:kill(1, near)
    state:advance(2)
    assert_count(state.attempts, 2, 'one initial attempt and one retry')
    assert_count(state.drops, 1, 'only one pickup after the retry')
    assert_drop(state.drops[1], 1, near)
end

local function stale_retry_cleared()
    local state = new_fixture()
    state.config = 'show_ui = 0\nthreshold_1 = 1'
    local near = {x = 10, y = 0, z = 0}
    state:load_addon(true)
    state:start(true)
    state.spawn_failure = function() return false, 'fixture packages loading', true end
    state:kill(1, near)
    assert_count(state.attempts, 1, 'initial delayed pickup')
    state:finish()
    state.spawn_failure = nil
    state:start(true)
    state:advance(2)
    assert_count(state.attempts, 1, 'mission end discards the old pickup retry')
    assert_count(state.drops, 0, 'no pickup carries over to the next mission')
end

local function sample_tier_policy()
    local state = new_fixture()
    state.config = 'show_ui = 0\nthreshold_1 = 1\nthreshold_2 = 1\nthreshold_3 = 1'
    state.policy_allowed = nil
    local near = {x = 10, y = 0, z = 0}
    state:load_addon(true)
    state:start(true)
    state:kill(1, near)
    assert_count(state.attempts, 0, 'unresolved tier policy blocks pickup submission')
    state.policy_allowed = {true, false, false}
    state:advance(1)
    assert(state.policy_refreshes > 0, 'the mission timer refreshes sample policy')
    assert_count(state.attempts, 1, 'only the policy-eligible tier is submitted')
    assert_drop(state.drops[1], 1, near)
    state:finish()
    state:start(true)
    assert(state.policy_resets == 2, 'tier policy resets at each mission start')
end

packaged_addon_loads()
default_thresholds()
qualifying_kills_and_ini()
menu_overrides_and_mission_reset()
team_authority_updates()
legacy_coexistence()
radius_applies_next_mission()
invalid_radius_falls_back()
deferred_pickup_at_most_once()
stale_retry_cleared()
sample_tier_policy()
