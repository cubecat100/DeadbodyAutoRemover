-- =========================================================
-- Project: DeadbodyAutoRemover
-- File:    media/lua/server/DeadbodyAutoRemover.lua
--
-- 목표:
--  1) 시체가 생성(스폰)되는 순간, 해당 시체(IsoDeadBody)에 timestamp/uid를 기록한다.
--  2) 청크(10x10) 단위로 시체를 인덱싱(카운트)한다.
--  3) 청크별 시체 수가 임계치를 넘으면, "가장 오래된 시체"부터 자동으로 제거한다.
--
-- 설계 요점:
--  - "가장 오래된 시체"를 정확히 찾으려면 시체별 생성 시각이 필요하므로 modData에 저장한다.
--  - 카운트는 "스폰 이벤트에서 +1"로 빠르게 유지하고,
--    세이브 로드/청크 로드 시점에는 해당 청크만 스캔해서 인덱스를 채운다.
--  - 인덱스 정합성이 완벽하지 않을 수 있으므로(시체 이동/외부 제거 등),
--    제거 실패 시 폭주 방지를 위해 루프를 조기에 중단한다.
-- =========================================================

local DeadbodyAutoRemover = {}

-- =========================================================
-- [설정] 필요하면 여기만 수정
-- =========================================================
DeadbodyAutoRemover.Config = {
    -- 청크당 시체 허용 최대치. 초과하면 자동 정리 시작.
    MAX_CORPSES_PER_CHUNK = 100,

    -- 스폰 이벤트 1회당 최대 제거 수(폭주 방지).
    MAX_REMOVALS_PER_EVENT = 3,

    -- 플레이어 시체도 제거할지 여부.
    REMOVE_PLAYER_CORPSES = false,

    -- timestamp가 없는 시체(세이브 로드 등)는 "아주 오래됨"으로 취급할 기준값.
    -- 0이면 최우선 제거 대상(가장 오래된 것으로 간주).
    BACKFILL_OLD_TIME = 0,

    -- 청크는 10x10 타일 고정(좀보이드 기본).
    CHUNK_SIZE = 10,

    -- 디버그 출력
    DEBUG_ENABLED = true,          -- 전체 디버그 on/off
    DEBUG_HALO_TEXT = true,        -- 싱글(로컬 플레이어 존재)일 때 HaloText도 같이 출력
    DEBUG_PREFIX = "[DeadbodyAutoRemover] ",
}

-- =========================================================
-- [modData 키] 시체 객체에 기록되는 메타데이터 키
-- =========================================================
DeadbodyAutoRemover.ModDataKey = {
    SPAWN_TIME_HOURS = "DAR_CorpseSpawnTimeHours",
    UID = "DAR_CorpseUID",
}

-- =========================================================
-- [내부 상태] 청크 인덱스
--  chunkKey -> {
--      count = number,                         -- 청크 내 시체 수(추정치)
--      list = { {uid,t,x,y,z}, {uid,t,x,y,z} }  -- 시체 레코드(오래된 탐색용)
--  }
-- =========================================================
local chunkIndex = {}

-- uid 충돌 방지용 시퀀스(월드 내에서만 유효)
local uidSeq = 0

-- =========================================================
-- [디버그 출력 유틸]
--  - 기본: print로 서버/로그에 남김
--  - 선택: 싱글(로컬 플레이어 있을 때만) HaloTextHelper로 화면에도 띄움
-- =========================================================
local function dbg_log(msg)
    if DeadbodyAutoRemover.Config.DEBUG_ENABLED == false then
        return
    end
    print(DeadbodyAutoRemover.Config.DEBUG_PREFIX .. tostring(msg))
end

local function dbg_halo(msg, colorFunc)
    if DeadbodyAutoRemover.Config.DEBUG_ENABLED == false then
        return
    end
    if DeadbodyAutoRemover.Config.DEBUG_HALO_TEXT == false then
        return
    end

    -- 전용 서버/멀티 서버에서는 로컬 플레이어가 없을 수 있음.
    if HaloTextHelper == nil then
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
    if colorFunc ~= nil then
        color = colorFunc()
    end
    if color == nil then
        -- 색 함수가 없거나 실패하면 흰색 비슷한 기본값이 없어서 그냥 생략
        HaloTextHelper.addText(player, tostring(msg))
    else
        HaloTextHelper.addText(player, tostring(msg), color)
    end
end

