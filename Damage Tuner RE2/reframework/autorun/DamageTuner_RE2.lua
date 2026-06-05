-- Damage Tuner RE2
-- Production path: tag hit region, then multiply actual HP addDamage.

local SETTINGS_PATH = "DamageTuner_RE2.json"
local LEGACY_SETTINGS_PATH = "EnemyHitzoneTuner_RE2.json"
local HIT_LOG_PATH = "DamageTuner_RE2_hit_log.txt"
local POLL_REPORT_PATH = "DamageTuner_RE2_poll_report.txt"
local HOOK_ERROR_PATH = "DamageTuner_RE2_hook_error.txt"

local MIN_MULT = 0.1
local MAX_MULT = 10.0
local MAX_LOG = 200

local enabled = true
local dev_mode = false
local show_hit_log = false
local trace_all_hits = false
local max_feed = 50
local hit_feed = {}
local hit_log_dirty = false

local regions = {
    Head = { damage = 1.0, stagger = 1.0 },
    Torso = { damage = 1.0, stagger = 1.0 },
    Arm = { damage = 1.0, stagger = 1.0 },
    Leg = { damage = 1.0, stagger = 1.0 },
}
local region_order = { "Head", "Torso", "Arm", "Leg" }

local pending_damage_region = nil
local pending_damage_raw = nil
local last_error = "none"
local last_damage_text = "?"
local tag_state = { installed = false, hits = 0, last = "?" }
local hp_state = { installed = false, hits = 0, applies = 0, last = "?" }
local em_wince_state = { installed = false, hits = 0, positives = 0, applies = 0, last = "?" }
local last_tag_region = nil
local last_tag_raw = nil

local REGION_BY_KEY = {
    ["0|0"] = "Head",
    ["2|0"] = "Torso",
    ["3|1"] = "Arm",
    ["3|2"] = "Arm",
    ["4|1"] = "Arm",
    ["4|2"] = "Arm",
    ["5|1"] = "Arm",
    ["5|2"] = "Arm",
    ["6|1"] = "Arm",
    ["6|2"] = "Arm",
    ["7|1"] = "Leg",
    ["7|2"] = "Leg",
    ["8|1"] = "Leg",
    ["8|2"] = "Leg",
}

-- Return whether verbose hit tracing should run this frame.
local function should_trace_all_hits()
    return dev_mode and trace_all_hits
end

-- Clamp multiplier to safe UI range.
local function clamp_mult(value)
    local n = tonumber(value)
    if n == nil then return 1.0 end
    if n < MIN_MULT then return MIN_MULT end
    if n > MAX_MULT then return MAX_MULT end
    return n
end

-- Load user settings from REFramework data folder.
local function load_settings()
    local ok, data = pcall(json.load_file, SETTINGS_PATH)
    if not ok or type(data) ~= "table" then
        ok, data = pcall(json.load_file, LEGACY_SETTINGS_PATH)
    end
    if not ok or type(data) ~= "table" then return end
    enabled = data.enabled ~= false
    trace_all_hits = data.trace_all_hits == true
    max_feed = tonumber(data.max_feed) or max_feed
    if type(data.regions) == "table" then
        for name, region in pairs(regions) do
            local saved = data.regions[name]
            if type(saved) == "table" then
                region.damage = clamp_mult(saved.damage)
                region.stagger = clamp_mult(saved.stagger)
            end
        end
    end
end

-- Save user settings to REFramework data folder.
local function save_settings()
    local data = { enabled = enabled, trace_all_hits = trace_all_hits, max_feed = max_feed, regions = {} }
    for name, region in pairs(regions) do
        data.regions[name] = { damage = region.damage, stagger = region.stagger }
    end
    pcall(json.dump_file, SETTINGS_PATH, data)
end

-- Write text file for copy/paste diagnostics.
local function write_lines(path, lines)
    pcall(function()
        local file = io.open(path, "w")
        if file then
            file:write(table.concat(lines, "\n"))
            file:close()
        end
    end)
end

-- Record hook error in UI and file.
local function record_error(stage, err)
    last_error = tostring(stage) .. ": " .. tostring(err)
    write_lines(HOOK_ERROR_PATH, {
        "Damage Tuner RE2 hook error",
        "stage=" .. tostring(stage),
        "error=" .. tostring(err),
    })
end

-- Read a managed field or return nil.
local function read_field(obj, field_name)
    if obj == nil or field_name == nil then return nil end
    local value = nil
    pcall(function() value = obj:get_field(field_name) end)
    return value
end

