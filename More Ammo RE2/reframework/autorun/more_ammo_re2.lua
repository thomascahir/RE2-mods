-- More Ammo RE2
-- REFramework script that multiplies known RE2 ammo grants.

local mod_name = "More Ammo RE2"
local config_path = "more_ammo_re2.json"
local error_path = "more_ammo_re2_error.txt"
local craft_report_path = "more_ammo_re2_craft_report.txt"

local cfg = {
    enabled = true,
    pickup_enabled = true,
    craft_enabled = false,
    multiplier = 2.0,
    pickup_multiplier = 2.0,
    craft_multiplier = 2.0,
    extended_range = false,
    direct_grant_enabled = false,
    dev_mode = false,
}

local min_multiplier = 0.1

local state = {
    hook_installed = false,
    hook_name = "?",
    install_error = nil,
    add_hits = 0,
    ammo_hits = 0,
    extra_grants = 0,
    suppressed_hits = 0,
    stock_route_hits = 0,
    stock_patches = 0,
    pickup_patches = 0,
    craft_patches = 0,
    craft_hook_hits = 0,
    craft_output_hits = 0,
    craft_extra_grants = 0,
    last_item = "?",
    last_count = 0,
    last_extra = 0,
    last_route = "?",
    last_kind = "?",
    last_error = nil,
    hooks = {},
    craft_frames = {},
    craft_events = {},
}

local ammo_items = {
    [15] = "Handgun Ammo",
    [16] = "Shotgun Shells",
    [17] = "Submachine Gun Ammo",
    [18] = "MAG Ammo",
    [22] = "Acid Rounds",
    [23] = "Flame Rounds",
    [24] = "Needle Cartridges",
    [25] = "Fuel",
    [26] = "Large-caliber Handgun Ammo",
    [27] = "High-Powered Rounds",
}

local method_names = {
    "addItemCount(app.ropeway.gamemastering.Item.ID, System.Int32)",
    "addItemCount(app.ropeway.gamemastering.Item.ID,System.Int32)",
    "addItemCount121818",
    "addItemCount160362",
    "addItemCount121840",
    "addItemCount",
}

local stock_method_names = {
    "get_ItemId",
    "get_ItemId5879",
    "get_ItemId76358",
}

local stock_count_names = {
    "get_Count",
    "get_Count5885",
    "get_Count76364",
}

local stock_route_methods = {
    {
        type_name = "app.ropeway.gui.NewInventorySlotBehavior",
        label = "openGetItemMode",
        names = {
            "openGetItemMode(app.ropeway.gamemastering.InventoryManager.StockItem, app.ropeway.gimmick.action.SetItem.SetItemSaveData)",
            "openGetItemMode(app.ropeway.gamemastering.InventoryManager.StockItem,app.ropeway.gimmick.action.SetItem.SetItemSaveData)",
            "openGetItemMode",
            "openGetItemMode95285",
            "openGetItemMode96412",
            "openGetItemMode129471",
            "openGetItemMode130538",
            "openGetItemMode178947",
            "openGetItemMode179339",
        },
        stock_arg = 3,
    },
    {
        type_name = "app.ropeway.gamemastering.InventoryManager",
        label = "enableGetItem",
        names = {
            "enableGetItem(app.ropeway.gamemastering.InventoryManager.StockItem)",
            "enableGetItem",
            "enableGetItem121080",
            "enableGetItem121915",
            "enableGetItem159664",
            "enableGetItem160458",
        },
        stock_arg = 3,
    },
}

local slot_item_id_names = { "get_ItemID", "get_ItemID120327", "get_ItemID158987" }
local slot_count_names = { "get_Number", "get_Number120337", "get_Number158997" }
local slot_index_names = { "get_Index", "get_Index120322", "get_Index158982" }
local slot_set_number_names = { "set_Number", "set_Number120338", "set_Number158998" }
local inventory_slot_names = { "getInventorySlots", "getInventorySlots121848", "getInventorySlots160392" }

