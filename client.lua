local protectedProps = {
    "prop_traffic_01a","prop_traffic_01b","prop_traffic_01c","prop_traffic_01d",
    "prop_traffic_02a","prop_traffic_02b","prop_traffic_03a","prop_traffic_03b","prop_traffic_03c",
    "prop_streetlight_01","prop_streetlight_01b","prop_streetlight_02","prop_streetlight_03","prop_streetlight_03b",
    "prop_streetlight_03c","prop_streetlight_03d","prop_streetlight_04","prop_streetlight_05","prop_streetlight_05_b",
    "prop_streetlight_06","prop_streetlight_07a","prop_streetlight_07b","prop_streetlight_08","prop_streetlight_09",
    "prop_streetlight_14a","prop_streetlight_m","prop_streetlight_rural",
    "prop_sign_road_01a","prop_sign_road_01b","prop_sign_road_03d","prop_sign_road_03e","prop_sign_road_04a",
    "prop_sign_road_04g","prop_sign_road_04u",
    "prop_sign_road_02a","prop_sign_road_02b","prop_sign_road_02c","prop_sign_road_02d","prop_sign_road_02e",
    "prop_sign_road_02f","prop_sign_road_02g","prop_sign_road_02h","prop_sign_road_03a","prop_sign_road_03b",
    "prop_sign_road_03c","prop_sign_road_03f","prop_sign_road_03g","prop_sign_road_03h","prop_sign_road_03i",
    "prop_sign_road_03m","prop_sign_road_04b","prop_sign_road_04c","prop_sign_road_04d","prop_sign_road_04e",
    "prop_sign_road_04f","prop_sign_road_04h","prop_sign_road_04i","prop_sign_road_04j","prop_sign_road_04k",
    "prop_sign_road_04l","prop_sign_road_04m","prop_sign_road_04n","prop_sign_road_04o","prop_sign_road_04p",
    "prop_sign_road_04q","prop_sign_road_04r","prop_sign_road_04s","prop_sign_road_04t","prop_sign_road_04v",
    "prop_sign_road_04w","prop_sign_road_05f","prop_sign_road_05a", "prop_sign_road_07a", "prop_sign_road_03o", "prop_sign_road_05d", "prop_sign_road_05za", "prop_elecbox_05a"
}

-- Build a fast lookup set of model hashes
local modelHashSet = {}
for i = 1, #protectedProps do
    modelHashSet[GetHashKey(protectedProps[i])] = true
end

-- Track what we've already protected (weak keys so handles can GC)
local protectedHandles = setmetatable({}, { __mode = 'k' })

-- Decorator to persist protection flag even if weak table entry is GC'd
local DECOR_KEY = 'qb_unbreakable'
if DecorRegister then
    pcall(DecorRegister, DECOR_KEY, 2) -- type 2 = bool
end

local function isProtectedModel(model)
    return modelHashSet[model] == true
end

local function alreadyMarked(ent)
    if protectedHandles[ent] then return true end
    if DecorExistOn and DecorExistOn(ent, DECOR_KEY) then
        return DecorGetBool and DecorGetBool(ent, DECOR_KEY) or false
    end
    return false
end

local function markProtected(ent)
    protectedHandles[ent] = true
    if DecorSetBool then
        pcall(DecorSetBool, ent, DECOR_KEY, true)
    end
end

local function protectEntity(ent)
    if not ent or ent == 0 then return end
    if not DoesEntityExist(ent) or not IsEntityAnObject(ent) then return end
    if alreadyMarked(ent) then return end

    local model = GetEntityModel(ent)
    if not isProtectedModel(model) then return end

    -- Physics + damage proofing (cheap calls; one-off per entity)
    FreezeEntityPosition(ent, true)
    SetEntityDynamic(ent, false)
    SetEntityHasGravity(ent, false)
    SetEntityCollision(ent, true, true)
    SetEntityInvincible(ent, true)
    SetEntityCanBeDamaged(ent, false)
    SetEntityProofs(ent, true, true, true, true, true, true, true, true)

    markProtected(ent)
end

-- Protect on creation (covers newly streamed/created objects fast)
AddEventHandler('entityCreated', function(handle)
    local ent = handle
    CreateThread(function()
        Wait(0) -- ensure fully valid
        if DoesEntityExist(ent) then
            protectEntity(ent)
        end
    end)
end)

-- Incremental streamed-pool scan with distance filter and adaptive interval
local poolIndex = 1
CreateThread(function()
    Wait(1000)
    local interval = 250 -- ms between passes (adaptive)
    local idleStreak = 0
    local maxInterval = 1000
    local minInterval = 100
    while true do
        local startTime = GetGameTimer()
        local p = PlayerPedId()
        local px, py, pz = table.unpack(GetEntityCoords(p))
        local radius = 120.0 -- scan radius around player
        local r2 = radius * radius

        local objects = GetGamePool('CObject')
        local processed = 0
        local protectedThisPass = 0
        local budget = 300 -- per pass budget (not per frame)
        local total = #objects

        if total > 0 then
            while processed < budget do
                if poolIndex > total then
                    poolIndex = 1
                    break
                end
                local obj = objects[poolIndex]
                if obj and DoesEntityExist(obj) and IsEntityAnObject(obj) and not alreadyMarked(obj) then
                    -- distance filter first to avoid unnecessary model/flags
                    local ox, oy, oz = table.unpack(GetEntityCoords(obj))
                    local dx, dy, dz = ox - px, oy - py, oz - pz
                    if (dx*dx + dy*dy + dz*dz) <= r2 then
                        local model = GetEntityModel(obj)
                        if modelHashSet[model] then
                            protectEntity(obj)
                            protectedThisPass = protectedThisPass + 1
                        end
                    end
                end
                poolIndex = poolIndex + 1
                processed = processed + 1
                -- Yield periodically inside large passes to avoid spikes
                if processed % 120 == 0 then
                    Wait(0)
                end
            end
        end

        -- Adaptive interval: slow down when area is stable
        if protectedThisPass == 0 then
            idleStreak = math.min(idleStreak + 1, 10)
        else
            idleStreak = 0
        end
        interval = math.min(maxInterval, math.max(minInterval, 250 + idleStreak * 100))

        -- Sleep remaining time in interval; ensure at least a small yield
        local elapsed = GetGameTimer() - startTime
        local sleep = math.max(0, interval - elapsed)
        if sleep <= 0 then sleep = 0 end
        Wait(sleep)
    end
end)

-- Guard: if something still receives damage, immediately re-protect
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end
    local victim = args and args[1]
    if victim and DoesEntityExist(victim) and IsEntityAnObject(victim) then
        local model = GetEntityModel(victim)
        if modelHashSet[model] then
            protectEntity(victim)
            if ClearEntityLastDamageEntity then
                ClearEntityLastDamageEntity(victim)
            end
        end
    end
end)