-- HellForge 25480438 / HD2Runtime 0.50.1
local hd2 = require('mods/skyeshade/hd2runtime')
local mod = hd2.mod()
local pickups, host_session, preload_sample_packages, compatibility_probe, local_position = make_pickups(hd2, mod)
local sample_policy = make_sample_policy(hd2, mod)
local in_mission, mission_id
local seen, progress, pending, awaiting_policy
local clear_hud
local disabled, waiting_for_compatibility

local function disable(reason)
    if disabled then return end
    disabled = true
    pending, awaiting_policy = {}, {}
    if clear_hud then clear_hud() end
    mod:log('[FieldSampleDrops] Disabled for this session: ' .. tostring(reason))
end

local function check_compatibility()
    if disabled then return false end
    local checked, ready, reason, retryable = pcall(compatibility_probe)
    if not checked then disable(ready); return false end
    if ready then return true, reason end
    if not retryable then disable(reason); return false end
    return false, reason
end

local function startup_compatibility()
    local ready, reason = check_compatibility()
    if ready then
        mod:log('[FieldSampleDrops] Compatibility verified for game build ' .. supported_game_build)
    elseif reason and reason ~= waiting_for_compatibility then
        waiting_for_compatibility = reason
        mod:log('[FieldSampleDrops] Waiting for compatibility checks: ' .. reason)
    end
    return ready
end

local ready = startup_compatibility()
if disabled then return end
if not ready then
    local timer
    timer = hd2.every(0.25, function()
        if startup_compatibility() or disabled then timer:cancel() end
    end, {scope='session',id='field_sample_drops_compatibility'})
end

local names = {'普通样本', '稀有样本', '超级样本'}
local defaults = {20, 40, 75}
local default_radius, max_radius = 30, 300
local config_path = (os.getenv('LOCALAPPDATA') or '.') .. '\\CowboyBingus\\Helldivers2\\FieldSampleDrops_CONFIG.ini'

local function valid_radius(value)
    return type(value) == 'number' and value >= 1 and value <= max_radius and value == math.floor(value)
end

local function read_ini()
    local thresholds = {unpack(defaults)}
    local show_ui = true
    local radius = default_radius
    local file = io.open(config_path, 'r')
    if file then
        for line in file:lines() do
            local key, value, suffix = line:match('^%s*([%w_]+)%s*=%s*(%d+)(.*)$')
            local n = tonumber(value)
            local tier = key and tonumber(key:match('^threshold_([123])$'))
            if tier and n >= 1 and n < math.huge then thresholds[tier] = n end
            if key == 'show_ui' then show_ui = n ~= 0 end
            if key == 'drop_radius_m' and valid_radius(n)
                and (suffix:match('^%s*$') or suffix:match('^%s*[;#]')) then
                radius = n
            end
        end
        file:close()
    else
        file = io.open(config_path, 'w')
        if file then
            file:write(('threshold_1 = 20\nthreshold_2 = 40\nthreshold_3 = 75\ndrop_radius_m = %d\nshow_ui = 1\n')
                :format(default_radius))
            file:close()
        end
    end
    return thresholds, show_ui, radius
end

local thresholds, show_ui, drop_radius_m = read_ini()
local sliders = {}
local radius_slider
local function register_menu()
    local page = hd2.options({id='field_sample_drops', title='战地样本掉落 · 联机版'})
    for tier = 1, 3 do
        sliders[tier] = page:slider({
            id='threshold_' .. tier, label=names[tier] .. '击杀阈值',
            min=1, max=math.max(200, thresholds[tier]), step=1, default=thresholds[tier],
            description='每掉落一个样本所需的近距击杀数。应用后，下一局生效。'
        })
    end
    radius_slider = page:slider({
        id='drop_radius_m', label='击杀距离上限（米）',
        min=1, max=max_radius, step=1, default=drop_radius_m,
        description='按玩家与敌人死亡位置的三维直线距离计算。应用后，下一局生效。'
    })
end
local menu_ok, menu_reason = pcall(register_menu)
if not menu_ok then mod:log('Sample drop menu unavailable: ' .. tostring(menu_reason)) end