local craft_boundary_methods = {
    {
        type_name = "app.ropeway.gui.NewInventorySlotBehavior",
        label = "precombinationItem",
        names = {
            "precombinationItem",
            "precombinationItem(app.ropeway.gamemastering.InventoryManager.StockItem)",
            "precombinationItem(System.Int32,System.Int32)",
            "precombinationItem96504",
            "precombinationItem130630",
            "precombinationItem96528",
            "precombinationItem130654",
        },
    },
    {
        type_name = "app.ropeway.gui.NewInventorySlotBehavior",
        label = "precombinationItemSub",
        names = {
            "precombinationItemSub",
            "precombinationItemSub(app.ropeway.gamemastering.InventoryManager.StockItem)",
            "precombinationItemSub(System.Int32,System.Int32)",
            "precombinationItemSub96505",
            "precombinationItemSub130631",
            "precombinationItemSub96529",
            "precombinationItemSub130655",
        },
    },
    {
        type_name = "app.ropeway.gui.NewInventorySlotBehavior",
        label = "combinationItem",
        names = {
            "combinationItem",
            "combinationItem(System.Int32,System.Int32)",
            "combinationItem96501",
            "combinationItem130627",
            "combinationItem96530",
            "combinationItem130656",
        },
    },
    {
        type_name = "app.ropeway.gui.NewInventorySlotBehavior",
        label = "combinationItemGetItemMode",
        names = {
            "combinationItemGetItemMode()",
            "combinationItemGetItemMode",
            "combinationItemGetItemMode96502",
            "combinationItemGetItemMode130628",
            "combinationItemGetItemMode179050",
        },
    },
}

local suppress_hook = false
local pending_grant = nil
local patched_objects = {}
local patched_order = {}

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

-- Store last error in UI and data file.
local function record_error(stage, err)
    state.last_error = tostring(stage) .. ": " .. tostring(err)
    write_lines(error_path, {
        "More Ammo RE2 script error",
        "stage=" .. tostring(stage),
        "error=" .. tostring(err),
    })
end

-- Clamp number to safe range because UI/config can carry stale values.
local function clamp_number(value, min_value, max_value, fallback)
    local n = tonumber(value)
    if n == nil then n = fallback end
    n = tonumber(n) or 0.0
    if min_value ~= nil and n < min_value then n = min_value end
    if max_value ~= nil and n > max_value then n = max_value end
    return n
end

-- Current max tracks normal or extended slider range.
local function multiplier_max()
    return cfg.extended_range and 100.0 or 10.0
end

-- Round multiplier to one decimal because UI should step by 0.1.
local function quantize_multiplier(value)
    local n = tonumber(value) or 0.0
    return math.floor(n * 10.0 + 0.5) / 10.0
end

-- Clamp and round multiplier for config/UI use.
local function normalize_multiplier(value, fallback)
    return quantize_multiplier(clamp_number(value, min_multiplier, multiplier_max(), fallback))
end

-- Format multiplier compactly for UI/report text.
local function multiplier_text(value)
    return string.format("%.1f", normalize_multiplier(value, 1.0))
end

-- Normalise loaded config so old/bad values cannot poison runtime.
local function normalize_config()
    cfg.enabled = cfg.enabled == true
    cfg.pickup_enabled = cfg.pickup_enabled ~= false
    cfg.craft_enabled = cfg.craft_enabled == true
    cfg.extended_range = cfg.extended_range == true
    cfg.dev_mode = cfg.dev_mode == true
    cfg.direct_grant_enabled = false
    cfg.multiplier = normalize_multiplier(cfg.multiplier, 2.0)
    cfg.pickup_multiplier = normalize_multiplier(cfg.pickup_multiplier, cfg.multiplier)
    cfg.craft_multiplier = normalize_multiplier(cfg.craft_multiplier, cfg.multiplier)
    cfg.multiplier = cfg.pickup_multiplier
end

-- Load user settings from REFramework data folder.
local function load_config()
    local ok, data = pcall(json.load_file, config_path)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do
            if cfg[k] ~= nil then cfg[k] = v end
        end
        if data.pickup_multiplier == nil and data.multiplier ~= nil then cfg.pickup_multiplier = data.multiplier end
        if data.craft_multiplier == nil and data.multiplier ~= nil then cfg.craft_multiplier = data.multiplier end
    end
    normalize_config()
end

-- Save user settings to REFramework data folder.
local function save_config()
    normalize_config()
    pcall(json.dump_file, config_path, cfg)
