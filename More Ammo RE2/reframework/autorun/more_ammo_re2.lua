-- More Ammo RE2
-- REFramework script that multiplies known RE2 ammo grants.

local mod_name = "More Ammo RE2"
local config_path = "more_ammo_re2.json"

local cfg = {
    enabled = true,
    multiplier = 2.0,
    extended_range = false,
    direct_grant_enabled = false,
    dev_mode = false,
}

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
    save_data_patches = 0,
    last_item = "?",
    last_count = 0,
    last_extra = 0,
    last_route = "?",
    last_error = nil,
    hooks = {},
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
        save_arg = 4,
    },
    {
        type_name = "app.ropeway.gamemastering.InventoryManager",
        label = "putStock(stock)",
        names = {
            "putStock(app.ropeway.gamemastering.InventoryManager.StockItem, app.ropeway.gimmick.action.SetItem.SetItemSaveData)",
            "putStock(app.ropeway.gamemastering.InventoryManager.StockItem,app.ropeway.gimmick.action.SetItem.SetItemSaveData)",
            "putStock121827",
            "putStock160371",
        },
        stock_arg = 3,
        save_arg = 4,
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
        save_arg = nil,
    },
}

local suppress_hook = false
local pending_grant = nil
local patched_objects = {}
local patched_order = {}

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

-- Normalise loaded config so old/bad values cannot poison runtime.
local function normalize_config()
    cfg.enabled = cfg.enabled == true
    cfg.extended_range = cfg.extended_range == true
    cfg.dev_mode = cfg.dev_mode == true
    cfg.direct_grant_enabled = false
    cfg.multiplier = clamp_number(cfg.multiplier, 0.0, multiplier_max(), 2.0)
end

-- Load user settings from REFramework data folder.
local function load_config()
    local ok, data = pcall(json.load_file, config_path)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do
            if cfg[k] ~= nil then cfg[k] = v end
        end
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
local function call_any(obj, names)
    if obj == nil then return nil end
    for _, name in ipairs(names or {}) do
        local ok, value = pcall(function() return obj:call(name) end)
        if ok then return value, name end
    end
    return nil, nil
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
        local ok = pcall(function() obj:set_field(name, value) end)
        if ok then return true, name end
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
    local item_id = read_stock_item_id(stock)
    local count = read_stock_count(stock)
    if not is_ammo(item_id) or count <= 0 then return false end
    local new_count = math.max(count, math.ceil(count * clamp_number(cfg.multiplier, 0.0, multiplier_max(), 1.0)))
    state.last_route = tostring(source or "stock")
    state.last_item = item_label(item_id)
    state.last_count = count
    state.last_extra = math.max(0, new_count - count)
    if new_count <= count then return false end

    local default_obj = nil
    local additional_obj = nil
    pcall(function() default_obj = stock:get_field("DefaultItem") end)
    pcall(function() additional_obj = stock:get_field("AdditionalItem") end)
    local primitive_ok = patch_primitive_count(default_obj, item_id, new_count, source) or patch_primitive_count(additional_obj, item_id, new_count, source)

    if primitive_ok then
        state.stock_patches = state.stock_patches + 1
        return true
    end
    return false
end

-- Patch SetItemSaveData count before RE2 converts it into stock.
local function patch_save_data_count(save_data, source)
    if cfg.enabled ~= true or save_data == nil then return false end
    local item_id = field_int(save_data, { "Type", "_Type", "ItemId", "ItemID" })
    local count = field_int(save_data, { "Count", "_Count", "ItemCount" })
    local count_field_names = { "Count", "_Count", "ItemCount" }
    if not is_ammo(item_id) then
        item_id = field_int(save_data, { "AdditionalWeaponId", "AdditionalItemId", "AdditionalItemID" })
        count = field_int(save_data, { "AdditionalItemCount", "AdditionalCount" })
        count_field_names = { "AdditionalItemCount", "AdditionalCount" }
    end
    if not is_ammo(item_id) or count == nil or count <= 0 then return false end
    local new_count = math.max(count, math.ceil(count * clamp_number(cfg.multiplier, 0.0, multiplier_max(), 1.0)))
    if new_count <= count then return false end
    local key = object_key(save_data, "save")
    if patched_objects[key] == true then return false end
    local ok = set_field_any(save_data, count_field_names, new_count)
    if ok then
        remember_patch(key)
        state.save_data_patches = state.save_data_patches + 1
        state.last_route = tostring(source or "save_data")
        state.last_item = item_label(item_id)
        state.last_count = count
        state.last_extra = math.max(0, new_count - count)
    end
    return ok == true