-- =========================================================
-- [시간] 월드 누적 시간(시간 단위) - 비교용으로 사용
-- =========================================================
local function getWorldAgeHours()
    return getGameTime():getWorldAgeHours()
end

-- =========================================================
-- [설정 적용] SandboxVars에서 설정 적용
-- =========================================================
local function applyUserConfigFromSandboxVars()
    local sv = SandboxVars and SandboxVars.DeadbodyAutoRemover

    DeadbodyAutoRemover.Config.MAX_CORPSES_PER_CHUNK = sv.MaxCorpsesPerChunk
    DeadbodyAutoRemover.Config.MAX_REMOVALS_PER_EVENT = sv.MaxRemovalsPerEvent
    DeadbodyAutoRemover.Config.REMOVE_PLAYER_CORPSES = sv.RemovePlayerCorpses
    DeadbodyAutoRemover.Config.DEBUG_ENABLED = sv.DebugEnabled

    dbg_log("Config from SandboxVars applied")
end

-- =========================================================
-- [청크 키 생성]
--  - 청크는 10x10이므로 좌표를 10으로 나눠 floor한 값이 청크 좌표 기록
--  - chunkKey는 "cx:cy" 문자열
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

local function generateUID(nowHours)
    uidSeq = uidSeq + 1
    -- 시간 + 시퀀스 + 랜덤 조합으로 충돌 가능성을 낮춤
    return tostring(nowHours) .. "-" .. tostring(uidSeq) .. "-" .. tostring(ZombRand(1000000))
end

-- =========================================================
-- [스퀘어 안전 획득]
--  - 보통 body:getSquare()가 있지만, 예외 상황 대비로 좌표 직접 조회도 시도
-- =========================================================
local function safeGetSquare(body)
    if body == nil then return nil end

    local sq = body:getSquare()
    if sq == nil then
        local x, y, z = body:getX(), body:getY(), body:getZ()
        if x ~= nil and y ~= nil and z ~= nil then
            sq = getCell():getGridSquare(x, y, z)
        end
    end
    return sq
end

-- =========================================================
-- [제거 대상 제외 조건]
--  - 플레이어 시체 제외 옵션 등
-- =========================================================
local function shouldSkipBody(body)
    if body == nil then return true end

    if DeadbodyAutoRemover.Config.REMOVE_PLAYER_CORPSES == false then
        -- 빌드에 따라 isPlayer()가 있을 수 있음
        if body.isPlayer ~= nil and body:isPlayer() then
            return true
        end

        -- 플레이어가 좀비화된 뒤 죽은 좀비(IsoZombie)
        if body.isReanimatedPlayer ~= nil and body:isReanimatedPlayer() then
            dbg_halo("isReanimatedPlayer: " .. tostring(body), HaloTextHelper.getColorRed)
            return true
        end

        if body.getReanimatedPlayer ~= nil then
            local reanimatedPlayer = body:getReanimatedPlayer()
            if reanimatedPlayer ~= nil then
                dbg_halo("getReanimatedPlayer: " .. tostring(reanimatedPlayer), HaloTextHelper.getColorRed)
                return true
            end
        end
    end

    return false
end

-- =========================================================
-- [시체 1구에 timestamp/uid를 기록]
--  - 시체 생성 이벤트에서 호출
--  - 세이브/청크 로드로 이미 존재하는 시체를 스캔할 때도 "없으면 채움"
-- =========================================================
local function applyTimestampIfMissing(body, nowHours)
    if body == nil then return end

    local md = body:getModData()
    if md == nil then return end

    local timeKey = DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS
    local uidKey  = DeadbodyAutoRemover.ModDataKey.UID

    local t = md[timeKey]
    local uid = md[uidKey]

    if t == nil then
        -- 기존 시체(세이브 로드 등)는 아주 오래된 것으로 백필
        md[timeKey] = DeadbodyAutoRemover.Config.BACKFILL_OLD_TIME
        t = md[timeKey]
        dbg_log("Backfill timestamp (missing) -> " .. tostring(t))
    end

    if uid == nil then
        md[uidKey] = generateUID(nowHours or t or 0)
        uid = md[uidKey]
        dbg_log("Assign UID (missing) -> " .. tostring(uid))
    end

    -- 서버에서 modData 변경 시 멀티 동기화가 필요할 수 있음
    if isServerSide() then
        if body.transmitModData ~= nil then
            body:transmitModData()
        end
    end
end