end

-- Convert hook values/enums to Lua integers.
local function scalar_int(value)
    if value == nil then return nil end
    if type(value) == "number" then return math.floor(value) end
    if type(value) == "boolean" then return value and 1 or 0 end
    local n = tonumber(value)
    if n ~= nil then return math.floor(n) end
    if sdk ~= nil and type(sdk.to_int64) == "function" then
        local ok, out = pcall(sdk.to_int64, value)
        if ok and tonumber(out) ~= nil then return math.floor(tonumber(out)) end
    end
    if type(value) == "userdata" then
        local ok_field, field_value = pcall(function()
            if value.get_field ~= nil then return value:get_field("value__") end
            return nil
        end)
        if ok_field and tonumber(field_value) ~= nil then return math.floor(tonumber(field_value)) end
    end
    return nil
end

-- Return managed object for hook receiver when pointer is valid.
local function managed_object(value)
    if value == nil or sdk == nil or type(sdk.to_managed_object) ~= "function" then return nil end
    local ok, obj = pcall(sdk.to_managed_object, value)
    if ok then return obj end
    return nil
end

-- Return stable object key when REFramework exposes native address.
local function object_key(obj, suffix)
    if obj == nil then return nil end
    local ok, addr = pcall(function()
        if type(obj.get_address) == "function" then return obj:get_address() end
        return nil
    end)
    if ok and addr ~= nil then return tostring(addr) .. ":" .. tostring(suffix or "") end
    return tostring(obj) .. ":" .. tostring(suffix or "")
end

