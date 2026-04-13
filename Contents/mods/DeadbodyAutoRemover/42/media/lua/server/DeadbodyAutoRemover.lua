-- =========================================================
-- Project: DeadbodyAutoRemover
-- File:    media/lua/server/DeadbodyAutoRemover.lua
--
-- 목표:
--  1) 시체가 생성(스폰)되는 순간, 해당 시체(IsoDeadBody)에 timestamp/uid를 기록한다.
--  2) 청크(10x10) 단위로 시체를 인덱싱(카운트)한다.
--  3) 청크별 시체 수가 임계치를 넘으면, "가장 오래된 시체"부터 자동으로 제거한다.
--
-- 현재 버전 특징:
--  - HaloText 유지 (안전 호출)
--  - 플레이어 시체 유지 기능 유지
--  - LoadChunk 스캔 포함
--  - 청크 재로드 시 중복 카운트 방지
-- =========================================================

local DeadbodyAutoRemover = {}

-- =========================================================
-- [설정]
-- =========================================================
DeadbodyAutoRemover.Config = {
    MAX_CORPSES_PER_CHUNK = 100,
    MAX_REMOVALS_PER_EVENT = 3,
    REMOVE_PLAYER_CORPSES = false,

    -- timestamp가 없는 기존 시체는 "아주 오래됨"으로 취급
    BACKFILL_OLD_TIME = 0,

    CHUNK_SIZE = 8,

    DEBUG_ENABLED = true,
    DEBUG_HALO_TEXT = true,
    DEBUG_PREFIX = "[DeadbodyAutoRemover] ",
}

-- =========================================================
-- [modData 키]
-- =========================================================
DeadbodyAutoRemover.ModDataKey = {
    SPAWN_TIME_HOURS = "DAR_CorpseSpawnTimeHours",
    UID = "DAR_CorpseUID",
}

-- =========================================================
-- [내부 상태]
-- =========================================================
local chunkIndex = {}
local uidSeq = 0

-- =========================================================
-- [디버그 출력]
-- =========================================================
local function dbg_log(msg)
    if DeadbodyAutoRemover.Config.DEBUG_ENABLED == false then
        return
    end
    print(DeadbodyAutoRemover.Config.DEBUG_PREFIX .. tostring(msg))
end

local function dbg_halo(msg, colorName)
    if DeadbodyAutoRemover.Config.DEBUG_ENABLED == false then
        return
    end
    if DeadbodyAutoRemover.Config.DEBUG_HALO_TEXT == false then
        return
    end

    if HaloTextHelper == nil or HaloTextHelper.addText == nil then
        return
    end

    local player = nil
    if getPlayer ~= nil then
        player = getPlayer()
    end
    if player == nil and getSpecificPlayer ~= nil then
        player = getSpecificPlayer(0)
    end
    if player == nil then
        return
    end

    local color = nil
    if colorName == "green" then
        if HaloTextHelper.getColorGreen ~= nil then
            color = HaloTextHelper.getColorGreen()
        end
    elseif colorName == "red" then
        if HaloTextHelper.getColorRed ~= nil then
            color = HaloTextHelper.getColorRed()
        end
    elseif colorName == "yellow" then
        if HaloTextHelper.getColorYellow ~= nil then
            color = HaloTextHelper.getColorYellow()
        end
    end

    if color ~= nil then
        HaloTextHelper.addText(player, tostring(msg), color)
    else
        HaloTextHelper.addText(player, tostring(msg))
    end
end

-- =========================================================
-- [시간]
-- =========================================================
local function getWorldAgeHours()
    return getGameTime():getWorldAgeHours()
end