-- Call a managed getter or return nil.
local function call_getter(obj, method_name)
    if obj == nil or method_name == nil then return nil end
    local value = nil
    pcall(function() value = obj:call(method_name) end)
    return value
end

-- Read raw enemy damage part key from EnemyDamageUserData.
local function read_enemy_part_key(user_data)
    if user_data == nil then return "?" end
    local parts = read_field(user_data, "Parts")
    local side = read_field(user_data, "PartsSide")
    return tostring(parts) .. "|" .. tostring(side)
end

-- Push one hit row to memory and text file.
local function add_hit(region, damage, final_damage, source, raw)
    table.insert(hit_feed, 1, {
        part = region or "?",
        damage = damage or 0,
        final = final_damage or damage or 0,
        source = source or "?",
        raw = raw or "?",
    })
    while #hit_feed > math.min(max_feed, MAX_LOG) do table.remove(hit_feed) end

    hit_log_dirty = true
end

-- Build hit log lines for manual file export.
local function build_hit_log_lines()
    local lines = { "Damage Tuner RE2 hit log" }
    for _, hit in ipairs(hit_feed) do
        lines[#lines + 1] = string.format(
            "part=%s dmg=%s final=%s src=%s",
            tostring(hit.part),
            tostring(hit.damage),
            tostring(hit.final),
            tostring(hit.source) .. " raw=" .. tostring(hit.raw)
        )
    end
    return lines
end

-- Flush hit log only on explicit export paths.
local function flush_hit_log()
    if not hit_log_dirty then return end
    write_lines(HIT_LOG_PATH, build_hit_log_lines())
    hit_log_dirty = false
end

-- Write compact runtime status for copy/paste.
local function write_poll_report()
    flush_hit_log()
    write_lines(POLL_REPORT_PATH, {
        "Damage Tuner RE2 poll report",
        "enabled=" .. tostring(enabled),
        "trace_all_hits=" .. tostring(trace_all_hits),
        "trace_active=" .. tostring(should_trace_all_hits()),
        "tag_hook=setDamageCalcInfo installed=" .. tostring(tag_state.installed) .. " hits=" .. tostring(tag_state.hits) .. " last=" .. tostring(tag_state.last),
        "hp_hook=HitPointController.addDamage installed=" .. tostring(hp_state.installed) .. " hits=" .. tostring(hp_state.hits) .. " applies=" .. tostring(hp_state.applies) .. " last=" .. tostring(hp_state.last),
        "em_wince=EmDamageInfo.setDamageInfo installed=" .. tostring(em_wince_state.installed) .. " hits=" .. tostring(em_wince_state.hits) .. " positives=" .. tostring(em_wince_state.positives) .. " applies=" .. tostring(em_wince_state.applies) .. " last=" .. tostring(em_wince_state.last),
        "last_damage=" .. tostring(last_damage_text),
        "last_error=" .. tostring(last_error),
    })
end

-- Read integer damage argument from addDamage.
local function read_damage_arg(value)
    local out = nil
    if sdk ~= nil and type(sdk.to_int64) == "function" then
        pcall(function() out = sdk.to_int64(value) end)
    end
    return tonumber(out)
end

-- Convert integer damage value back to hook arg pointer.
local function damage_to_ptr(value)
    if value == nil or sdk == nil or type(sdk.to_ptr) ~= "function" then return nil end
    local ok, ptr = pcall(sdk.to_ptr, value)
    if ok then return ptr end
    return nil
end

-- Set managed number through setter first, then backing field fallback.
local function set_managed_number(obj, setter_name, field_name, value)
    if obj == nil or value == nil then return false end
    local ok = pcall(function() obj:call(setter_name, value) end)
    if ok then return true end
    ok = pcall(function() obj:set_field(field_name, value) end)
    return ok == true
end

-- Capture hitzone region before HP damage is applied.
local function install_region_tag_hook()
    local td = sdk.find_type_definition("app.Collision.HitController")
    if td == nil then return end
    local method = td:get_method("setDamageCalcInfo")
    if method == nil then return end

    local ok = pcall(function()
        sdk.hook(method, function(args)
            local hook_ok, hook_err = pcall(function()
                local hit_info = sdk.to_managed_object(args[3])
                local user_data = nil
                pcall(function() user_data = hit_info and hit_info:call("get_EnemyDamageUserData") end)
                local raw = read_enemy_part_key(user_data)
                local region = REGION_BY_KEY[raw]
                pending_damage_region = region
                pending_damage_raw = raw
                last_tag_region = region
                last_tag_raw = raw
                tag_state.hits = tag_state.hits + 1
                tag_state.last = "raw=" .. tostring(raw) .. " region=" .. tostring(region or "?")
            end)
            if not hook_ok then record_error("setDamageCalcInfo", hook_err) end
            return nil
        end, function(retval)
            return retval
        end)
    end)
    tag_state.installed = ok == true