-- Remember patched object keys without unbounded growth.
local function remember_patch(key)
    if key == nil then return false end
    if patched_objects[key] == true then return false end
    patched_objects[key] = true
    patched_order[#patched_order + 1] = key
    while #patched_order > 128 do
        local old = table.remove(patched_order, 1)
        patched_objects[old] = nil
    end
    return true
end

-- Resolve first usable method from known RE2 names.
local function find_method(type_def, names)
    if type_def == nil then return nil, nil end
    for _, name in ipairs(names) do
        local ok, method = pcall(type_def.get_method, type_def, name)
        if ok and method ~= nil then return method, name end
    end
    return nil, nil
end

-- Call first usable getter on managed object.
local function call_any(obj, names, ...)
    if obj == nil then return nil end
    for _, name in ipairs(names or {}) do
        local ok, value = pcall(function(...) return obj:call(name, ...) end, ...)
        if ok then return value, name end
    end
    return nil, nil
end

-- Return array/list length from RE managed collection.
local function array_length(arr)
    if arr == nil then return 0 end
    local ok_size, size = pcall(arr.get_size, arr)
    if ok_size and tonumber(size) ~= nil then return math.max(0, math.floor(tonumber(size))) end
    local value = call_any(arr, { "get_Length", "get_Count" })
    if tonumber(value) ~= nil then return math.max(0, math.floor(tonumber(value))) end
    return 0
end

-- Return array/list element from RE managed collection.
local function array_get(arr, index)
    if arr == nil then return nil end
    local ok_element, element = pcall(arr.get_element, arr, index)
    if ok_element then return element end
    local value = call_any(arr, { "GetValue" }, index)
    return value
end

-- Read int field from managed object using candidate field names.
local function field_int(obj, names)
    if obj == nil then return nil, nil end
    for _, name in ipairs(names or {}) do
        local ok, value = pcall(function() return obj:get_field(name) end)
        if ok then
            local n = scalar_int(value)
            if n ~= nil then return n, name end
        end
    end
    return nil, nil
end

-- Set first usable field on managed object.
local function set_field_any(obj, names, value)
    if obj == nil then return false, nil end
    for _, name in ipairs(names or {}) do
        local checked = false
        local exists = false
        pcall(function()
            if type(obj.get_type_definition) == "function" then
                local type_def = obj:get_type_definition()
                checked = type_def ~= nil
                if checked and type_def:get_field(name) ~= nil then exists = true end
            end
        end)
        if checked and not exists then goto continue end
        local ok = pcall(function() obj:set_field(name, value) end)
        if ok then return true, name end
        ::continue::
    end
    return false, nil
end

-- Return ammo label for UI/log text.
local function item_label(item_id)
    return ammo_items[tonumber(item_id or 0)] or ("Item " .. tostring(item_id or "?"))
end

-- True when item id is known grantable ammo.
local function is_ammo(item_id)
    return ammo_items[tonumber(item_id or 0)] ~= nil
end

-- Return route kind from known RE2 stock entry point.
local function route_kind(source)
    return "pickup"
end

-- Return route multiplier after enabled checks.
local function route_multiplier(kind)
    if kind == "craft" then
        if cfg.craft_enabled ~= true then return nil end
        return clamp_number(cfg.craft_multiplier, min_multiplier, multiplier_max(), 1.0)
    end
    if cfg.pickup_enabled ~= true then return nil end
    return clamp_number(cfg.pickup_multiplier, min_multiplier, multiplier_max(), 1.0)
end

-- Craft hooks observe in Dev Mode even when multiplier is off.
local function craft_observe_enabled()
    return cfg.enabled == true and (cfg.craft_enabled == true or cfg.dev_mode == true)
end

-- Read StockItem item id through native getter names.
local function read_stock_item_id(stock)
    local value = call_any(stock, stock_method_names)
    return scalar_int(value)
end

-- Read StockItem count through native getter names.
local function read_stock_count(stock)
    local value = call_any(stock, stock_count_names)
    local count = scalar_int(value)
    if count == nil or count <= 0 then return 1 end
    return count
end

-- Return InventoryManager singleton for snapshot and extra craft grant.
local function inventory_manager()
    if sdk == nil or type(sdk.get_managed_singleton) ~= "function" then return nil end
    local ok, inv = pcall(sdk.get_managed_singleton, "app.ropeway.gamemastering.InventoryManager")
    if ok then return inv end
    return nil
end

-- Read current inventory ammo/input totals for craft diff.
local function inventory_snapshot(reason)
    local snap = { reason = tostring(reason or "snapshot"), totals = {}, rows = {}, error = nil }
    local inv = inventory_manager()
    local slots = call_any(inv, inventory_slot_names)
    if slots == nil then
        snap.error = "inventory_slots_unavailable"
        return snap
    end
    local count = array_length(slots)
    for i = 0, math.max(0, count - 1) do
        local slot = array_get(slots, i)
        if slot ~= nil then
            local item_id = scalar_int(call_any(slot, slot_item_id_names))
            local number = scalar_int(call_any(slot, slot_count_names)) or 0
            local slot_index = scalar_int(call_any(slot, slot_index_names)) or i
            if item_id ~= nil and item_id > 0 and number > 0 then
                snap.totals[tostring(item_id)] = (tonumber(snap.totals[tostring(item_id)] or 0) or 0) + number
                snap.rows[#snap.rows + 1] = { slot = slot_index, item_id = item_id, count = number, label = item_label(item_id) }
            end
        end
    end
    return snap
end

-- Return matching inventory slot by exposed slot index.
local function inventory_slot_by_index(slot_index)
    local inv = inventory_manager()
    local slots = call_any(inv, inventory_slot_names)
    if slots == nil then return nil end
    local count = array_length(slots)
    for i = 0, math.max(0, count - 1) do
        local slot = array_get(slots, i)
        if slot ~= nil then
            local idx = scalar_int(call_any(slot, slot_index_names)) or i
            if tonumber(idx or -1) == tonumber(slot_index or -2) then return slot end
        end
    end
    return nil
end

-- Set visible inventory slot count directly.
local function set_slot_count(slot_index, count)
    local slot = inventory_slot_by_index(slot_index)
    if slot == nil then return false, "slot_missing" end
    local _result, method_name = call_any(slot, slot_set_number_names, tonumber(count or 0) or 0)
    return method_name ~= nil, tostring(method_name or "slot_set_number_missing")
end

-- Return count for same slot/item in snapshot.
local function snapshot_slot_count(snap, slot_index, item_id)
    for _, row in ipairs((snap and snap.rows) or {}) do
        if tonumber(row.slot or -1) == tonumber(slot_index or -2) and tonumber(row.item_id or -1) == tonumber(item_id or -2) then
            return tonumber(row.count or 0) or 0
        end
    end
    return 0
end

-- Pick slot that received crafted output delta.
local function crafted_output_slot(before, after, item_id)
    local best = nil
    for _, row in ipairs((after and after.rows) or {}) do
        if tonumber(row.item_id or -1) == tonumber(item_id or -2) then
            local before_count = snapshot_slot_count(before, row.slot, item_id)
            local gain = (tonumber(row.count or 0) or 0) - before_count
            if gain > 0 and (best == nil or gain > best.gain) then
                best = { slot = row.slot, after_count = tonumber(row.count or 0) or 0, gain = gain }
            end
        end
    end
    return best
end

-- Return total changes between two inventory snapshots.
local function snapshot_diff(before, after)
    local rows = {}
    local ids = {}
    for k in pairs((before and before.totals) or {}) do ids[k] = true end
    for k in pairs((after and after.totals) or {}) do ids[k] = true end
    for k in pairs(ids) do
        local item_id = tonumber(k) or 0
        local old_count = tonumber(before and before.totals and before.totals[k] or 0) or 0
        local new_count = tonumber(after and after.totals and after.totals[k] or 0) or 0
        local delta = new_count - old_count
        if delta ~= 0 then
            rows[#rows + 1] = { item_id = item_id, before = old_count, after = new_count, delta = delta, label = item_label(item_id) }
        end
    end
    table.sort(rows, function(a, b) return tonumber(a.item_id or 0) < tonumber(b.item_id or 0) end)
    return rows
end

-- Keep bounded craft evidence for reports.
local function push_craft_event(event)
    event = type(event) == "table" and event or { note = tostring(event or "") }
    state.craft_events[#state.craft_events + 1] = event
    while #state.craft_events > 40 do table.remove(state.craft_events, 1) end
end

-- Write craft report for user copy/paste.
local function write_craft_report(reason)
    local lines = {
        "More Ammo RE2 craft report",
        "reason=" .. tostring(reason or "manual"),
        "enabled=" .. tostring(cfg.enabled),
        "pickup_enabled=" .. tostring(cfg.pickup_enabled),
        "pickup_multiplier=" .. multiplier_text(cfg.pickup_multiplier),
        "craft_enabled=" .. tostring(cfg.craft_enabled),
        "craft_multiplier=" .. multiplier_text(cfg.craft_multiplier),
        "craft_hook_hits=" .. tostring(state.craft_hook_hits),
        "craft_output_hits=" .. tostring(state.craft_output_hits),
        "craft_extra_grants=" .. tostring(state.craft_extra_grants),
        "last_error=" .. tostring(state.last_error or "none"),
        "note=" .. (cfg.craft_enabled == true and "craft multiplier active" or "craft multiplier OFF; no extra craft ammo will be granted"),
        "",
        "events:",
    }
    for _, event in ipairs(state.craft_events) do
        lines[#lines + 1] = tostring(event.label or "?") .. " base=" .. tostring(event.base or "?") .. " extra=" .. tostring(event.extra or "?") .. " via=" .. tostring(event.route or "?") .. " diff=" .. tostring(event.diff or "?") .. " slot=" .. tostring(event.slot or "?") .. " final=" .. tostring(event.final or "?")
    end
    write_lines(craft_report_path, lines)
end

-- Set ammo primitive count when StockItem wraps PrimitiveItem data.
local function patch_primitive_count(obj, item_id, new_count, source)
    if obj == nil then return false end
    local wid = field_int(obj, { "WeaponId", "WeaponID", "_WeaponId", "_WeaponID", "Type", "_Type", "ItemId", "ItemID" })
    if wid ~= nil and is_ammo(wid) then item_id = wid end
    if not is_ammo(item_id) then return false end
    local key = object_key(obj, "primitive")
    if patched_objects[key] == true then return false end
    local ok = set_field_any(obj, { "Count", "_Count", "ItemCount" }, new_count)
    if ok then remember_patch(key) end
    return ok == true
end

-- Patch StockItem count before RE2 accepts pickup/craft stock.
local function patch_stock_count(stock, source)
    if cfg.enabled ~= true or stock == nil then return false end
    local kind = route_kind(source)
    local multiplier = route_multiplier(kind)
    if multiplier == nil then return false end
    local item_id = read_stock_item_id(stock)
    local count = read_stock_count(stock)
    if not is_ammo(item_id) or count <= 0 then return false end
    local new_count = math.max(1, math.ceil(count * multiplier))
    state.last_route = tostring(source or "stock")
    state.last_kind = kind
    state.last_item = item_label(item_id)
    state.last_count = count
    state.last_extra = new_count - count
    if new_count == count then return false end

    local default_obj = nil
    local additional_obj = nil
    pcall(function() default_obj = stock:get_field("DefaultItem") end)
    pcall(function() additional_obj = stock:get_field("AdditionalItem") end)
    local primitive_ok = patch_primitive_count(default_obj, item_id, new_count, source) or patch_primitive_count(additional_obj, item_id, new_count, source)

    if primitive_ok then
        state.stock_patches = state.stock_patches + 1
        if kind == "craft" then
            state.craft_patches = state.craft_patches + 1
        else
            state.pickup_patches = state.pickup_patches + 1
        end
        return true
    end
    return false
end

-- Calculate extra count to add after native grant.
local function extra_count(base_count)
    local base = math.max(0, math.floor(tonumber(base_count or 0) or 0))
    local mult = clamp_number(cfg.pickup_multiplier, min_multiplier, multiplier_max(), 1.0)
    return math.max(0, math.ceil(base * mult) - base)
end

-- Call native addItemCount with enum arg first, numeric fallback second.
local function call_extra_grant(grant)
    local ok = pcall(function()
        grant.inventory:call(grant.method_name, grant.item_arg, grant.extra)
    end)
    if ok then return true, nil end
    local ok_numeric, numeric_err = pcall(function()
        grant.inventory:call(grant.method_name, grant.item_id, grant.extra)
    end)
    if ok_numeric then return true, nil end
    return false, numeric_err
end

-- Calculate desired crafted ammo output from native output count.
local function craft_target_count(base_count)
    local base = math.max(0, math.floor(tonumber(base_count or 0) or 0))
    local mult = clamp_number(cfg.craft_multiplier, min_multiplier, multiplier_max(), 1.0)
    return math.max(1, math.ceil(base * mult))
end

-- Apply craft multiplier from post-native inventory diff.
local function apply_craft_diff(frame, after)
    if cfg.enabled ~= true then return false end
    if frame == nil or frame.before == nil or after == nil then return false end
    local diff = snapshot_diff(frame.before, after)
    local has_craft_input = false
    for _, row in ipairs(diff) do
        local id = tonumber(row.item_id or 0) or 0
        if id >= 36 and id <= 39 and tonumber(row.delta or 0) < 0 then
            has_craft_input = true
            break
        end
    end
    local applied = false
    for _, row in ipairs(diff) do
        local item_id = tonumber(row.item_id or 0) or 0
        local base = tonumber(row.delta or 0) or 0
        if has_craft_input == true and is_ammo(item_id) and base > 0 then
            local desired = craft_target_count(base)
            local adjustment = desired - base
            state.craft_output_hits = state.craft_output_hits + 1
            state.last_route = tostring(frame.route or "craft")
            state.last_kind = "craft"
            state.last_item = item_label(item_id)
            state.last_count = base
            state.last_extra = adjustment
            if cfg.craft_enabled ~= true then
                push_craft_event({ route = frame.route, item_id = item_id, label = item_label(item_id), base = base, extra = 0, diff = "craft_disabled" })
                return false
            end
            if adjustment ~= 0 then
                local target = crafted_output_slot(frame.before, after, item_id)
                local ok, err = false, "crafted_output_slot_missing"
                if target ~= nil then
                    ok, err = set_slot_count(target.slot, target.after_count + adjustment)
                end
                if ok then
                    state.craft_patches = state.craft_patches + 1
                    state.craft_extra_grants = state.craft_extra_grants + 1
                    applied = true
                    push_craft_event({ route = frame.route, item_id = item_id, label = item_label(item_id), base = base, extra = adjustment, diff = "slot_set", slot = target and target.slot, final = target and (target.after_count + adjustment) })
                else
                    record_error("craft_slot_set", err)
                    push_craft_event({ route = frame.route, item_id = item_id, label = item_label(item_id), base = base, extra = adjustment, diff = "slot_set_failed" })
                end
            end
        end
    end
    if applied then write_craft_report("craft_apply") end
    return applied
end

-- Install one stock route hook.
local function install_stock_route(route)
    local type_def = sdk.find_type_definition(route.type_name)
    if type_def == nil then
        state.hooks[route.label] = "type missing"
        return false
    end
    local method, name = find_method(type_def, route.names)
    if method == nil then
        state.hooks[route.label] = "method missing"
        return false
    end
    sdk.hook(method, function(args)
        local ok, err = pcall(function()
            state.stock_route_hits = state.stock_route_hits + 1
            local stock = route.stock_arg ~= nil and managed_object(args[route.stock_arg]) or nil
            patch_stock_count(stock, route.label)
        end)
        if not ok then record_error("stock_route:" .. tostring(route.label), err) end
        return nil
    end, function(retval)
        return retval
    end)
    state.hooks[route.label] = name
    return true
end

-- Install one craft boundary hook.
local function install_craft_route(route)
    local type_def = sdk.find_type_definition(route.type_name)
    if type_def == nil then
        state.hooks[route.label] = "type missing"
        return false
    end
    local method, name = find_method(type_def, route.names)
    if method == nil then
        state.hooks[route.label] = "method missing"
        return false
    end
    sdk.hook(method, function(args)
        local ok, err = pcall(function()
            if craft_observe_enabled() ~= true then return end
            state.craft_hook_hits = state.craft_hook_hits + 1
            state.craft_frames[#state.craft_frames + 1] = { route = route.label, before = inventory_snapshot(route.label .. "_pre") }
        end)
        if not ok then record_error("craft_pre:" .. tostring(route.label), err) end
        return nil
    end, function(retval)
        local ok, err = pcall(function()
            if craft_observe_enabled() ~= true then return end
            local frame = table.remove(state.craft_frames)
            if frame == nil then return end
            if #state.craft_frames > 0 then return end
            apply_craft_diff(frame, inventory_snapshot(tostring(frame.route or route.label) .. "_post"))
        end)
        if not ok then record_error("craft_post:" .. tostring(route.label), err) end
        return retval
    end)
    state.hooks[route.label] = name
    return true
end

-- Install addItemCount hook because this is RE2 direct ammo grant path.
local function install_hook()
    if state.hook_installed then return true end
    local type_def = sdk.find_type_definition("app.ropeway.gamemastering.InventoryManager")
    if type_def == nil then
        state.install_error = "InventoryManager type missing"
        return false
    end
    local method, name = find_method(type_def, method_names)
    if method == nil then
        state.install_error = "addItemCount method missing"
        return false
    end

    sdk.hook(method, function(args)
        local ok, err = pcall(function()
            state.add_hits = state.add_hits + 1
            if suppress_hook then
                state.suppressed_hits = state.suppressed_hits + 1
                pending_grant = nil
                return
            end

            pending_grant = nil
            local item_id = scalar_int(args[3])
            local count = scalar_int(args[4])
            state.last_item = item_label(item_id)
            state.last_count = count or 0
            state.last_extra = 0

            if cfg.enabled ~= true or cfg.direct_grant_enabled ~= true or item_id == nil or count == nil or count <= 0 then return end
            if not is_ammo(item_id) then return end

            local extra = extra_count(count)
            state.ammo_hits = state.ammo_hits + 1
            state.last_extra = extra
            if extra <= 0 then return end

            pending_grant = {
                inventory = managed_object(args[2]),
                item_arg = args[3],
                item_id = item_id,
                extra = extra,
                method_name = name,
            }
        end)
        if not ok then record_error("addItemCount_pre", err) end
        return nil
    end, function(retval)
        local ok, err = pcall(function()
            local grant = pending_grant
            pending_grant = nil
            if grant == nil or grant.inventory == nil or grant.extra <= 0 then return end

            suppress_hook = true
            local grant_ok, grant_err = call_extra_grant(grant)
            suppress_hook = false

            if grant_ok then
                state.extra_grants = state.extra_grants + 1
                state.last_error = nil
            else
                record_error("addItemCount_post_grant", grant_err)
            end
        end)
        suppress_hook = false
        if not ok then record_error("addItemCount_post", err) end
        return retval
    end)

    state.hook_installed = true
    state.hook_name = name
    state.install_error = nil
    state.hooks.addItemCount = name
    for _, route in ipairs(stock_route_methods) do
        install_stock_route(route)
    end
    for _, route in ipairs(craft_boundary_methods) do
        install_craft_route(route)
    end
    return true
end

-- Draw diagnostics only when Dev Mode is enabled.
local function draw_dev()
    imgui.text("Hook: " .. tostring(state.hook_installed and state.hook_name or "not installed"))
    if state.install_error ~= nil then imgui.text("Error: " .. tostring(state.install_error)) end
    imgui.text("Last: " .. tostring(state.last_item) .. " +" .. tostring(state.last_count) .. " extra " .. tostring(state.last_extra) .. " via " .. tostring(state.last_route) .. " kind=" .. tostring(state.last_kind))
    if imgui.button("Retry Hook Install") then install_hook() end
    imgui.same_line()
    if imgui.button("Save Config") then save_config() end
    local changed
    imgui.text("Direct addItemCount Mutator: disabled")
    imgui.text("addItemCount hits: " .. tostring(state.add_hits))
    imgui.text("Ammo hits: " .. tostring(state.ammo_hits))
    imgui.text("Extra grants: " .. tostring(state.extra_grants))
    imgui.text("Suppressed hits: " .. tostring(state.suppressed_hits))
    imgui.text("Stock route hits: " .. tostring(state.stock_route_hits))
    imgui.text("Stock patches: " .. tostring(state.stock_patches))
    imgui.text("Pickup patches: " .. tostring(state.pickup_patches))
    imgui.text("Craft patches: " .. tostring(state.craft_patches))
    imgui.text("Craft hook hits: " .. tostring(state.craft_hook_hits))
    imgui.text("Craft output hits: " .. tostring(state.craft_output_hits))
    imgui.text("Craft extra grants: " .. tostring(state.craft_extra_grants))
    if imgui.button("Write Craft Report") then write_craft_report("manual") end
    imgui.same_line()
    imgui.text(craft_report_path)
    for label, hook_name in pairs(state.hooks) do
        imgui.text(tostring(label) .. ": " .. tostring(hook_name))
    end
    if state.last_error ~= nil then
        imgui.text("Last error: " .. tostring(state.last_error))
        imgui.text("Error file: " .. error_path)
    end
end

load_config()
re.on_config_save(save_config)

re.on_frame(function()
    local ok, err = pcall(function()
        if not state.hook_installed then install_hook() end
    end)
    if not ok then record_error("on_frame", err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node(mod_name) then return end

    local changed
    changed, cfg.enabled = imgui.checkbox("Enabled", cfg.enabled)
    if changed then save_config() end

    changed, cfg.extended_range = imgui.checkbox("Extended Range", cfg.extended_range)
    if changed then
        cfg.pickup_multiplier = normalize_multiplier(cfg.pickup_multiplier, 2.0)
        cfg.craft_multiplier = normalize_multiplier(cfg.craft_multiplier, 2.0)
        save_config()
    end

    changed, cfg.pickup_enabled = imgui.checkbox("Multiply Pickups", cfg.pickup_enabled)
    if changed then save_config() end

    changed, cfg.pickup_multiplier = imgui.slider_float("Pickup Multiplier", cfg.pickup_multiplier, min_multiplier, multiplier_max(), "%.1f")
    if changed then
        cfg.pickup_multiplier = normalize_multiplier(cfg.pickup_multiplier, 2.0)
        save_config()
    end

    changed, cfg.craft_enabled = imgui.checkbox("Multiply Crafting", cfg.craft_enabled)
    if changed then save_config() end

    changed, cfg.craft_multiplier = imgui.slider_float("Craft Multiplier", cfg.craft_multiplier, min_multiplier, multiplier_max(), "%.1f")
    if changed then
        cfg.craft_multiplier = normalize_multiplier(cfg.craft_multiplier, 2.0)
        save_config()
    end

    changed, cfg.dev_mode = imgui.checkbox("Dev Mode", cfg.dev_mode)
    if changed then save_config() end
    if cfg.dev_mode then draw_dev() end

    imgui.tree_pop()
end)