-- =========================================================
-- [설정 적용]
-- =========================================================
local function applyUserConfigFromSandboxVars()
    local sv = SandboxVars and SandboxVars.DeadbodyAutoRemover
    if sv == nil then
        dbg_log("SandboxVars.DeadbodyAutoRemover not ready -> keep defaults")
        return
    end

    if sv.MaxCorpsesPerChunk ~= nil then
        DeadbodyAutoRemover.Config.MAX_CORPSES_PER_CHUNK = sv.MaxCorpsesPerChunk
    end
    if sv.MaxRemovalsPerEvent ~= nil then
        DeadbodyAutoRemover.Config.MAX_REMOVALS_PER_EVENT = sv.MaxRemovalsPerEvent
    end
    if sv.RemovePlayerCorpses ~= nil then
        DeadbodyAutoRemover.Config.REMOVE_PLAYER_CORPSES = sv.RemovePlayerCorpses
    end
    if sv.DebugEnabled ~= nil then
        DeadbodyAutoRemover.Config.DEBUG_ENABLED = sv.DebugEnabled
    end

    dbg_log("Config from SandboxVars applied")
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(applyUserConfigFromSandboxVars)
end

if Events and Events.OnServerStarted then
    Events.OnServerStarted.Add(applyUserConfigFromSandboxVars)
end

-- =========================================================
-- [청크 키 생성]
-- =========================================================
local function makeChunkKeyFromXY(x, y)
    local cx = math.floor(x / DeadbodyAutoRemover.Config.CHUNK_SIZE)
    local cy = math.floor(y / DeadbodyAutoRemover.Config.CHUNK_SIZE)
    return tostring(cx) .. ":" .. tostring(cy), cx, cy
end

local function ensureChunkBucket(chunkKey)
    local bucket = chunkIndex[chunkKey]
    if bucket == nil then
        bucket = { list = {}, count = 0 }
        chunkIndex[chunkKey] = bucket
    end
    return bucket
end

local function resetChunkBucket(chunkKey)
    chunkIndex[chunkKey] = { list = {}, count = 0 }
    return chunkIndex[chunkKey]
end

local function generateUID(nowHours)
    uidSeq = uidSeq + 1
    return tostring(nowHours) .. "-" .. tostring(uidSeq) .. "-" .. tostring(ZombRand(1000000))
end

-- =========================================================
-- [스퀘어 안전 획득]
-- =========================================================
local function safeGetSquare(body)
    if body == nil then
        return nil
    end

    local sq = nil
    if body.getSquare ~= nil then
        sq = body:getSquare()
    end

    if sq == nil and body.getX ~= nil and body.getY ~= nil and body.getZ ~= nil then
        local x, y, z = body:getX(), body:getY(), body:getZ()
        if x ~= nil and y ~= nil and z ~= nil and getCell ~= nil then
            sq = getCell():getGridSquare(x, y, z)
        end
    end

    return sq
end

-- =========================================================
-- [제거 대상 제외 조건]
-- =========================================================
local function shouldSkipBody(body)
    if body == nil then
        return true
    end

    if DeadbodyAutoRemover.Config.REMOVE_PLAYER_CORPSES == false then
        if body.isPlayer ~= nil and body:isPlayer() then
            dbg_log("Skip player corpse")
            dbg_halo("Skip player corpse")
            return true
        end

        if body.isReanimatedPlayer ~= nil and body:isReanimatedPlayer() then
            dbg_log("Skip reanimated player corpse (isReanimatedPlayer)")
            dbg_halo("isReanimatedPlayer: " .. tostring(body))
            return true
        end

        if body.getReanimatedPlayer ~= nil then
            local reanimatedPlayer = body:getReanimatedPlayer()
            if reanimatedPlayer ~= nil then
                dbg_log("Skip reanimated player corpse (getReanimatedPlayer)")
                dbg_halo("getReanimatedPlayer: " .. tostring(reanimatedPlayer))
                return true
            end
        end
    end

    return false
end