end

-- Multiply final enemy reaction wince where real positive stagger values appear.
local function install_em_wince_hook()
    local td = sdk.find_type_definition("app.ropeway.EmDamageInfo")
    if td == nil then return end
    local method = td:get_method("setDamageInfo")
    if method == nil then return end

    local active_info = nil
    local ok = pcall(function()
        sdk.hook(method, function(args)
            active_info = sdk.to_managed_object(args[2])
            return nil
        end, function(retval)
            local hook_ok, hook_err = pcall(function()
                local info = active_info
                active_info = nil
                if info == nil then return end
                local damage = tonumber(call_getter(info, "get_Damage"))
                local wince = tonumber(call_getter(info, "get_Wince"))
                local parts = call_getter(info, "get_Parts")
                local category = call_getter(info, "get_PartsCategory")
                local side = call_getter(info, "get_PartsSide")
                local raw = tostring(parts) .. "|" .. tostring(category) .. "|" .. tostring(side)
                em_wince_state.hits = em_wince_state.hits + 1
                local region = last_tag_region
                local tag_raw = last_tag_raw
                em_wince_state.last = "em=" .. raw .. " dmg=" .. tostring(damage) .. " wince=" .. tostring(wince) .. " tag=" .. tostring(tag_raw or "?")

                if wince ~= nil and wince > 0 then em_wince_state.positives = em_wince_state.positives + 1 end
                if should_trace_all_hits() and wince ~= nil then
                    add_hit(region or "?", wince, wince, "em_wince_seen", tag_raw or raw)
                end
                if not enabled or wince == nil or wince <= 0 or region == nil then return end
                local tuning = regions[region]
                if tuning == nil or tuning.stagger == 1.0 then return end

                local final_wince = math.floor((wince * tuning.stagger) + 0.5)
                local changed = set_managed_number(info, "set_Wince", "<Wince>k__BackingField", final_wince)
                if not changed then return end

                em_wince_state.applies = em_wince_state.applies + 1
                em_wince_state.last = em_wince_state.last .. " -> " .. tostring(final_wince)
                add_hit(region, wince, final_wince, "em_wince_apply", tag_raw or raw)
            end)
            if not hook_ok then record_error("EmDamageInfo.setDamageInfo", hook_err) end
            return retval
        end)
    end)
    em_wince_state.installed = ok == true
end

-- Multiply actual HP damage after region has been tagged.
local function install_hp_damage_hook()
    local td = sdk.find_type_definition("app.ropeway.HitPointController")
    if td == nil then return end
    local method = td:get_method("addDamage")
    if method == nil then return end

    local ok = pcall(function()
        sdk.hook(method, function(args)
            local hook_ok, hook_err = pcall(function()
                local damage = read_damage_arg(args[3])
                local region = pending_damage_region
                local raw = pending_damage_raw
                pending_damage_region = nil
                pending_damage_raw = nil
                hp_state.hits = hp_state.hits + 1
                hp_state.last = "raw=" .. tostring(raw or "?") .. " region=" .. tostring(region or "?") .. " damage=" .. tostring(damage)

                if should_trace_all_hits() and damage ~= nil and raw ~= nil then
                    add_hit(region or "?", damage, damage, "hp_addDamage_seen", raw)
                end
                if not enabled or damage == nil or region == nil then return end
                local tuning = regions[region]
                if tuning == nil or tuning.damage == 1.0 then return end

                local final_damage = math.floor((damage * tuning.damage) + 0.5)
                local ptr = damage_to_ptr(final_damage)
                if ptr == nil then return end

                args[3] = ptr
                hp_state.applies = hp_state.applies + 1
                hp_state.last = hp_state.last .. " -> " .. tostring(final_damage)
                last_damage_text = tostring(region) .. " " .. tostring(damage) .. " -> " .. tostring(final_damage)
                add_hit(region, damage, final_damage, "hp_addDamage_apply", raw)
            end)
            if not hook_ok then record_error("HitPointController.addDamage", hook_err) end
            return nil
        end, function(retval)
            return retval
        end)
    end)
    hp_state.installed = ok == true
end

