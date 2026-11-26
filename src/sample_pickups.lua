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
    local bridge, bridge_mod, bridge_sdk

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
        bridge_sdk = info.sdk
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

    local function displacement(world, rva, opcode)
        local code = world.view.read(world.game + rva, #opcode + 4)
        if not code or code:sub(1, #opcode) ~= opcode then return end
        local offset = bytes.u32(code, #opcode)
        return offset < 0x80000000 and offset or offset - 0x100000000
    end

    local layout_world, network_map, entity_map, entity_records
    local function verify_entity_layout(world)
        if layout_world == world then return true end
        -- SDK 20 can move both maps and their shared 24-byte records.
        -- Verify their live displacements in EntityOfNetwork and EntityDescriptor.
        local map = displacement(world, 0xFD9BF9, '\x49\x8B\xBB')
        local entities = displacement(world, 0xFD9D83, '\x49\x8B\x9A')
        local records = displacement(world, 0xFD9C50, '\x48\x8D\x80')
        local descriptors = displacement(world, 0xFD9DDB, '\x48\x8D\x80')
        if not map or not entities or not records or not descriptors or records ~= descriptors + 1
            or map % 8 ~= 0 or entities % 8 ~= 0
            or displacement(world, 0xFD9BC9, '\x45\x8B\x93') ~= map + 8
            or displacement(world, 0xFD9C00, '\x41\x8B\xB3') ~= map + 12
            or displacement(world, 0xFD9BD7, '\x41\x8B\x9B') ~= map + 16
            or displacement(world, 0xFD9D68, '\x45\x8B\x8A') ~= entities + 8 then return end
        layout_world, network_map, entity_map, entity_records = world, map, entities, descriptors * 8
        if map ~= 0xF22EC8 or entities ~= 0xF1AEB0 or entity_records ~= 0xF32F18 then
            mod:log('[FieldSampleDrops] using HellForge relocated entity lookup')
        end
        return true
    end

    local function uses_movable_entities()
        return (tonumber(bridge_sdk) or 0) >= 20
    end

    local function entity_slot(world, address, id)
        local view = world.view
        local header = view.read(address, 20)
        if not header then return end
        local slots, capacity = bytes.pointer(header, 0), bytes.u32(header, 8)
        if slots == 0 or capacity < 2 or capacity > 65536 or capacity % 2 ~= 0 then return end
        local empty, multiplier = bytes.u32(header, 12), bytes.u32(header, 16)
        local start = world_module.mul32(id, multiplier)
        for probe = 0, math.min(capacity, 4096) - 1 do
            local bucket = view.read(slots + ((start + probe) % capacity) * 8, 8)
            if not bucket then return end
            local key = bytes.u32(bucket, 0)
            if key == empty then return end
            if key == id then
                local index = bytes.u32(bucket, 4)
                return index < capacity and index or nil
            end
        end
    end

    local function local_position(world)
        if not uses_movable_entities() then
            local player = hd2.local_player()
            return player and player:position()
        end
        if not verify_entity_layout(world) then
            return nil, 'HellForge entity layout could not be verified'
        end

        local network_id
        -- The player list reads the network id independently of its legacy entity lookup.
        for _, player in ipairs(world_module.players(world, true)) do
            if player['local'] then network_id = player.avatar_network_id; break end
        end
        if not network_id or network_id == 0x7FFF or network_id == 0xFFFFFFFF then return end
        local view = world.view
        local manager = view.pointer(world.game + 0x346BF98)
        local index = manager and manager ~= 0 and entity_slot(world, manager + network_map, network_id)
        if not index then return end
        local id = view.u32(manager + entity_records + 8 + index * 24)
        local state = id and world_module.entity_exists(world, id) and world_module.entity_state(world, id)
        local avatar = state and state.descriptor
        local info = avatar and world_module.type_info(avatar.type)
        if avatar and avatar.entity == id and avatar.goid == network_id and avatar.owned and state.life < 2
            and info and info.avatar then return world_module.unit_position(world, avatar.unit) end
    end

    local function sample_identity(world, id, resource, check_network)
        if not uses_movable_entities() then
            if world_module.entity_type(world, id) ~= resource.hex then return false end
            return true, check_network and world_module.entity_network(world, id) or nil
        end
        if not verify_entity_layout(world) then return false end
        local view = world.view
        local manager = view.pointer(world.game + 0x346BF98)
        local index = manager and manager ~= 0 and entity_slot(world, manager + entity_map, id)
        local record = index and view.read(manager + entity_records + index * 24, 24)
        if not record or record:sub(1, 8) ~= resource.raw or bytes.u32(record, 8) ~= id then return false end
        if check_network then
            local network_id = bytes.u32(record, 16)
            if network_id ~= 0x7FFF and entity_slot(world, manager + network_map, network_id) == index then
                return true, network_id
            end
        end
        return true
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
        if not readable then return false, 'Could not read residency for sample package ' .. hex .. ': ' .. tostring(state), true end
        return false, 'Sample package ' .. hex .. ' is ' .. tostring(state) .. ' and HellForge could not hold it', true
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
        if uses_movable_entities() and not verify_entity_layout(world) then
            return false, 'HellForge entity layout could not be verified', true
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
            if not w then return nil end
            local _, id = sample_identity(w, entity, resource, true)
            return id
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
        local checked, confirmed = pcall(sample_identity, world, entity, resource)
        if not checked or not confirmed then return false, 'Sample spawn entity type was not confirmed' end
        if count > 1 then pcall(observe_network, world, entity, resource) end
        return true
    end

    local function host_session()
        local checked, allowed, world_or_reason, count = pcall(session)
        if not checked then return false, 'Could not verify the sample drop session: ' .. tostring(allowed) end
        if not allowed then return false, world_or_reason end
        return true, nil, count
    end

    local function preload_sample_packages(allowed, warn_once)
        local ok, world = session()
        if not ok then warn_once('Preload deferred: ' .. world); return end
        for tier, resource in ipairs(resources) do
            if allowed[tier] and not resource.warmed then
                local ready, reason = package_ready(world, resource)
                if ready then
                    resource.warmed = true
                elseif reason then
                    warn_once(('Preload tier %d: %s'):format(tier, reason))
                end
            end
        end
    end

    return spawn, host_session, preload_sample_packages, compatibility, local_position
end