-- =========================================================
-- [시체 1구에 timestamp/uid 기록]
--  - 기존 시체 스캔 시 missing 값 백필
-- =========================================================
local function applyTimestampIfMissing(body, nowHours, missingTimeValue)
    if body == nil then
        return
    end

    local md = body:getModData()
    if md == nil then
        return
    end

    local timeKey = DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS
    local uidKey = DeadbodyAutoRemover.ModDataKey.UID

    local t = md[timeKey]
    local uid = md[uidKey]

    if t == nil then
        local fillTime = missingTimeValue
        if fillTime == nil then
            fillTime = DeadbodyAutoRemover.Config.BACKFILL_OLD_TIME
        end
        md[timeKey] = fillTime
        t = md[timeKey]
        dbg_log("Backfill timestamp (missing) -> " .. tostring(t))
    end

    if uid == nil then
        md[uidKey] = generateUID(nowHours or t or 0)
        uid = md[uidKey]
        dbg_log("Assign UID (missing) -> " .. tostring(uid))
    end

    if body.transmitModData ~= nil then
        body:transmitModData()
    end
end

-- =========================================================
-- [인덱싱]
-- =========================================================
local function indexCorpse(body)
    if body == nil then
        return
    end
    if shouldSkipBody(body) then
        return
    end

    local sq = safeGetSquare(body)
    if sq == nil then
        dbg_log("Index skipped: square missing")
        return
    end

    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local chunkKey = makeChunkKeyFromXY(x, y)
    local bucket = ensureChunkBucket(chunkKey)

    local md = body:getModData()
    if md == nil then
        dbg_log("Index skipped: modData missing")
        return
    end

    local t = md[DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS]
    local uid = md[DeadbodyAutoRemover.ModDataKey.UID]

    if t == nil or uid == nil then
        applyTimestampIfMissing(body, getWorldAgeHours(), DeadbodyAutoRemover.Config.BACKFILL_OLD_TIME)
        t = md[DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS]
        uid = md[DeadbodyAutoRemover.ModDataKey.UID]
    end

    if uid == nil then
        dbg_log("Index skipped: uid still missing")
        return
    end

    for i = 1, #bucket.list do
        local r = bucket.list[i]
        if r ~= nil and r.uid == uid then
            dbg_log("Index skipped: duplicate uid -> " .. tostring(uid))
            return
        end
    end

    bucket.count = bucket.count + 1
    bucket.list[#bucket.list + 1] = {
        uid = uid,
        t = t,
        x = x,
        y = y,
        z = z
    }

    dbg_log("Index +1 | chunk=" .. chunkKey ..
            " | count=" .. tostring(bucket.count) ..
            " | uid=" .. tostring(uid) ..
            " | t=" .. tostring(t))
    dbg_halo("Chunk " .. chunkKey .. " corpse +1 (now " .. tostring(bucket.count) .. ")")
end

-- =========================================================
-- [제거]
-- =========================================================
local function removeCorpseByRecord(record)
    if record == nil then
        return false
    end

    local square = getCell():getGridSquare(record.x, record.y, record.z)
    if square == nil then
        return false
    end

    local corpses = square:getDeadBodys()
    if corpses == nil then
        return false
    end

    for i = 0, corpses:size() - 1 do
        local corpseObject = corpses:get(i)
        if corpseObject ~= nil then
            if shouldSkipBody(corpseObject) == false then
                local md = corpseObject:getModData()
                if md ~= nil then
                    local uid = md[DeadbodyAutoRemover.ModDataKey.UID]
                    if uid ~= nil and uid == record.uid then
                        if square.transmitRemoveItemFromSquareOnServer ~= nil then
                            square:transmitRemoveItemFromSquareOnServer(corpseObject)
                        elseif square.transmitRemoveItemFromSquare ~= nil then
                            square:transmitRemoveItemFromSquare(corpseObject)
                        end

                        corpseObject:removeFromWorld()
                        corpseObject:removeFromSquare()
                        return true
                    end
                end
            end
        end
    end

    dbg_log("Remove FAIL: uid not found on square | uid=" .. tostring(record.uid) ..
            " | xyz=(" .. tostring(record.x) .. "," .. tostring(record.y) .. "," .. tostring(record.z) .. ")")
    return false
