-- Build 25480438. Resource names and identities from HD2Runtime by SkyeShade
-- and Treasure Map by Th3chef. The spawn ABI is corroborated by HD2Runtime's
-- Pelican research and Link's Link to Memory (MIT), as used by MultiBackpack.
local supported_game_build = '25480438'

local function check_runtime_build(hd2)
    local status, info = hd2.build()
    if status == 'matched' then return true end
    local detail = type(info) == 'table' and info.reason
    local reason = 'Expected game build ' .. supported_game_build .. ', HD2Runtime reported ' .. tostring(status)
    if detail then reason = reason .. ' (' .. tostring(detail) .. ')' end
    return false, reason, status == 'not_ready'
end

local function make_pickups(hd2, mod)
    local ffi = require('ffi')
    local world_module = require('hd2runtime/runtime/event_world')
    local scheduler = require('hd2runtime/runtime/scheduler')
    local hellforge = require('hd2runtime/runtime/hellforge')
    local assets = require('hd2runtime/core/assets')
    local bytes = require('hd2runtime/core/bytes')

    local sample_resources = {
        [1] = '64B49B9D8A445266', -- bio_sample_01
        [2] = 'DEFE062C2567C23D', -- legendarium_sample_01
        [3] = '9D4935FA69B6B41A', -- super_uranium_sample_01
    }
    local resources = {}
    for tier, hex in ipairs(sample_resources) do
        local raw = bytes.unhex(hex):reverse()
        local value = ffi.new('uint64_t[1]')
        ffi.copy(value, raw, 8)
        resources[tier] = {hex = hex, raw = raw, value = value[0], slot = tonumber(hex:sub(-3), 16)}
    end

    local spawn_rva = 0xFD9710
    local spawn_code = bytes.unhex('4c8bdc49895b1049897320574881eca0000000488b05e62866014833c4488984249000000033c0498bf84d8b4050488bda49894388488bf14989439049894398498943a0498943a8498943b0498943b8498943c0498943c8498943d0498943d84d85c0750c498d4388488947504d8d4388e80abe3000488b0d0b2849024c8bcb488bd648897c24204c8b01e820290000488bc6488b8c24900000004833cce8bdef0a014c8d9c24a0000000498b5b18498b7328498be35fc3')
    local package_rva = 0x4F5680
    local package_code = bytes.unhex('4885c97471488b050c69f702448bc14c8b905825f10048b8')
    local zero_key = string.rep('\0', 8)
    local zero_context = string.rep('\0', 0x8A0)
    local retained = {} -- Spawn descriptors stay alive for this game session.
    local refused_packages = {}
    local held_packages = {}
    local bridge, bridge_mod

    local function check_hellforge()
        bridge = hellforge.backend()
        if not bridge then return false, 'HellForge bridge unavailable: ' .. tostring(hellforge.reason) end
        local info = bridge.info()
        local build = info and info.build
        if not build then return false, 'HellForge bridge not ready', true end
        if build ~= supported_game_build then
            return false, 'Expected HellForge game build ' .. supported_game_build .. ', found ' .. build
        end
        if (tonumber(info.ready) or 0) % 4 ~= 3 then return false, 'HellForge entity data not ready', true end
        return true
    end

    local function check_pin(world, rva, expected, label)
        local actual = world.view.read(world.game + rva, #expected)
        if not actual then return false, label .. ' code is not readable yet', true end
        if actual ~= expected then return false, label .. ' code differs from the reviewed build' end
        return true
    end

    local function compatibility()
        local matched, reason, retryable = check_runtime_build(hd2)
        if not matched then return false, reason, retryable end
        matched, reason, retryable = check_hellforge()
        if not matched then return false, reason, retryable end
        local world, why = world_module.open()
        if not world then
            why = tostring(why)
            if why:find('native event structure changed', 1, true) or why:find('image size changed', 1, true) then
                return false, why
            end
            return false, 'Game world unavailable: ' .. why, true
        end
        matched, reason, retryable = check_pin(world, spawn_rva, spawn_code, 'Sample spawn')
        if not matched then return false, reason, retryable end
        matched, reason, retryable = check_pin(world, package_rva, package_code, 'Sample package lookup')
        if not matched then return false, reason, retryable end
        return true, world
    end

    local function registered(view, world_address, resource)
        local types = view.pointer(world_address + 0xF12EA0)
        if not types or types == 0 then return false end
        local slot = resource.slot
        for _ = 1, 4096 do
            local key = view.read(types + slot * 32, 8)
            if key == resource.raw then return true end
            if not key or key == zero_key then return false end
            slot = (slot + 1) % 4096
        end
        return false
    end

    local function package_ready(world, resource)
        local view = world.view
        local address = world.game + package_rva
        local pinned, reason, retryable = check_pin(world, package_rva, package_code, 'Sample package lookup')
        if not pinned then return false, reason, retryable end
        local lookup = ffi.cast('const uint8_t *(*)(uint64_t)', address)
        local record = lookup(resource.value)
        if record == nil then return false, 'Sample package record unavailable', true end
        local package = view.read(tonumber(ffi.cast('uintptr_t', record)) + 8, 8)
        if not package or package == zero_key then return false, 'Sample package identity unavailable', true end
        local hex = '0x' .. string.format('%08X%08X', bytes.u32(package, 4), bytes.u32(package, 0))
        -- Holding a catalogue package also advertises it to HellForge AssetShare.
        -- This is needed even when the host already has it resident from the map.
        if held_packages[hex] then return true end
        if not refused_packages[hex] then
            bridge_mod = bridge_mod or bridge.mod('field_sample_drops')
            if bridge_mod ~= nil then
                local id = ffi.new('uint64_t[1]')
                ffi.copy(id, package, 8)
                local status = bridge.load_package(bridge_mod, id[0])
                if status == 2 then
                    held_packages[hex] = true
                    return true
                end
                if status == 1 then return false, 'Sample package is loading', true end
                refused_packages[hex] = true
                mod:log('[FieldSampleDrops] HellForge could not hold package ' .. hex .. ' for lobby preload')
            end
        end
        local readable, state = pcall(assets.state, world.runtime, hex)
        if readable and state == 'resident' then return true end
        return false, 'Sample package is not resident and HellForge could not load it', true
    end

    local function finite(value)
        return type(value) == 'number' and value == value and math.abs(value) <= 100000
    end

    local function session()
        if not scheduler.in_update() then return false, 'Sample drop needs the game update', true end
        local compatible, world, retryable = compatibility()
        if not compatible then return false, world, retryable end
        local state = world_module.game_state(world)
        if not state or not state.mission then return false, 'No active mission', true end
        if state.host ~= true then return false, 'Samples require the mission host', state.host == nil end
        local manager = world.view.pointer(world.game + 0x3326468)
        local count = manager and manager ~= 0 and world.view.u32(manager + 0x84)
        if not count or count == 0 or count > 4 then return false, 'Mission player count unavailable', true end
        return true, world, count
    end

    local function prepare(tier, position)
        local resource = resources[tier]
        if not resource then return false, 'Unknown sample tier' end
        if type(position) ~= 'table' or not (finite(position.x) and finite(position.y) and finite(position.z)) then
            return false, 'Invalid sample drop position'
        end
        local allowed, world, count = session()
        if not allowed then return false, world, count end

        local view = world.view
        local world_address = view.pointer(world.game + 0x346BF98)
        if not world_address or world_address == 0 or view.read(world_address + 0xF3EF28, #zero_context) ~= zero_context then
            return false, 'Default entity spawn context unavailable', true
        end
        local ready, asset_reason, asset_retryable = package_ready(world, resource)
        if not ready then return false, asset_reason, asset_retryable end
        if not registered(view, world_address, resource) then return false, 'Sample entity type not registered', true end
        local pinned, reason, retryable = check_pin(world, spawn_rva, spawn_code, 'Sample spawn')
        if not pinned then return false, reason, retryable end
        return true, world, resource, count
    end

    local function observe_network(world, entity, resource)
        local function network_id(w)
            if not w or world_module.entity_type(w, entity) ~= resource.hex then return nil end
            return world_module.entity_network(w, entity)
        end
        local id = network_id(world)
        if id then
            mod:log(('[FieldSampleDrops] co-op entity=%d network_id=%d'):format(entity, id))
        else
            hd2.after(1, function()
                local compatible, current_world = compatibility()
                local current = compatible and network_id(current_world) or nil
                mod:log(('[FieldSampleDrops] co-op entity=%d network_id=%s after 1 s'):format(entity, tostring(current)))
            end, {scope='mission'})
        end
    end

    local function spawn(tier, position)
        local prepared, ready, world, resource, count = pcall(prepare, tier, position)
        if not prepared then return false, 'Could not verify sample spawn prerequisites: ' .. tostring(ready) end
        if not ready then return false, world, resource end

        -- The 0x58-byte descriptor is 16-byte aligned, with the pose at +0x08.
        local raw = ffi.new('uint8_t[?]', 0x58 + 15)
        local pointer = tonumber(ffi.cast('uintptr_t', raw))
        local descriptor = raw + (16 - pointer % 16) % 16
        descriptor[0] = 1
        ffi.cast('uint32_t *', descriptor + 4)[0] = 0x7FFF
        local pose = ffi.cast('float *', descriptor + 8)
        pose[0], pose[5], pose[10], pose[15] = 1, 1, 1, 1
        pose[12], pose[13], pose[14] = position.x, position.y, position.z
        local result = ffi.new('uint32_t[1]')
        local spawn = ffi.cast('uint32_t *(*)(uint32_t *, uint64_t, void *)', world.game + spawn_rva)
        retained[#retained + 1] = raw
        local submitted, returned = pcall(spawn, result, resource.value, descriptor)
        if not submitted or returned ~= result then return false, 'Sample spawn did not confirm a result' end
        local entity = tonumber(result[0])
        if entity == 0 or entity == 0xFFFFFFFF then return false, 'Sample spawn did not return an entity' end
        local checked, kind = pcall(world_module.entity_type, world, entity)
        if not checked or kind ~= resource.hex then return false, 'Sample spawn entity type was not confirmed' end
        if count > 1 then pcall(observe_network, world, entity, resource) end
        return true
    end

    local function host_session()
        local checked, allowed, world_or_reason, count = pcall(session)
        if not checked then return false, 'Could not verify the sample drop session: ' .. tostring(allowed) end
        if not allowed then return false, world_or_reason end
        return true, nil, count
    end

    local function preload_sample_packages(allowed)
        local ok, world = session()
        if not ok then return end
        for tier, resource in ipairs(resources) do
            if allowed[tier] and not resource.warmed then
                local ready = package_ready(world, resource)
                if ready then resource.warmed = true end
            end
        end
    end

    return spawn, host_session, preload_sample_packages, compatibility
end