-- Draw one multiplier slider and save edits.
local function mult_slider(label, value, apply)
    local changed, new_value = imgui.slider_float(label, value, MIN_MULT, MAX_MULT, "%.1fx")
    if changed then
        new_value = clamp_mult(math.floor(new_value * 10 + 0.5) / 10)
        apply(new_value)
        save_settings()
        return new_value
    end
    return value
end

-- Draw floating hit log window.
local function draw_hit_log()
    if not show_hit_log then return end
    imgui.set_next_window_pos(10, 300, 4)
    imgui.set_next_window_size(560, 260, 4)

    local open = imgui.begin_window("Damage Tuner - Hit Log", true, 0)
    if #hit_feed == 0 then
        imgui.text("Waiting for hits...")
    elseif imgui.begin_table("DamageTunerRE2HitLog", 4, 0x1 + 0x4 + 0x40 + 0x80 + 0x100 + 0x400 + 0x200000) then
        imgui.table_setup_column("Part", 0x10, 70)
        imgui.table_setup_column("Dmg", 0x10, 80)
        imgui.table_setup_column("Final", 0x10, 80)
        imgui.table_setup_column("Src", 0x10, 160)
        imgui.table_headers_row()
        for _, hit in ipairs(hit_feed) do
            imgui.table_next_row()
            imgui.table_next_column()
            imgui.text(tostring(hit.part))
            imgui.table_next_column()
            imgui.text(tostring(hit.damage))
            imgui.table_next_column()
            imgui.text(tostring(hit.final))
            imgui.table_next_column()
            imgui.text(tostring(hit.source))
        end
        imgui.end_table()
    end
    imgui.end_window()
    if not open then show_hit_log = false end
end

-- Draw main REFramework UI.
local function draw_main_ui()
    if not imgui.tree_node("Damage Tuner") then return end

    local changed = false
    changed, enabled = imgui.checkbox("Enabled", enabled)
    if changed then save_settings() end
    imgui.text("Last Damage: " .. tostring(last_damage_text))

    for _, name in ipairs(region_order) do
        if imgui.tree_node(name) then
            regions[name].damage = mult_slider(name .. " Damage", regions[name].damage, function(value) regions[name].damage = value end)
            regions[name].stagger = mult_slider(name .. " Stagger", regions[name].stagger, function(value) regions[name].stagger = value end)
            imgui.tree_pop()
        end
    end

    imgui.separator()
    local dev_changed = false
    dev_changed, dev_mode = imgui.checkbox("Dev Mode", dev_mode)
    if dev_mode then
        if imgui.button(show_hit_log and "Hide Hit Log" or "Show Hit Log") then show_hit_log = not show_hit_log end
        imgui.same_line()
        if imgui.button("Clear Hit Log") then
            hit_feed = {}
            add_hit(nil, nil, nil, "cleared")
            hit_feed = {}
            hit_log_dirty = true
            last_damage_text = "?"
            flush_hit_log()
            write_poll_report()
        end

        local max_changed, max_value = imgui.slider_int("Max Log Entries", max_feed, 5, MAX_LOG)
        if max_changed then
            max_feed = max_value
            save_settings()
        end

        local trace_changed = false
        trace_changed, trace_all_hits = imgui.checkbox("Trace All Hits", trace_all_hits)
        if trace_changed then save_settings() end
        imgui.text("Tag Hook: " .. tostring(tag_state.installed) .. " hits=" .. tostring(tag_state.hits))
        imgui.text("Tag Last: " .. tostring(tag_state.last))
        imgui.text("HP Hook: " .. tostring(hp_state.installed) .. " hits=" .. tostring(hp_state.hits) .. " applies=" .. tostring(hp_state.applies))
        imgui.text("HP Last: " .. tostring(hp_state.last))
        imgui.text("Em Wince Hook: " .. tostring(em_wince_state.installed) .. " hits=" .. tostring(em_wince_state.hits) .. " positives=" .. tostring(em_wince_state.positives) .. " applies=" .. tostring(em_wince_state.applies))
        imgui.text("Em Wince Last: " .. tostring(em_wince_state.last))
        imgui.text("Last Error: " .. tostring(last_error))
        if imgui.button("Write Logs") then write_poll_report() end
        imgui.text("Hit Log File: " .. HIT_LOG_PATH)
        imgui.text("Poll Report: " .. POLL_REPORT_PATH)
        imgui.text("Hook Error: " .. HOOK_ERROR_PATH)
    end

    imgui.tree_pop()
end

load_settings()
install_region_tag_hook()
install_hp_damage_hook()
install_em_wince_hook()
write_poll_report()

re.on_frame(draw_hit_log)
re.on_draw_ui(draw_main_ui)