end

-- =========================================================
-- [청크에서 가장 오래된 record 제거]
-- =========================================================
local function removeOldestFromChunk(chunkKey)
    local bucket = chunkIndex[chunkKey]
    if bucket == nil then
        return false
    end
    if bucket.count <= 0 then
        return false
    end
    if #bucket.list == 0 then
        bucket.count = 0
        return false
    end

    local oldestIndex = nil
    local oldestTime = nil

    for i = 1, #bucket.list do
        local r = bucket.list[i]
        if r ~= nil then
            if oldestTime == nil or r.t < oldestTime then
                oldestTime = r.t
                oldestIndex = i
            end
        end
    end

    if oldestIndex == nil then
        bucket.count = 0
        bucket.list = {}
        return false
    end

    local oldestRecord = bucket.list[oldestIndex]
    local removed = removeCorpseByRecord(oldestRecord)

    table.remove(bucket.list, oldestIndex)
    bucket.count = math.max(0, bucket.count - 1)

    if removed then
        local max = DeadbodyAutoRemover.Config.MAX_CORPSES_PER_CHUNK
        dbg_log("Remove OK | chunk=" .. chunkKey ..
                " | count=" .. tostring(bucket.count) ..
                " | uid=" .. tostring(oldestRecord.uid) ..
                " | t=" .. tostring(oldestRecord.t))
        dbg_halo("Removed oldest corpse (chunk " .. chunkKey .. ")" .. ", max=" .. tostring(max))
    else
        dbg_log("Remove FAIL | chunk=" .. chunkKey ..
                " | count=" .. tostring(bucket.count) ..
                " | uid=" .. tostring(oldestRecord.uid) ..
                " | t=" .. tostring(oldestRecord.t))
        dbg_halo("Remove failed (chunk " .. chunkKey .. ")")
    end

    return removed
end

-- =========================================================
-- [임계치 초과 시 정리 실행]
-- =========================================================
local function enforceChunkLimit(chunkKey)

    local max = DeadbodyAutoRemover.Config.MAX_CORPSES_PER_CHUNK

    if max == 0 then
        return
    end

    local bucket = chunkIndex[chunkKey]
    if bucket == nil then   
        return
    end

    if bucket.count <= max then
        return
    end

    dbg_log("Enforce | chunk=" .. chunkKey .. " | count=" .. tostring(bucket.count) .. " > max=" .. tostring(max))

    local removals = 0
    while bucket.count > max
        and removals < DeadbodyAutoRemover.Config.MAX_REMOVALS_PER_EVENT
    do
        local ok = removeOldestFromChunk(chunkKey)
        removals = removals + 1

        if ok == false then
            break
        end
    end

    dbg_log("Enforce Done | chunk=" .. chunkKey ..
            " | removals=" .. tostring(removals) ..
            " | countNow=" .. tostring(bucket.count))
end

-- =========================================================
-- [이벤트] 시체 스폰 시점
-- =========================================================
local function onDeadBodySpawn(body)
    if body == nil then
        return
    end
    if shouldSkipBody(body) then
        return
    end

    local now = getWorldAgeHours()
    local md = body:getModData()
    if md == nil then
        dbg_log("Spawn skipped: modData missing")
        return
    end

    if md[DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS] == nil then
        md[DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS] = now
    end

    if md[DeadbodyAutoRemover.ModDataKey.UID] == nil then
        md[DeadbodyAutoRemover.ModDataKey.UID] = generateUID(now)
    end

    if body.transmitModData ~= nil then
        body:transmitModData()
    end

    indexCorpse(body)

    local sq = safeGetSquare(body)
    if sq ~= nil then
        local chunkKey = makeChunkKeyFromXY(sq:getX(), sq:getY())
        enforceChunkLimit(chunkKey)
    end
end

