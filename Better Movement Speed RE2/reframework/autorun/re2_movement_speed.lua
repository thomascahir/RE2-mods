-- Better Movement Speed RE2
-- REFramework script that changes RE2 player animation-layer speed.

local game_name = reframework:get_game_name()
if game_name ~= "re2" then return end

local MOD_NAME = "Better Movement Speed RE2"
local CONFIG_PATH = "re2_movement_speed.json"
local WEAPON_SCAN_PATH = "re2_movement_speed_weapon_scan.txt"
local DEFAULT_SPEED = 1.0

local motion_type = sdk.typeof("via.motion.Motion")
local equipment_type = sdk.typeof(sdk.game_namespace("survivor.Equipment"))
local hotkey_listening = false
local hotkey_prev_down = false
local last_layer0 = nil
local reload_layers = {}
local melee_layers = {}
local method_hooks_installed = false

local state = {
    player_found = false,
    motion_found = false,
    layer_found = false,
    last_motion = "?",
    last_move_type = "?",
    current_speed = DEFAULT_SPEED,
    last_error = nil,
    layer_names = {},
    last_scan_path = "?",
    reload_active = false,
    reload_hook_installed = false,
    reload_hook_name = "?",
    request_reload_hits = 0,
    execute_reload_hits = 0,
    execute_end_reload_hits = 0,
    gun_execute_reload_hits = 0,
    motion_speed_hits = 0,
}

