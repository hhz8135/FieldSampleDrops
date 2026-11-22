-- Active mission difficulty and optional Treasure Map 1.4.0 sample evidence.
local function make_sample_policy(hd2, mod, options)
    options = options or {}
    local difficulties = {
        {0x953212, '418b85c4180500'},
        {0x953219, 'ffc8'},
        -- HellForge's difficulty 11 moves the weight table from +0x30 to +0x2C.
        {0x95321b, 'f30f10448730', 'f30f1044872c'},
    }
    -- Instruction checks for the tactical map's sample group, reviewed on 25480438.
    local hud_proofs = {
        {19864682, '488b1dc7b81702'}, {19864689, '80bb34e3240000'}, {19864735, '488d8b68f13e00'},
        {25872722, 'c6819501000001'}, {19838951, '488d8e50600400'}, {24970793, '4c8db510060000'},
        {24971433, '498bce'}, {24939064, '4c8b6d97'}, {24942103, '498d8d08270000'},
        {25442841, '4d8daf6c250000'}, {25442848, '4d8db7701c0000'}, {25443574, '498d4e58'},
        {25443581, 'ba89eb4244'}, {25443714, 'ba566564eb'}, {21210362, '0fb68958010000'},
        {21210377, '413954c308'}, {21210414, 'c744240404000000'}, {21210422, '4489442408'},
        {25444460, '45896500'},
    }
    local kinds = {'common', 'rare', 'super'}
    local token, baseline, last_scan, known, next_read
    local world_api, bytes, hud_world, hud_disabled

    local function matches(world, pins)
        for _, pin in ipairs(pins) do
            local expected = bytes.unhex(pin[2])
            local actual = world.view.read(world.game + pin[1], #expected)
            if not actual then return nil end
            if actual ~= expected and (not pin[3] or actual ~= bytes.unhex(pin[3])) then return false end
        end
        return true
    end

    local function active(world)
        local state = world_api.game_state(world)
        return state and state.mission == true
    end

    local function current_difficulty()
        local matched, reason, retryable = check_runtime_build(hd2)
        if not matched then return nil, reason, nil, not retryable end
        world_api = world_api or require('hd2runtime/runtime/event_world')
        bytes = bytes or require('hd2runtime/core/bytes')
        local world = world_api.open()
        if not world or not active(world) then return nil, 'Current mission is unavailable' end
        local pinned = matches(world, difficulties)
        if pinned == false then return nil, 'Mission difficulty layout changed', nil, true end
        if not pinned then return nil, 'Mission difficulty code is not readable yet' end
        local view, game = world.view, world.game
        local manager = view.pointer(game + 0x3326D10)
        local level = manager and view.u32(manager + 0x518C4)
        if not level or view.pointer(game + 0x3326D10) ~= manager or not active(world) then
            return nil, 'Current mission difficulty is unavailable'
        end
        return level, nil, world
    end

    local function treasure_log(require_open_map)
        local treasure = rawget(_G, 'ChefTreasureMap')
        if type(treasure) ~= 'table' or treasure.version ~= '1.4.0' then return nil end
        if require_open_map and treasure.status ~= 'map open' then return nil end
        local loader = rawget(_G, 'CowboyBingusModLoader')
        local folder = type(loader) == 'table' and rawget(loader, 'log_directory')
        if type(folder) ~= 'string' then
            local local_app_data = os.getenv('LOCALAPPDATA')
            if not local_app_data then return nil end
            folder = local_app_data .. '\\CowboyBingus\\Helldivers2\\Logs'
        end
        local log = io.open(folder .. '\\TreasureMap.log', 'r')
        if not log then return nil end
        local data = log:read(32769)
        log:close()
        if not data or #data > 32768 or not data:find('\nrecent events:\n', 1, true) then return nil end
        local started = data:match('^Treasure Map 1%.4%.0  %(started ([%d: %-]+), written ')
        local scans = tonumber(data:match('list scans (%d+)'))
        local map_frames = tonumber(data:match('frames %d+ %(map open (%d+)%)'))
        if not started or not scans or not map_frames
            or not data:find('\nplatform: HellForge (game build 25480438,', 1, true) then return nil end
        return {started = started, scans = scans, map_frames = map_frames, data = data,
            map_open = treasure.status == 'map open' and data:find('\nstatus: map open\n', 1, true) ~= nil}
    end

    local function read_counter(view, panel, tier)
        local index = tier - 1
        local flags = view.u32(panel + 0x190 + index * 0x110)
        if not flags or math.floor(flags / 16) % 2 == 0 then return nil end
        local address = panel + 0x1C70 + index * 0x2B8 + 0x58
        local record = view.read(address, 0x159)
        if not record or record:byte(0x159) > 14 then return nil end
        local quota, displayed
        for item = 0, record:byte(0x159) - 1 do
            local offset = item * 24
            local key = bytes.u32(record, 8 + offset)
            if key == 0x4442EB89 or key == 0xEB646556 then
                local value = bytes.u32(record, 16 + offset)
                if value > 99 or bytes.u32(record, 12 + offset) % 4096 ~= 4 then return nil end
                if key == 0x4442EB89 and quota == nil then quota = value
                elseif key == 0xEB646556 and displayed == nil then displayed = value
                else return nil end
            end
        end
        local current = view.u32(panel + 0x256C + index * 4)
        if not quota or not current or current > 99 or quota < current
            or (displayed or 0) ~= current or view.read(address, 0x159) ~= record then return nil end
        return {quota = quota, current = current}
    end

    local function map_evidence(world)
        local log = treasure_log(true)
        if not log then return end
        if not baseline or log.started ~= baseline.started then
            baseline, last_scan = log, nil
            return
        end
        if not log.map_open or log.scans <= baseline.scans or log.map_frames <= baseline.map_frames
            or log.scans == last_scan then return end
        local entries, summary, placed = log.data:match('\nloot list: read, (%d+) entries: ([^\n]*); positions known (%d+)\n')
        if not entries then return end
        local counts, parsed = {}, 0
        for name, count in summary:gmatch('([%w_]+) (%d+)') do
            if counts[name] then return end
            counts[name] = tonumber(count)
            parsed = parsed + counts[name]
        end
        if parsed ~= tonumber(entries) then return end
        if hud_world ~= world then
            local pinned = matches(world, hud_proofs)
            if pinned == false then
                hud_disabled = true
                known = {}
                mod:log('[FieldSampleDrops] Treasure Map HUD layout changed; using mission difficulty for sample types')
            end
            if not pinned then return end
            hud_world = world
        end
        local view, game = world.view, world.game
        local hud = view.pointer(game + 0x346D538)
        if not hud or view.read(hud + 0x24E334, 1) ~= '\1' or view.read(hud + 0x3EF2FD, 1) ~= '\1' then return end
        local panel = hud + 0x24E340 + 0x46050 + 0x610 + 0x2708
        local counters = {}
        for tier = 1, 3 do counters[tier] = read_counter(view, panel, tier) end
        if view.pointer(game + 0x346D538) ~= hud or view.read(hud + 0x3EF2FD, 1) ~= '\1'
            or not active(world) then return end
        last_scan = log.scans

        -- Only subtract a tier when all three explicit HUD quotas agree with a fully positioned
        -- list before collecting anything. Hidden rows and leftover loot cannot certify absence.
        local complete = tonumber(placed) == parsed
        local evidence = {}
        for tier, kind in ipairs(kinds) do
            local counter, listed = counters[tier], counts[kind] or 0
            if not counter or counter.current ~= 0 or counter.quota >= 99 or counter.quota ~= listed then
                complete = false
            end
            if counter and counter.quota > 0 and listed > 0 and listed <= counter.quota then evidence[tier] = true end
        end
        if complete then
            for tier, kind in ipairs(kinds) do evidence[tier] = (counts[kind] or 0) > 0 end
        end
        return evidence
    end

    local function provider_evidence()
        local snapshot = options.sample_snapshot(token)
        if type(snapshot) ~= 'table' or snapshot.mission ~= token or type(snapshot.counts) ~= 'table' then return end
        local complete = snapshot.kind == 'initial'
        if not complete and snapshot.kind ~= 'observed' then return end
        local evidence = {}
        for tier = 1, 3 do
            local count = snapshot.counts[tier]
            if type(count) ~= 'number' or count < 0 or count > 100000 or count % 1 ~= 0 then
                if complete then return end
            elseif count > 0 or complete then
                evidence[tier] = count > 0
            end
        end
        return evidence
    end

    local function refresh(world)
        if not token then return end
        local read, evidence
        if options.sample_snapshot then
            read, evidence = pcall(provider_evidence)
        else
            if hud_disabled then return end
            local treasure = rawget(_G, 'ChefTreasureMap')
            if type(treasure) ~= 'table' or treasure.version ~= '1.4.0' or treasure.status ~= 'map open' then return end
            local now = os.clock()
            if now < next_read then return end
            next_read = now + 0.5
            if not world then
                local read_mission, level, _, live_world = pcall(current_difficulty)
                if not read_mission or not level or not live_world then return end
                world = live_world
            end
            read, evidence = pcall(map_evidence, world)
        end
        if read and evidence then
            for tier, present in pairs(evidence) do
                if known[tier] ~= true then known[tier] = present end
            end
        end
    end

    local policy = {}
    function policy.reset()
        token, last_scan, known, next_read = {}, nil, {}, 0
        baseline = nil
        if not options.sample_snapshot then
            local read, log = pcall(treasure_log)
            if read then baseline = log end
        end
        return token
    end

    -- The mission update can observe the map between kills. Closed maps need
    -- only a Lua table lookup. Open maps are polled twice a second at most.
    function policy.refresh()
        refresh()
    end

    function policy.allowed()
        if not token then return nil, 'Mission sample policy has not started' end
        local ok, level, why, world, incompatible = pcall(options.difficulty or current_difficulty)
        if not ok then return nil, 'Current mission difficulty could not be read' end
        if type(level) ~= 'number' or level < 1 or level > 11 or level % 1 ~= 0 then
            return nil, why or 'Current mission difficulty is not ready', incompatible
        end
        refresh(world)
        local allowed = {true, level >= 4, level >= 6}
        for tier, present in pairs(known) do allowed[tier] = present end
        return allowed
    end
    return policy
end