end

-- Calculate extra count to add after native grant.
local function extra_count(base_count)
    local base = math.max(0, math.floor(tonumber(base_count or 0) or 0))
    local mult = clamp_number(cfg.multiplier, 0.0, multiplier_max(), 1.0)
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
        state.stock_route_hits = state.stock_route_hits + 1
        local stock = route.stock_arg ~= nil and managed_object(args[route.stock_arg]) or nil
        local save_data = route.save_arg ~= nil and managed_object(args[route.save_arg]) or nil
        patch_stock_count(stock, route.label)
        patch_save_data_count(save_data, route.label)
        return nil
    end, function(retval)
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
        state.add_hits = state.add_hits + 1
        if suppress_hook then
            state.suppressed_hits = state.suppressed_hits + 1
            pending_grant = nil
            return nil
        end

        pending_grant = nil
        local item_id = scalar_int(args[3])
        local count = scalar_int(args[4])
        state.last_item = item_label(item_id)
        state.last_count = count or 0
        state.last_extra = 0

        if cfg.enabled ~= true or cfg.direct_grant_enabled ~= true or item_id == nil or count == nil or count <= 0 then return nil end
        if not is_ammo(item_id) then return nil end

        local extra = extra_count(count)
        state.ammo_hits = state.ammo_hits + 1
        state.last_extra = extra
        if extra <= 0 then return nil end

        pending_grant = {
            inventory = managed_object(args[2]),
            item_arg = args[3],
            item_id = item_id,
            extra = extra,
            method_name = name,
        }
        return nil
    end, function(retval)
        local grant = pending_grant
        pending_grant = nil
        if grant == nil or grant.inventory == nil or grant.extra <= 0 then return retval end

        suppress_hook = true
        local ok, err = call_extra_grant(grant)
        suppress_hook = false

        if ok then
            state.extra_grants = state.extra_grants + 1
            state.last_error = nil
        else
            state.last_error = tostring(err or "extra grant failed")
        end
        return retval
    end)

    state.hook_installed = true
    state.hook_name = name
    state.install_error = nil
    state.hooks.addItemCount = name
    for _, route in ipairs(stock_route_methods) do
        install_stock_route(route)
    end
    return true
end

-- Draw compact runtime status for normal users.
local function draw_status()
    imgui.text("Hook: " .. tostring(state.hook_installed and state.hook_name or "not installed"))
    if state.install_error ~= nil then imgui.text("Error: " .. tostring(state.install_error)) end
    imgui.text("Last: " .. tostring(state.last_item) .. " +" .. tostring(state.last_count) .. " extra " .. tostring(state.last_extra) .. " via " .. tostring(state.last_route))
end

-- Draw diagnostics only when Dev Mode is enabled.
local function draw_dev()
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
    imgui.text("SaveData patches: " .. tostring(state.save_data_patches))
    for label, hook_name in pairs(state.hooks) do
        imgui.text(tostring(label) .. ": " .. tostring(hook_name))
    end
    if state.last_error ~= nil then imgui.text("Last error: " .. tostring(state.last_error)) end
end

load_config()
re.on_config_save(save_config)

re.on_frame(function()
    if not state.hook_installed then install_hook() end
end)

re.on_draw_ui(function()
    if not imgui.tree_node(mod_name) then return end

    local changed
    changed, cfg.enabled = imgui.checkbox("Enabled", cfg.enabled)
    if changed then save_config() end

    changed, cfg.extended_range = imgui.checkbox("Extended Range", cfg.extended_range)
    if changed then
        cfg.multiplier = clamp_number(cfg.multiplier, 0.0, multiplier_max(), 2.0)
        save_config()
    end

    changed, cfg.multiplier = imgui.slider_float("Ammo Grant Multiplier", cfg.multiplier, 0.0, multiplier_max(), "%.2f")
    if changed then save_config() end

    draw_status()

    changed, cfg.dev_mode = imgui.checkbox("Dev Mode", cfg.dev_mode)
    if changed then save_config() end
    if cfg.dev_mode then draw_dev() end

    imgui.tree_pop()
end)