-- =========================================================
-- [이벤트] 청크 로드 시점
--  - 기존 시체를 다시 스캔/인덱싱
--  - 같은 청크 재로드 시 중복 카운트 방지를 위해 bucket 초기화 후 재스캔
-- =========================================================
local function onLoadChunk(chunk)
    if chunk == nil then
        return
    end

    local maxZ = chunk.maxLevel
    if maxZ == nil and chunk.getMaxLevel ~= nil then
        maxZ = chunk:getMaxLevel()
    end
    if maxZ == nil then
        maxZ = 8
    end

    -- 1) 먼저 chunk 안에서 실제 square 하나를 찾아 앵커로 사용
    local anchorSquare = nil

    for z = 0, maxZ do
        for dx = 0, DeadbodyAutoRemover.Config.CHUNK_SIZE - 1 do
            for dy = 0, DeadbodyAutoRemover.Config.CHUNK_SIZE - 1 do
                local sq = nil
                if chunk.getGridSquare ~= nil then
                    sq = chunk:getGridSquare(dx, dy, z)
                end

                if sq ~= nil then
                    anchorSquare = sq
                    break
                end
            end
            if anchorSquare ~= nil then
                break
            end
        end
        if anchorSquare ~= nil then
            break
        end
    end

    if anchorSquare == nil then
        dbg_log("LoadChunk: anchorSquare nil -> skip scan")
        return
    end

    -- 2) 앵커의 월드 좌표에서 청크 시작점 계산
    local baseX = math.floor(anchorSquare:getX() / DeadbodyAutoRemover.Config.CHUNK_SIZE) * DeadbodyAutoRemover.Config.CHUNK_SIZE
    local baseY = math.floor(anchorSquare:getY() / DeadbodyAutoRemover.Config.CHUNK_SIZE) * DeadbodyAutoRemover.Config.CHUNK_SIZE
    local chunkKey = makeChunkKeyFromXY(baseX, baseY)

    -- 기존 bucket 초기화
    resetChunkBucket(chunkKey)

    local bodiesSeen = 0
    local now = getWorldAgeHours()

    -- 3) 이후는 월드 좌표 기준으로 10x10 전체 스캔
    for z = 0, maxZ do
        for dx = 0, DeadbodyAutoRemover.Config.CHUNK_SIZE - 1 do
            for dy = 0, DeadbodyAutoRemover.Config.CHUNK_SIZE - 1 do
                local square = getCell():getGridSquare(baseX + dx, baseY + dy, z)
                if square ~= nil then
                    local corpses = square:getDeadBodys()
                    if corpses ~= nil and corpses:size() > 0 then

                        for i = 0, corpses:size() - 1 do
                            local body = corpses:get(i)
                            if body ~= nil then
                                bodiesSeen = bodiesSeen + 1

                                applyTimestampIfMissing(body, now, DeadbodyAutoRemover.Config.BACKFILL_OLD_TIME)

                                indexCorpse(body)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 인덱싱된 시체가 있으면 
    if bodiesSeen > 0 then  
        dbg_log("LoadChunk Scan Done | chunk=" .. tostring(chunkKey) ..
                " | bodiesSeen=" .. tostring(bodiesSeen) ..
                " | finalCount=" .. tostring(chunkIndex[chunkKey].count))

        enforceChunkLimit(chunkKey)
    end
end

-- =========================================================
-- [이벤트 등록]
-- =========================================================
if Events ~= nil and Events.OnZombieDead ~= nil then
    Events.OnZombieDead.Add(onDeadBodySpawn)
    dbg_log("Hooked Events.OnZombieDead")
else
    dbg_log("Events.OnZombieDead not found")
end

if Events ~= nil and Events.LoadChunk ~= nil then
    Events.LoadChunk.Add(onLoadChunk)
    dbg_log("Hooked Events.LoadChunk")
else
    dbg_log("Events.LoadChunk not found")
end

return DeadbodyAutoRemover