-- =========================================================
-- [인덱싱] 시체 1구를 청크 버킷에 등록(+1)
--  - 이 시점에 "청크 시체 수 추정치"가 증가한다.
-- =========================================================
local function indexCorpse(body)
    if body == nil then return end
    if shouldSkipBody(body) then return end

    local sq = safeGetSquare(body)
    if sq == nil then return end

    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local chunkKey = makeChunkKeyFromXY(x, y)
    local bucket = ensureChunkBucket(chunkKey)

    local md = body:getModData()
    if md == nil then return end

    local t = md[DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS]
    local uid = md[DeadbodyAutoRemover.ModDataKey.UID]

    -- 안전: 스캔 상황에서 누락될 수 있으니 보정
    if t == nil or uid == nil then
        applyTimestampIfMissing(body, getWorldAgeHours())
        t = md[DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS]
        uid = md[DeadbodyAutoRemover.ModDataKey.UID]
    end

    bucket.count = bucket.count + 1
    bucket.list[#bucket.list + 1] = { uid = uid, t = t, x = x, y = y, z = z }

    -- ===== 디버그: 카운트 확인 =====
    dbg_log("Index +1 | chunk=" .. chunkKey .. " | count=" .. tostring(bucket.count) .. " | uid=" .. tostring(uid) .. " | t=" .. tostring(t))
    dbg_halo("Chunk " .. chunkKey .. " corpse +1 (now " .. tostring(bucket.count) .. ")", HaloTextHelper.getColorGreen)

end

-- =========================================================
-- [제거] record(좌표/uid)를 기반으로 실제 시체를 찾아 제거
--  - true: 제거 성공
--  - false: 찾지 못함 / 스퀘어 없음 / 실패
-- =========================================================
local function removeCorpseByRecord(record)
    if record == nil then return false end

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
                        -- ===== 실제 제거 =====
                        square:transmitRemoveItemFromSquare(corpseObject)
                        corpseObject:removeFromWorld()
                        corpseObject:removeFromSquare()
                        return true
                    end
                end
            end
        end
    end

    return false
end

-- =========================================================
-- [청크에서 가장 오래된 record 제거]
--  - bucket.list에서 timestamp(t)가 가장 작은 레코드를 선택
--  - 제거 성공/실패와 관계없이 인덱스에서는 해당 레코드를 제거해
--    "무한히 같은 레코드만 시도"하는 상황을 방지한다.
-- =========================================================
local function removeOldestFromChunk(chunkKey)
    local bucket = chunkIndex[chunkKey]
    if bucket == nil then return false end
    if bucket.count <= 0 then return false end
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

    -- 인덱스 정합성 유지: 레코드 제거(+카운트 감소)
    table.remove(bucket.list, oldestIndex)
    bucket.count = math.max(0, bucket.count - 1)

    -- ===== 디버그: 제거 확인 =====
    if removed then
        dbg_log("Remove OK | chunk=" .. chunkKey .. " | count=" .. tostring(bucket.count) .. " | uid=" .. tostring(oldestRecord.uid) .. " | t=" .. tostring(oldestRecord.t))
        dbg_halo("Removed oldest corpse (chunk " .. chunkKey .. ")", HaloTextHelper.getColorGreen)
    else
        dbg_log("Remove FAIL | chunk=" .. chunkKey .. " | count=" .. tostring(bucket.count) .. " | uid=" .. tostring(oldestRecord.uid) .. " | t=" .. tostring(oldestRecord.t))
        dbg_halo("Remove failed (chunk " .. chunkKey .. ")", HaloTextHelper.getColorRed)
    end

    return removed
end

-- =========================================================
-- [임계치 초과 시 정리 실행]
--  - bucket.count가 MAX를 초과하면 oldest부터 제거
--  - 제거가 계속 실패하면(언로드/이동/외부 삭제 등) 폭주 방지로 break
-- =========================================================
local function enforceChunkLimit(chunkKey)

    local max = DeadbodyAutoRemover.Config.MAX_CORPSES_PER_CHUNK
    if max == 0 then
        return -- 0이면 무제한: 자동 제거 비활성화
    end

    local bucket = chunkIndex[chunkKey]
    if bucket == nil then return end

    if bucket.count <= DeadbodyAutoRemover.Config.MAX_CORPSES_PER_CHUNK then
        return
    end

    dbg_log("Enforce | chunk=" .. chunkKey .. " | count=" .. tostring(bucket.count) ..
            " > max=" .. tostring(DeadbodyAutoRemover.Config.MAX_CORPSES_PER_CHUNK))

    local removals = 0
    while bucket.count > DeadbodyAutoRemover.Config.MAX_CORPSES_PER_CHUNK
        and removals < DeadbodyAutoRemover.Config.MAX_REMOVALS_PER_EVENT
    do
        local ok = removeOldestFromChunk(chunkKey)
        removals = removals + 1

        -- 제거 실패가 발생하면 정합성이 흔들렸을 가능성이 있으므로
        -- 같은 이벤트에서 과도하게 반복하지 않도록 중단
        if ok == false then
            break
        end
    end

    dbg_log("Enforce Done | chunk=" .. chunkKey .. " | removals=" .. tostring(removals) ..
            " | countNow=" .. tostring(bucket.count))
end

-- =========================================================
-- [이벤트] 시체 스폰 시점
--  - 이때 timestamp/uid를 "확정"으로 찍는다.
--  - 그리고 해당 청크 카운트를 +1 하고, 임계치 초과면 바로 정리한다.
-- =========================================================
local function onDeadBodySpawn(body)
    if body == nil then return end
    if shouldSkipBody(body) then return end

    local now = getWorldAgeHours()

    -- (1) 시체에 timestamp/uid 기록
    local md = body:getModData()
    if md ~= nil then
        if md[DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS] == nil then
            md[DeadbodyAutoRemover.ModDataKey.SPAWN_TIME_HOURS] = now
        end
        if md[DeadbodyAutoRemover.ModDataKey.UID] == nil then
            md[DeadbodyAutoRemover.ModDataKey.UID] = generateUID(now)
        end

        if body.transmitModData ~= nil then
            body:transmitModData()
        end
    end

    -- (2) 인덱싱(+1) 및 디버그 출력
    indexCorpse(body)

    -- (3) 해당 시체가 속한 청크만 임계치 검사/정리
    local sq = safeGetSquare(body)
    if sq ~= nil then
        local chunkKey = makeChunkKeyFromXY(sq:getX(), sq:getY())
        enforceChunkLimit(chunkKey)
    end
end

-- =========================================================
-- [이벤트] 청크 로드 시점
--  - 세이브 로드로 이미 존재하던 시체가 있을 수 있으니
--    로드된 청크(10x10 * z층)를 스캔하여 인덱스를 채운다.
--  - 로드 직후 이미 과포화면 즉시 정리한다.
-- =========================================================
local function onLoadChunk(chunk)
    dbg_log("LoadChunk Scan begin...")
    if chunk == nil then return end

    -- 일부 빌드에서 chunk.wx / chunk.wy가 존재.
    -- 존재하지 않으면 안전하게 스킵(최소 범위 변경 원칙)
    local cwx = chunk.wx
    local cwy = chunk.wy
    if cwx == nil or cwy == nil then
        dbg_log("LoadChunk: chunk.wx/wy not available -> skip scan")
        return
    end

    local baseX = cwx * DeadbodyAutoRemover.Config.CHUNK_SIZE
    local baseY = cwy * DeadbodyAutoRemover.Config.CHUNK_SIZE
    local chunkKey = tostring(cwx) .. ":" .. tostring(cwy)

    -- z 상한: 있으면 chunk.maxLevel, 없으면 8로 가정
    local maxZ = chunk.maxLevel
    if maxZ == nil then maxZ = 8 end

    local scanned = 0

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
                                -- timestamp/uid가 없으면 백필하고 인덱싱
                                applyTimestampIfMissing(body, getWorldAgeHours())
                                indexCorpse(body)
                                scanned = scanned + 1
                            end
                        end
                    end
                end
            end
        end
    end

    dbg_log("LoadChunk Scan Done | chunk=" .. chunkKey .. " | indexed=" .. tostring(scanned))

    -- 로드된 청크가 이미 과포화면 즉시 정리
    enforceChunkLimit(chunkKey)
end

-- =========================================================
-- [이벤트 등록]
-- =========================================================

if Events.OnZombieDead ~= nil then 
    Events.OnZombieDead.Add(onDeadBodySpawn)
end

if Events and Events.OnGameStart then 
    Events.OnGameStart.Add(applyUserConfigFromSandboxVars) 
end

if Events and Events.OnServerStarted then 
    Events.OnServerStarted.Add(applyUserConfigFromSandboxVars) 
end

if Events.LoadChunk ~= nil then
    Events.LoadChunk.Add(onLoadChunk)
    dbg_log("Hooked Events.LoadChunk")
else
    dbg_log("Events.LoadChunk not found")
end

return DeadbodyAutoRemover