local VK_NAMES = {
    [0x08] = "Backspace", [0x09] = "Tab", [0x0D] = "Enter", [0x14] = "CapsLock",
    [0x20] = "Space", [0x21] = "PgUp", [0x22] = "PgDn", [0x23] = "End", [0x24] = "Home",
    [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down",
    [0x2D] = "Insert", [0x2E] = "Delete",
}

for i = 0x30, 0x39 do VK_NAMES[i] = string.char(i) end
for i = 0x41, 0x5A do VK_NAMES[i] = string.char(i) end
for i = 1, 24 do VK_NAMES[0x6F + i] = "F" .. i end
for i = 0, 9 do VK_NAMES[0x60 + i] = "Num" .. i end
VK_NAMES[0x6A] = "Num*"; VK_NAMES[0x6B] = "Num+"; VK_NAMES[0x6D] = "Num-"
VK_NAMES[0x6E] = "Num."; VK_NAMES[0x6F] = "Num/"

local SCAN_KEYS = {}
for i = 0x70, 0x7B do SCAN_KEYS[#SCAN_KEYS + 1] = i end
for i = 0x30, 0x39 do SCAN_KEYS[#SCAN_KEYS + 1] = i end
for i = 0x41, 0x5A do SCAN_KEYS[#SCAN_KEYS + 1] = i end
for i = 0x60, 0x6F do SCAN_KEYS[#SCAN_KEYS + 1] = i end
for _, k in ipairs({ 0x08, 0x09, 0x14, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E }) do
    SCAN_KEYS[#SCAN_KEYS + 1] = k
end

local cfg = {
    enabled = true,
    hotkey_enabled = false,
    hotkey_key = 0,
    walk_speed = 1.2,
    run_speed = 1.2,
    melee_speed = 1.0,
    reload_speed = 1.0,
    dev_mode = false,
}

-- Clamp number to usable speed bounds.
local function clamp_number(value, min_value, max_value, fallback)
    local n = tonumber(value)
    if n == nil then n = fallback end
    n = tonumber(n) or 0.0
    if min_value ~= nil and n < min_value then n = min_value end
    if max_value ~= nil and n > max_value then n = max_value end
    return n
end

-- Normalise config after load or UI edits.
local function normalize_config()
    cfg.enabled = cfg.enabled == true
    cfg.hotkey_enabled = cfg.hotkey_enabled == true
    cfg.hotkey_key = math.floor(tonumber(cfg.hotkey_key or 0) or 0)
    cfg.walk_speed = clamp_number(cfg.walk_speed, 0.1, 5.0, 1.2)
    cfg.run_speed = clamp_number(cfg.run_speed, 0.1, 5.0, 1.2)
    cfg.melee_speed = clamp_number(cfg.melee_speed, 0.1, 5.0, 1.0)
    cfg.reload_speed = clamp_number(cfg.reload_speed, 0.1, 5.0, 1.0)
    cfg.dev_mode = cfg.dev_mode == true
end

-- Load user config from REFramework data folder.
local function load_config()
    local ok, data = pcall(json.load_file, CONFIG_PATH)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do
            if cfg[k] ~= nil then cfg[k] = v end
        end
    end
    normalize_config()
end

-- Save user config to REFramework data folder.
local function save_config()
    normalize_config()
    pcall(json.dump_file, CONFIG_PATH, cfg)
end

-- Return display name for virtual key code.
local function get_vk_name(vk)
    return VK_NAMES[vk] or string.format("0x%02X", tonumber(vk or 0) or 0)
end

-- Safely call managed method and return nil on failure.
local function safe_call(obj, method, ...)
    if obj == nil or method == nil then return nil end
    local ok, ret = pcall(obj.call, obj, method, ...)
    if ok then return ret end
    return nil
end

-- Resolve first usable method from candidate names.
local function find_method(type_def, names)
    if type_def == nil then return nil, nil end
    for _, name in ipairs(names or {}) do
        local ok, method = pcall(type_def.get_method, type_def, name)
        if ok and method ~= nil then return method, name end
    end
    return nil, nil
end

-- Hook method if it exists and count hits in Dev Mode.
local function hook_counter(type_name, names, state_key, pre_fn, post_fn)
    local td = sdk.find_type_definition(type_name)
    local method = find_method(td, names)
    if method == nil then return false end
    sdk.hook(method, function(_args)
        state[state_key] = (tonumber(state[state_key] or 0) or 0) + 1
        if pre_fn ~= nil then pre_fn() end
        return nil
    end, function(retval)
        if post_fn ~= nil then post_fn() end
        return retval
    end)
    return true
end

-- Install native reload-speed hook and reload lifecycle probes once.
local function install_method_hooks()
    if method_hooks_installed then return true end
    method_hooks_installed = true

    local eq_td = sdk.find_type_definition(sdk.game_namespace("survivor.Equipment"))
    local speed_method, speed_name = find_method(eq_td, { "getMotionPlaySpeed" })
    if speed_method ~= nil then
        sdk.hook(speed_method, function(_args)
            return nil
        end, function(retval)
            state.motion_speed_hits = state.motion_speed_hits + 1
            if cfg.enabled == true and state.reload_active == true then
                return sdk.float_to_ptr(cfg.reload_speed)
            end
            return retval
        end)
        state.reload_hook_installed = true
        state.reload_hook_name = speed_name
    else
        state.reload_hook_name = "getMotionPlaySpeed missing"
    end

    hook_counter(sdk.game_namespace("survivor.Equipment"), { "requestReload" }, "request_reload_hits", function() state.reload_active = true end)
    hook_counter(sdk.game_namespace("survivor.Equipment"), { "executeReload" }, "execute_reload_hits", function() state.reload_active = true end)
    hook_counter(sdk.game_namespace("survivor.Equipment"), { "executeEndReload" }, "execute_end_reload_hits", nil, function() state.reload_active = false end)
    hook_counter(sdk.game_namespace("implement.Gun"), { "executeReload" }, "gun_execute_reload_hits", function() state.reload_active = true end)
    return true
end

-- Safely read managed field and return nil on failure.
local function safe_field(obj, field_name)
    if obj == nil or field_name == nil then return nil end
    local ok, ret = pcall(function() return obj:get_field(field_name) end)
    if ok then return ret end
    return nil
end

-- Get RE2 player GameObject through ropeway PlayerManager.
local function get_player()
    local manager = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
    if manager == nil then return nil end
    return safe_call(manager, "get_CurrentPlayer")
end

-- Get component from GameObject by cached type.
local function get_component(game_object, type_def)
    if game_object == nil or type_def == nil then return nil end
    return safe_call(game_object, "getComponent(System.Type)", type_def)
end

-- Get equipped weapon object from player equipment.
local function get_weapon()
    local player = get_player()
    local equipment = get_component(player, equipment_type)
    if equipment == nil then return nil, nil, nil end
    local weapon = safe_field(equipment, "<EquipWeapon>k__BackingField")
    local weapon_go = weapon and safe_call(weapon, "get_GameObject") or nil
    return weapon, weapon_go, equipment
end

-- Get via.motion.Motion component from player GameObject.
local function get_player_motion()
    local player = get_player()
    state.player_found = player ~= nil
    if player == nil or motion_type == nil then
        state.motion_found = false
        return nil
    end
    local motion = get_component(player, motion_type)
    state.motion_found = motion ~= nil
    return motion
end

-- True when SDK member name is relevant to reload timing search.
local function scanner_match(name)
    local lower = tostring(name or ""):lower()
    local tokens = { "reload", "ammo", "bullet", "magazine", "mag", "load", "remain", "count", "timer", "time", "speed", "motion", "status", "state", "frame", "request", "equip", "fire", "shell" }
    for _, token in ipairs(tokens) do
        if lower:find(token, 1, true) then return true end
    end
    return false
end

-- Convert scanner values to compact text.
local function scan_value_text(value)
    if value == nil then return "nil" end
    local t = type(value)
    if t == "number" or t == "boolean" or t == "string" then return tostring(value) end
    if t == "userdata" then
        local ok_int, n = pcall(sdk.to_int64, value)
        if ok_int and tonumber(n) ~= nil then return tostring(n) end
        local ok_float, f = pcall(sdk.to_float, value)
        if ok_float and tonumber(f) ~= nil then return tostring(f) end
        local ok_td, td = pcall(function() return value:get_type_definition() end)
        if ok_td and td ~= nil then return tostring(td:get_full_name() or td:get_name() or "userdata") end
    end
    return tostring(value)
end

-- Append filtered type surface to scanner output.
local function append_surface(lines, label, obj)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "[" .. tostring(label) .. "]"
    if obj == nil then
        lines[#lines + 1] = "missing"
        return
    end
    local td = nil
    pcall(function() td = obj:get_type_definition() end)
    if td == nil then
        lines[#lines + 1] = "type=?"
        return
    end
    lines[#lines + 1] = "type=" .. tostring(td:get_full_name() or td:get_name() or "?")

    pcall(function()
        for _, field in ipairs(td:get_fields() or {}) do
            local name = field:get_name()
            if scanner_match(name) then
                lines[#lines + 1] = "field " .. tostring(name) .. "=" .. scan_value_text(safe_field(obj, name))
            end
        end
    end)

    pcall(function()
        local seen = {}
        for _, method in ipairs(td:get_methods() or {}) do
            local name = method:get_name()
            if scanner_match(name) and seen[name] ~= true then
                seen[name] = true
                if tostring(name):sub(1, 4) == "get_" then
                    lines[#lines + 1] = "getter " .. tostring(name) .. "=" .. scan_value_text(safe_call(obj, name))
                else
                    lines[#lines + 1] = "method " .. tostring(name)
                end
            end
        end
    end)
end

-- Write current weapon/equipment SDK surface to data text file.
local function write_weapon_scan(reason)
    local weapon, weapon_go, equipment = get_weapon()
    local lines = {
        "Better Movement Speed RE2 weapon scan",
        "reason=" .. tostring(reason or "manual"),
        "motion=" .. tostring(state.last_motion),
        "move_type=" .. tostring(state.last_move_type),
    }
    append_surface(lines, "equipment", equipment)
    append_surface(lines, "weapon", weapon)
    append_surface(lines, "weapon_gameobject", weapon_go)

    local ok, err = pcall(function()
        local file = io.open("reframework/data/" .. WEAPON_SCAN_PATH, "w")
        if file == nil then return false end
        for _, line in ipairs(lines) do file:write(tostring(line), "\n") end
        file:close()
        return true
    end)
    state.last_scan_path = WEAPON_SCAN_PATH
    if not ok then state.last_error = tostring(err or "weapon scan write failed") end
    return ok
end

-- Get motion layer by index from player motion component.
local function get_player_layer(index)
    local motion = get_player_motion()
    if motion == nil then
        state.layer_found = false
        return nil
    end
    local layer = safe_call(motion, "getLayer", index or 0)
    state.layer_found = layer ~= nil
    return layer
end

-- Read active motion name from layer.
local function get_layer_motion_name(layer)
    if layer == nil then return nil end
    local node = safe_call(layer, "get_HighestWeightMotionNode")
    if node == nil then return nil end
    return safe_call(node, "get_MotionName")
end

-- Classify animation name into tunable movement bucket.
local function classify_motion(name)
    if name == nil then return nil end
    local lower = tostring(name):lower()
    if lower:find("finish", 1, true) or lower:find("execution", 1, true) or lower:find("death", 1, true) then return nil end
    if lower:find("reload", 1, true) or lower:find("reload", 1, false) or lower:find("magazine", 1, true) or lower:find("reload", 1, true) or lower:find("_rl", 1, true) or lower:find("rl_", 1, true) then return "reload" end
    if lower:find("attack", 1, true) or lower:find("melee", 1, true) or lower:find("knife", 1, true) then return "melee" end
    if lower:find("walk", 1, true) then return "walk" end
    if lower:find("run", 1, true) or lower:find("jog", 1, true) or lower:find("dash", 1, true) then return "run" end
    return nil
end

-- Return configured speed for motion bucket.
local function speed_for_move_type(move_type)
    if move_type == "walk" then return cfg.walk_speed end
    if move_type == "run" then return cfg.run_speed end
    if move_type == "melee" then return cfg.melee_speed end
    if move_type == "reload" then return cfg.reload_speed end
    return DEFAULT_SPEED
end

-- Apply speed to motion layer.
local function set_layer_speed(layer, speed)
    if layer == nil then return false end
    local ok, err = pcall(layer.call, layer, "set_Speed", speed)
    if not ok then state.last_error = tostring(err or "set_Speed failed") end
    return ok == true
end

-- Restore tracked layers to default speed.
local function reset_tracked_layers()
    if last_layer0 ~= nil then set_layer_speed(last_layer0, DEFAULT_SPEED) end
    for _, layer in ipairs(reload_layers) do set_layer_speed(layer, DEFAULT_SPEED) end
    for _, layer in ipairs(melee_layers) do set_layer_speed(layer, DEFAULT_SPEED) end
    last_layer0 = nil
    reload_layers = {}
    melee_layers = {}
    state.current_speed = DEFAULT_SPEED
end

-- Update layer zero movement speed from active animation.
local function update_base_layer()
    local layer = get_player_layer(0)
    if layer == nil then
        reset_tracked_layers()
        state.last_motion = "?"
        state.last_move_type = "?"
        return
    end

    local name = get_layer_motion_name(layer)
    local move_type = classify_motion(name)
    state.last_motion = tostring(name or "?")
    state.last_move_type = tostring(move_type or "default")
    last_layer0 = layer

    local speed = DEFAULT_SPEED
    if cfg.enabled == true and move_type ~= nil then speed = speed_for_move_type(move_type) end
    set_layer_speed(layer, speed)
    state.current_speed = speed
end

-- Update upper animation layers for reload and melee speed.
local function update_upper_layers()
    local motion = get_player_motion()
    if motion == nil or cfg.enabled ~= true then
        for _, layer in ipairs(reload_layers) do set_layer_speed(layer, DEFAULT_SPEED) end
        for _, layer in ipairs(melee_layers) do set_layer_speed(layer, DEFAULT_SPEED) end
        reload_layers = {}
        melee_layers = {}
        state.reload_active = false
        return
    end

    for _, layer in ipairs(reload_layers) do set_layer_speed(layer, DEFAULT_SPEED) end
    for _, layer in ipairs(melee_layers) do set_layer_speed(layer, DEFAULT_SPEED) end

    local next_reload = {}
    local next_melee = {}
    state.layer_names = {}
    state.reload_active = false
    for i = 1, 8 do
        local layer = safe_call(motion, "getLayer", i)
        local name = get_layer_motion_name(layer)
        local move_type = classify_motion(name)
        state.layer_names[i] = tostring(name or "?") .. " => " .. tostring(move_type or "default")
        if move_type == "reload" then
            state.reload_active = true
            set_layer_speed(layer, cfg.reload_speed)
            next_reload[#next_reload + 1] = layer
        elseif move_type == "melee" then
            set_layer_speed(layer, cfg.melee_speed)
            next_melee[#next_melee + 1] = layer
        end
    end

    reload_layers = next_reload
    melee_layers = next_melee
end

-- Update hotkey toggle state.
local function update_hotkey()
    if cfg.hotkey_enabled ~= true or cfg.hotkey_key <= 0 then
        hotkey_prev_down = false
        return
    end
    local ok, down = pcall(reframework.is_key_down, reframework, cfg.hotkey_key)
    if ok and down and not hotkey_prev_down then
        cfg.enabled = not cfg.enabled
        if cfg.enabled ~= true then reset_tracked_layers() end
        save_config()
    end
    hotkey_prev_down = ok and down or false
end

-- Apply preset to all speed sliders.
local function apply_preset(speed)
    cfg.walk_speed = speed
    cfg.run_speed = speed
    cfg.reload_speed = speed
    normalize_config()
end

-- Draw hotkey picker UI.
local function draw_hotkey_picker()
    local changed = false
    local c, v = imgui.checkbox("Hotkey", cfg.hotkey_enabled)
    if c then cfg.hotkey_enabled = v; changed = true end
    imgui.same_line()
    if hotkey_listening then
        imgui.text_colored("Press key... ESC cancel", 0xFF44BBFF)
        local esc_ok, esc_down = pcall(reframework.is_key_down, reframework, 0x1B)
        if esc_ok and esc_down then
            hotkey_listening = false
        else
            for _, vk in ipairs(SCAN_KEYS) do
                local k_ok, k_down = pcall(reframework.is_key_down, reframework, vk)
                if k_ok and k_down then
                    cfg.hotkey_key = vk
                    hotkey_listening = false
                    changed = true
                    break
                end
            end
        end
    else
        local key_label = cfg.hotkey_key > 0 and get_vk_name(cfg.hotkey_key) or "None"
        if imgui.button("[" .. key_label .. "]##hk_set") then hotkey_listening = true end
        if cfg.hotkey_key > 0 then
            imgui.same_line()
            if imgui.button("X##hk_clear") then cfg.hotkey_key = 0; changed = true end
        end
    end
    return changed
end

-- Draw preset buttons.
local function draw_presets()
    local changed = false
    local presets = { 1.0, 1.1, 1.2, 1.3, 1.5, 2.0, 3.0 }
    for i, speed in ipairs(presets) do
        if i > 1 then imgui.same_line() end
        local label = speed == 1.0 and "Default" or string.format("x%.1f", speed)
        if imgui.button(label) then
            apply_preset(speed)
            changed = true
        end
    end
    return changed
end

-- Draw developer-only runtime state.
local function draw_dev()
    imgui.text("Player: " .. tostring(state.player_found))
    imgui.text("Motion: " .. tostring(state.motion_found))
    imgui.text("Layer0: " .. tostring(state.layer_found))
    imgui.text("Motion Name: " .. tostring(state.last_motion))
    imgui.text("Move Type: " .. tostring(state.last_move_type))
    imgui.text("Reload Active: " .. tostring(state.reload_active))
    imgui.text("Native Reload Hook: " .. tostring(state.reload_hook_installed) .. " " .. tostring(state.reload_hook_name))
    imgui.text("getMotionPlaySpeed hits: " .. tostring(state.motion_speed_hits))
    imgui.text("requestReload hits: " .. tostring(state.request_reload_hits))
    imgui.text("executeReload hits: " .. tostring(state.execute_reload_hits))
    imgui.text("executeEndReload hits: " .. tostring(state.execute_end_reload_hits))
    imgui.text("Gun.executeReload hits: " .. tostring(state.gun_execute_reload_hits))
    imgui.text("Current Speed: " .. string.format("%.2f", tonumber(state.current_speed or 1.0) or 1.0))
    if imgui.tree_node("Layers") then
        imgui.text("0: " .. tostring(state.last_motion) .. " => " .. tostring(state.last_move_type))
        for i = 1, 8 do
            imgui.text(tostring(i) .. ": " .. tostring(state.layer_names[i] or "?"))
        end
        imgui.tree_pop()
    end
    if imgui.button("Write Weapon Scan") then write_weapon_scan("ui_button") end
    imgui.text("Scan File: " .. tostring(state.last_scan_path))
    if state.last_error ~= nil then imgui.text("Last Error: " .. tostring(state.last_error)) end
end

load_config()
install_method_hooks()

re.on_pre_application_entry("LateUpdateBehavior", function()
    update_hotkey()
    if cfg.enabled == true then
        update_base_layer()
        update_upper_layers()
    else
        reset_tracked_layers()
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node(MOD_NAME) then return end

    local changed = false
    local c, v = imgui.checkbox("Enabled", cfg.enabled)
    if c then
        cfg.enabled = v
        changed = true
        if v ~= true then reset_tracked_layers() end
    end

    if draw_hotkey_picker() then changed = true end
    imgui.spacing()
    if draw_presets() then changed = true end
    imgui.spacing()

    c, v = imgui.slider_float("Walk Speed", cfg.walk_speed, 0.1, 5.0, "%.2f")
    if c then cfg.walk_speed = v; changed = true end
    c, v = imgui.slider_float("Run Speed", cfg.run_speed, 0.1, 5.0, "%.2f")
    if c then cfg.run_speed = v; changed = true end
    c, v = imgui.slider_float("Reload Speed", cfg.reload_speed, 0.1, 5.0, "%.2f")
    if c then cfg.reload_speed = v; changed = true end

    imgui.spacing()
    c, v = imgui.checkbox("Dev Mode", cfg.dev_mode)
    if c then cfg.dev_mode = v; changed = true end
    if cfg.dev_mode then draw_dev() end

    if changed then save_config() end
    imgui.tree_pop()
end)

re.on_script_reset(function()
    reset_tracked_layers()
end)

re.on_config_save(save_config)