local function menu_value(slider, allow_registered_default)
    if not slider then return end
    local ok, value = pcall(function()
        local info = slider:describe()
        if info.source == 'saved' or info.source == 'menu' or (allow_registered_default and info.registered) then
            return slider:get()
        end
    end)
    if ok then return value end
end

local function mission_settings()
    thresholds, show_ui, drop_radius_m = read_ini()
    for tier, slider in pairs(sliders) do
        local value = menu_value(slider, true)
        if type(value) == 'number' and value >= 1 and value < math.huge and value == math.floor(value) then
            thresholds[tier] = value
        end
    end
    local radius = menu_value(radius_slider, false)
    if valid_radius(radius) then drop_radius_m = radius end
end

local warned = {}
local function warn_once(reason, key)
    reason = tostring(reason)
    key = key or reason
    if not warned[key] then warned[key] = true; mod:log('[FieldSampleDrops] ' .. reason) end
end

local kill_events, stat_kills, counted
local function log_progress()
    mod:log(('[FieldSampleDrops] mission progress; kill events %d, stat kills %d, nearby counted %d, tiers %d/%d/%d, queued kills %d, pending drops %d')
        :format(kill_events, stat_kills, counted, progress[1], progress[2], progress[3], #awaiting_policy, #pending))
end

-- No inventory writes. Only failures known to precede submission are eligible for retry.
local function attempt(tier, position)
    local ok, accepted, reason, retryable = pcall(pickups, tier, position)
    if not ok then
        warn_once(('Tier %d spawn error: %s'):format(tier, tostring(accepted)), 'spawn_error_' .. tier)
        return false
    end
    if accepted then
        mod:log(('[FieldSampleDrops] spawned tier %d at %.1f %.1f %.1f'):format(tier,position.x,position.y,position.z))
        return false
    end
    warn_once(('Tier %d spawn %s: %s'):format(tier, retryable and 'deferred' or 'refused', reason or 'unknown reason'))
    return retryable == true
end

local function credit(position, allowed)
    counted = counted + 1
    if counted == 1 then warn_once('first nearby kill counted') end
    for tier = 1, 3 do
        if allowed[tier] then
            progress[tier] = progress[tier] + 1
            if progress[tier] >= thresholds[tier] then
                progress[tier] = 0
                warn_once(('tier %d threshold reached'):format(tier))
                if attempt(tier, position) then
                    pending[#pending+1] = {tier=tier, position=position}
                end
            end
        end
    end
end

local function allowed_samples()
    local allowed, reason, incompatible = sample_policy.allowed()
    if incompatible then disable(reason) end
    return allowed, reason
end

local function flush_kills()
    if #awaiting_policy == 0 then return end
    local allowed, reason = allowed_samples()
    if not allowed then
        if not disabled then warn_once(reason or 'waiting for mission difficulty') end
        return
    end
    local kills = awaiting_policy
    awaiting_policy = {}
    for _, position in ipairs(kills) do credit(position, allowed) end
end

local function point(p)
    if not p then return end
    local x, y, z = p.x, p.y, p.z
    if type(x) == 'number' and type(y) == 'number' and type(z) == 'number'
        and math.abs(x) < math.huge and math.abs(y) < math.huge and math.abs(z) < math.huge then
        return {x=x, y=y, z=z}
    end
end

local function is_host()
    local state = hd2.game_state()
    return state and state.mission and state.host == true
end

local function legacy_loaded()
    return rawget(_G, 'HD2RuntimeMod:mods/custom/monster_sample_drop')
end

local function eligible_host()
    local ok, reason, players = host_session()
    if not ok then return false, reason end
    if legacy_loaded() then
        if rawget(_G, '__MONSTER_SAMPLE_DROP_INSTALLED') then
            return false, 'Original MonsterSampleDrop is issuing rewards'
        end
        if players == 1 then return false, 'MonsterSampleDrop 1.1.0 handles solo drops' end
    end
    return true
end

hd2.events.on('entity_killed', function(e)
    if disabled or not in_mission or not e then return end
    if mission_id and e.mission and e.mission ~= mission_id then
        warn_once('Kill skipped: from a different mission')
        return
    end
    kill_events = kill_events + 1
    if kill_events == 1 then warn_once('received first entity_killed event') end
    if not e.enemy then warn_once('Kill skipped: victim is not an enemy'); return end
    if e.local_killer ~= true then
        warn_once('Kill skipped: local credit was not confirmed (local_killer=' .. tostring(e.local_killer) .. ')',
            'kill_credit')
        return
    end
    local compatible, world_or_reason = check_compatibility()
    if not compatible then if world_or_reason then warn_once(world_or_reason) end; return end
    local id = e.entity_id
    if type(id) ~= 'number' then warn_once('Kill skipped: missing victim entity ID'); return end
    if seen[id] then warn_once('Kill skipped: duplicate victim entity ID'); return end
    if not is_host() then warn_once('Kill skipped: mission host authority unavailable'); return end
    local corpse = point(e.position)
    if not corpse then warn_once('Kill skipped: victim position unavailable'); return end
    local position, why = local_position(world_or_reason)
    local origin = point(position)
    if not origin then warn_once('Kill skipped: ' .. (why or 'local Helldiver position unavailable')); return end
    seen[id] = true
    local dx, dy, dz = corpse.x-origin.x, corpse.y-origin.y, corpse.z-origin.z
    local distance_sq = dx*dx + dy*dy + dz*dz
    if distance_sq > drop_radius_m*drop_radius_m then
        warn_once(('Kill skipped: %.1f m exceeds %d m radius'):format(math.sqrt(distance_sq), drop_radius_m),
            'kill_distance')
        return
    end
    local eligible, reason = eligible_host()
    if not eligible then warn_once(reason or 'Cannot confirm the mission host'); return end
    awaiting_policy[#awaiting_policy+1] = corpse
    flush_kills()
end, {id='field_sample_drops_kill', scope='session'})

-- Aggregate stats corroborate event delivery. Only entity_killed has the victim position.
hd2.events.on('player_kill_credited', function(e)
    if disabled or not in_mission or not e or (e.mission and mission_id and e.mission ~= mission_id) then return end
    if type(e.kills) ~= 'number' or e.kills <= 0 then return end
    if stat_kills == 0 then warn_once('received first player_kill_credited stat event') end
    stat_kills = stat_kills + e.kills
end, {id='field_sample_drops_kill_stats', scope='session'})

-- Original compact progress HUD.
local hud_state = { gui = nil, gui_world = nil, ids = {}, last_key = '' }

clear_hud = function()
    local sr = rawget(_G, 'stingray') or _G
    local Gui = sr.Gui
    if hud_state.gui and Gui then
        for _, item in ipairs(hud_state.ids) do
            pcall(Gui[item[1]], hud_state.gui, item[2])
        end
    end
    hud_state.ids = {}
    hud_state.last_key = ''
end

local function render_hud()
    if not in_mission or not show_ui then
        if #hud_state.ids > 0 then clear_hud() end
        return
    end

    local sr = rawget(_G, 'stingray') or _G
    local App, World, Gui = sr.Application, sr.World, sr.Gui
    if not App or not World or not Gui then return end

    local ok_worlds, worlds = pcall(App.worlds)
    local ok_main, main_world = pcall(App.main_world)
    if not ok_worlds or not ok_main or not main_world or not worlds or #worlds == 0 then
        clear_hud()
        return
    end

    if not hud_state.gui or not hud_state.gui_world then
        for _, v in ipairs(worlds) do
            if v ~= main_world then
                hud_state.gui_world = v
                break
            end
        end
        if not hud_state.gui_world then hud_state.gui_world = main_world end
        if hud_state.gui_world then
            local ok_g, g = pcall(World.create_screen_gui, hud_state.gui_world, 'scale', 1, 1)
            if ok_g and g then hud_state.gui = g end
        end
    end

    if not hud_state.gui then return end

    local w, h = Gui.resolution()
    if type(w) ~= 'number' or type(h) ~= 'number' or w <= 0 or h <= 0 then return end

    local key = table.concat(progress, ',') .. '/' .. w .. '/' .. h
    if key == hud_state.last_key then return end
    clear_hud()
    hud_state.last_key = key

    local scale = math.min(w / 1920, h / 1080)
    local box_w = 210 * scale
    local box_h = 24 * scale
    local box_x = (w * 0.02)
    local box_y = h - ((legacy_loaded() and 270 or 240) * scale)

    local V2 = sr.Vector2 or function(x, y) return { x = x, y = y } end
    local Color = sr.Color or function(a, r, g, b) return { a = a, r = r, g = g, b = b } end

    -- 1. 半透明微圆角底框
    local bg_col = Color(140, 10, 15, 20)
    local ok_r, r_id = pcall(Gui.rect, hud_state.gui, V2(box_x, box_y), V2(box_w, box_h), bg_col)
    if ok_r and r_id then table.insert(hud_state.ids, { 'destroy_rect', r_id }) end

    -- 2. 文本显示三路样本进度：SAMPLE: 0/20 | 0/40 | 0/75
    local line = string.format("SAMPLE: %d/%d | %d/%d | %d/%d",
        progress[1], thresholds[1], progress[2], thresholds[2], progress[3], thresholds[3])
    local text_col = Color(230, 230, 230, 230)
    local font_size = 13 * scale
    local text_pos = V2(box_x + 6 * scale, box_y + 4 * scale)

    local ok_t, t_id = pcall(Gui.text, hud_state.gui, line, 'core/performance_hud/debug', font_size, 'core/performance_hud/debug', text_pos, text_col)
    if ok_t and t_id then table.insert(hud_state.ids, { 'destroy_text', t_id }) end
end



hd2.events.on('mission_started', function(e)
    if disabled then return end
    mission_settings()
    seen, progress, pending, awaiting_policy, warned = {}, {0,0,0}, {}, {}, {}
    kill_events, stat_kills, counted = 0, 0, 0
    mission_id, in_mission = e.mission, true
    sample_policy.reset()
    mod:log(('[FieldSampleDrops] mission started; thresholds %d/%d/%d, radius %d m')
        :format(thresholds[1], thresholds[2], thresholds[3], drop_radius_m))
    local preload_tick = 0
    local ticks = 0
    hd2.every(0.25, function()
        if disabled or not in_mission then return end
        ticks = ticks + 1
        if ticks == 120 then log_progress() end
        local compatible, waiting = check_compatibility()
        if not compatible then if waiting then warn_once(waiting) end; return end
        if not is_host() or (legacy_loaded() and not eligible_host()) then
            pending, awaiting_policy = {}, {}
            if #hud_state.ids > 0 then clear_hud() end
            return
        end
        sample_policy.refresh()
        if preload_tick == 0 then
            local allowed, reason = allowed_samples()
            if disabled then return end
            if allowed then
                local ok, why = pcall(preload_sample_packages, allowed, warn_once)
                if not ok then warn_once('Sample preload error: ' .. tostring(why), 'preload_error') end
            elseif reason then
                warn_once(reason)
            end
        end
        preload_tick = (preload_tick + 1) % 8
        if #pending > 0 then
            local remaining, waiting = {}, {}
            for _, item in ipairs(pending) do
                if waiting[item.tier] or attempt(item.tier, item.position) then
                    waiting[item.tier] = true
                    remaining[#remaining+1] = item
                end
            end
            pending = remaining
        end
        flush_kills()
        pcall(render_hud)
    end, {scope='mission',id='field_sample_drops_tick'})
end, {id='field_sample_drops_start', scope='session'})

hd2.events.on('mission_ended', function()
    if in_mission and not disabled then log_progress() end
    in_mission, mission_id = false, nil
    seen, pending, awaiting_policy = {}, {}, {}
    clear_hud()
    hud_state.gui, hud_state.gui_world = nil, nil
end, {id='field_sample_drops_end', scope='session'})
mod:log(('[FieldSampleDrops] 1.2.1 loaded; radius 1-%d m, default %d m'):format(max_radius, default_radius))
