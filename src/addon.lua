-- HellForge 25480438 / HD2Runtime 0.50.1
local hd2 = require('mods/skyeshade/hd2runtime')
local mod = hd2.mod()
local pickups, host_session, preload_sample_packages = make_pickups(hd2, mod)
local sample_policy = make_sample_policy(hd2, mod)
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

local in_mission, mission_id
local seen, progress, pending, awaiting_policy
local warned = {}
local function warn_once(reason)
    reason = tostring(reason)
    if not warned[reason] then warned[reason] = true; mod:log('[FieldSampleDrops] ' .. reason) end
end

-- No inventory writes. Only failures known to precede submission are eligible for retry.
local function attempt(tier, position)
    local ok, accepted, reason, retryable = pcall(pickups, tier, position)
    if not ok then warn_once(accepted); return false end
    if accepted then
        mod:log(('[FieldSampleDrops] spawned tier %d at %.1f %.1f %.1f'):format(tier,position.x,position.y,position.z))
        return false
    end
    warn_once(reason or 'spawn refused')
    return retryable == true
end

local function credit(position, allowed)
    for tier = 1, 3 do
        if allowed[tier] then
            progress[tier] = progress[tier] + 1
            if progress[tier] >= thresholds[tier] then
                progress[tier] = 0
                if attempt(tier, position) then
                    pending[#pending+1] = {tier=tier, position=position}
                end
            end
        end
    end
end

local function flush_kills()
    if #awaiting_policy == 0 then return end
    local allowed, reason = sample_policy.allowed()
    if not allowed then warn_once(reason or 'waiting for mission difficulty'); return end
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
    if not in_mission or not e or not e.enemy or e.local_killer ~= true then return end
    if mission_id and e.mission and e.mission ~= mission_id then return end
    local id = e.entity_id
    if type(id) ~= 'number' or seen[id] or not is_host() then return end
    local corpse = point(e.position)
    if not corpse then return end
    local player = hd2.local_player()
    local origin = player and point(player:position())
    if not origin then return end
    seen[id] = true
    local dx, dy, dz = corpse.x-origin.x, corpse.y-origin.y, corpse.z-origin.z
    if dx*dx + dy*dy + dz*dz > drop_radius_m*drop_radius_m then return end
    local eligible, reason = eligible_host()
    if not eligible then warn_once(reason or 'Cannot confirm the mission host'); return end
    awaiting_policy[#awaiting_policy+1] = corpse
    flush_kills()
end, {id='field_sample_drops_kill', scope='session'})

-- Original compact progress HUD.
local hud_state = { gui = nil, gui_world = nil, ids = {}, last_key = '' }

local function clear_hud()
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
    mission_settings()
    seen, progress, pending, awaiting_policy, warned = {}, {0,0,0}, {}, {}, {}
    mission_id, in_mission = e.mission, true
    sample_policy.reset()
    mod:log(('[FieldSampleDrops] mission started; thresholds %d/%d/%d, radius %d m')
        :format(thresholds[1], thresholds[2], thresholds[3], drop_radius_m))
    local preload_tick = 0
    hd2.every(0.25, function()
        if not in_mission then return end
        if not is_host() or (legacy_loaded() and not eligible_host()) then
            pending, awaiting_policy = {}, {}
            if #hud_state.ids > 0 then clear_hud() end
            return
        end
        sample_policy.refresh()
        if preload_tick == 0 then
            local allowed = sample_policy.allowed()
            if allowed then
                local ok, why = pcall(preload_sample_packages, allowed)
                if not ok then warn_once(why) end
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
    in_mission, mission_id = false, nil
    seen, pending, awaiting_policy = {}, {}, {}
    clear_hud()
    hud_state.gui, hud_state.gui_world = nil, nil
end, {id='field_sample_drops_end', scope='session'})
mod:log(('[FieldSampleDrops] 1.2.0 loaded; radius 1-%d m, default %d m'):format(max_radius, default_radius))
