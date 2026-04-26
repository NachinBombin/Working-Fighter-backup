AddCSLuaFile()

if SERVER then

    util.AddNetworkString("P51Backup_FlareSpawned")
    util.AddNetworkString("P51Backup_ManualSpawn")

    -- ============================================================
    -- ConVars
    -- ============================================================

    local SHARED_FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)

    local cv_enabled  = CreateConVar("npc_p51backup_enabled",  "1",    SHARED_FLAGS, "Enable/disable P-51 Backup calls")
    local cv_chance   = CreateConVar("npc_p51backup_chance",   "0.12", SHARED_FLAGS, "Probability per check")
    local cv_interval = CreateConVar("npc_p51backup_interval", "12",   SHARED_FLAGS, "Seconds between NPC checks")
    local cv_cooldown = CreateConVar("npc_p51backup_cooldown", "50",   SHARED_FLAGS, "Cooldown per NPC (seconds)")
    local cv_max_dist = CreateConVar("npc_p51backup_max_dist", "3000", SHARED_FLAGS, "Max call distance (HU)")
    local cv_min_dist = CreateConVar("npc_p51backup_min_dist", "400",  SHARED_FLAGS, "Min call distance (HU)")
    local cv_delay    = CreateConVar("npc_p51backup_delay",    "5",    SHARED_FLAGS, "Flare to arrival delay (s)")
    local cv_height   = CreateConVar("npc_p51backup_height",   "2500", SHARED_FLAGS, "Spawn altitude above ground (HU)")
    local cv_announce = CreateConVar("npc_p51backup_announce", "0",    SHARED_FLAGS, "Debug prints")

    -- ============================================================
    -- NPC callers  (Combine-side — they call in the P-51)
    -- ============================================================

    local P51_CALLERS = {
        ["npc_combine_s"]     = true,
        ["npc_metropolice"]   = true,
        ["npc_combine_elite"] = true,
    }

    -- ============================================================
    -- LVS TEAM SETUP
    --   Team 1 = Combine / P-51  (friendly to each other)
    --   Team 2 = Players + Rebels (targets for the P-51)
    -- AIGetTarget skips team-0 entities, so everyone who should
    -- be a target MUST have a non-zero team assigned.
    -- ============================================================

    local P51_ENEMY_NPCS = {
        -- rebels / resistance
        ["npc_citizen"]          = true,
        ["npc_rebel"]            = true,
        ["npc_alyx"]             = true,
        ["npc_barney"]           = true,
        -- antlions / headcrabs are independent; leave at 0 unless desired
    }

    local P51_FRIENDLY_NPCS = {
        ["npc_combine_s"]     = true,
        ["npc_metropolice"]   = true,
        ["npc_combine_elite"] = true,
        ["npc_hunter"]        = true,
        ["npc_strider"]       = true,
        ["npc_helicopter"]    = true,
        ["npc_combinegunship"]= true,
    }

    local function P51_RegisterNPCTeams()
        if not LVS then return end
        for class, _ in pairs( P51_ENEMY_NPCS ) do
            LVS:SetNPCRelationship( class, 2 )
        end
        for class, _ in pairs( P51_FRIENDLY_NPCS ) do
            LVS:SetNPCRelationship( class, 1 )
        end
    end

    -- Register on a short delay to make sure LVS is fully loaded
    timer.Simple( 1, P51_RegisterNPCTeams )

    -- Also register whenever a map re-initialises
    hook.Add( "InitPostEntity", "P51Backup_RegisterTeams", function()
        timer.Simple( 1, P51_RegisterNPCTeams )
    end )

    -- Players are the primary target: assign them to team 2 so
    -- AIGetTarget sees them as enemies of the team-1 plane.
    local function P51_SetPlayerTeam( ply )
        if not IsValid( ply ) then return end
        -- lvsSetAITeam is the setter used by the LVS toolgun internals
        if ply.lvsSetAITeam then
            ply:lvsSetAITeam( 2 )
        end
    end

    hook.Add( "PlayerInitialSpawn", "P51Backup_PlayerTeam", P51_SetPlayerTeam )
    hook.Add( "PlayerSpawn",        "P51Backup_PlayerTeamRespawn", P51_SetPlayerTeam )

    hook.Add( "PlayerDisconnected", "P51Backup_PlayerTeamClean", function( ply )
        if not IsValid( ply ) then return end
        if ply.lvsSetAITeam then ply:lvsSetAITeam( 0 ) end
    end )

    -- Also apply to any already-connected players (late load)
    timer.Simple( 2, function()
        for _, ply in ipairs( player.GetHumans() ) do
            P51_SetPlayerTeam( ply )
        end
    end )

    -- ============================================================
    -- HELPERS
    -- ============================================================

    local function P51_Debug(msg)
        if not cv_announce:GetBool() then return end
        local full = "[P51 Backup] " .. tostring(msg)
        print(full)
        for _, ply in ipairs(player.GetHumans()) do
            if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, full) end
        end
    end

    local function P51_CheckSkyAbove(pos)
        local tr = util.TraceLine({
            start  = pos + Vector(0, 0, 50),
            endpos = pos + Vector(0, 0, 1050),
        })
        if tr.Hit and not tr.HitSky then
            tr = util.TraceLine({
                start  = tr.HitPos + Vector(0, 0, 50),
                endpos = tr.HitPos + Vector(0, 0, 1000),
            })
        end
        return not (tr.Hit and not tr.HitSky)
    end

    local function P51_ThrowFlare(npc, targetPos)
        local npcEyePos = npc:EyePos()
        local toTarget  = (targetPos - npcEyePos):GetNormalized()

        local flare = ents.Create("ent_bombin_flare_blue")
        if not IsValid(flare) then
            P51_Debug("Flare spawn failed")
            return nil
        end

        flare:SetPos(npcEyePos + toTarget * 52)
        flare:SetAngles(npc:GetAngles())
        flare:Spawn()
        flare:Activate()

        local dir  = targetPos - flare:GetPos()
        local dist = dir:Length()
        dir:Normalize()

        timer.Simple(0, function()
            if not IsValid(flare) then return end
            local phys = flare:GetPhysicsObject()
            if not IsValid(phys) then return end
            phys:SetVelocity(dir * 700 + Vector(0, 0, dist * 0.25))
            phys:Wake()
        end)

        net.Start("P51Backup_FlareSpawned")
        net.WriteEntity(flare)
        net.Broadcast()

        P51_Debug("Flare thrown")
        return flare
    end

    local function P51_FindGround(centerPos)
        local startPos   = Vector(centerPos.x, centerPos.y, centerPos.z + 64)
        local endPos     = Vector(centerPos.x, centerPos.y, centerPos.z - 8192)
        local filterList = {}
        local maxIter    = 0

        while maxIter < 100 do
            local tr = util.TraceLine({ start = startPos, endpos = endPos, filter = filterList })
            if tr.HitWorld then
                if tr.HitPos.z < startPos.z and tr.HitPos.z > (centerPos.z - 8192) then
                    return tr.HitPos.z
                else
                    break
                end
            end
            if IsValid(tr.Entity) then
                table.insert(filterList, tr.Entity)
            else
                break
            end
            maxIter = maxIter + 1
        end

        return -1
    end

    local function P51_SpawnAtPos(centerPos, callDir)
        local ground = P51_FindGround(centerPos)
        if ground == -1 then
            ground = centerPos.z
            P51_Debug("FindGround failed — using caller Z as ground")
        end

        ground = math.max(ground, centerPos.z - 256)

        local heightAdd = cv_height:GetFloat()
        local skyAlt    = ground + heightAdd

        local spawnPos = centerPos - callDir * 2000
        spawnPos = Vector(spawnPos.x, spawnPos.y, skyAlt)

        if not util.IsInWorld(spawnPos) then
            spawnPos = Vector(centerPos.x, centerPos.y, skyAlt)
        end
        if not util.IsInWorld(spawnPos) then
            spawnPos = centerPos + Vector(0, 0, heightAdd)
            P51_Debug("Spawn fallback to caller + height: " .. tostring(spawnPos))
        end

        local ent = ents.Create("lvs_plane_p51v2")
        if not IsValid(ent) then
            P51_Debug("ents.Create returned invalid entity for lvs_plane_p51v2")
            return false
        end

        ent:SetPos(spawnPos)

        local ang = callDir:Angle()
        ent:SetAngles(Angle(0, ang.y + 70, 0))

        ent:Spawn()
        ent:Activate()

        if not IsValid(ent) then
            P51_Debug("Entity invalid after Spawn()")
            return false
        end

        -- Team 1 = Combine-allied. Players are team 2, rebels are team 2.
        -- AIGetTarget will now find and pursue them automatically.
        ent:SetAITEAM( 1 )

        -- Enable the built-in LVS AI (same as using the toolgun)
        ent:SetAI( true )

        P51_Debug("P-51 spawned at " .. tostring(spawnPos))
        return true
    end

    local function P51_FireMunition(npc, target)
        if not IsValid(npc) then P51_Debug("NPC invalid") return false end
        if not IsValid(target) or not target:IsPlayer() or not target:Alive() then
            P51_Debug("Target invalid") return false
        end

        local targetPos = target:GetPos() + Vector(0, 0, 36)
        if not P51_CheckSkyAbove(targetPos) then
            P51_Debug("No open sky above target") return false
        end

        local callDir = targetPos - npc:GetPos()
        callDir.z = 0
        if callDir:LengthSqr() <= 1 then callDir = npc:GetForward() callDir.z = 0 end
        if callDir:LengthSqr() <= 1 then callDir = Vector(1, 0, 0) end
        callDir:Normalize()

        local flare = P51_ThrowFlare(npc, targetPos)
        if not IsValid(flare) then P51_Debug("Flare failed") return false end

        local fallbackPos = Vector(targetPos.x, targetPos.y, targetPos.z)
        local storedDir   = Vector(callDir.x, callDir.y, callDir.z)

        timer.Simple(cv_delay:GetFloat(), function()
            local centerPos = IsValid(flare) and flare:GetPos() or fallbackPos
            P51_SpawnAtPos(centerPos, storedDir)
        end)

        return true
    end

    -- ============================================================
    -- MANUAL SPAWN (button in menu / console command)
    -- ============================================================

    net.Receive("P51Backup_ManualSpawn", function(len, ply)
        if not IsValid(ply) then return end

        local tr = util.TraceLine({
            start  = ply:EyePos(),
            endpos = ply:EyePos() + ply:EyeAngles():Forward() * 3000,
            filter = ply,
        })

        local centerPos = tr.Hit and tr.HitPos or (ply:GetPos() + Vector(0, 0, 100))

        local callDir = ply:EyeAngles():Forward()
        callDir.z = 0
        if callDir:LengthSqr() <= 1 then callDir = Vector(1, 0, 0) end
        callDir:Normalize()

        if P51_SpawnAtPos(centerPos, callDir) then
            ply:PrintMessage(HUD_PRINTCENTER, "[Backup Fighter] P-51D inbound!")
        else
            ply:PrintMessage(HUD_PRINTCENTER, "[Backup Fighter] Spawn failed.")
        end
    end)

    -- ============================================================
    -- MAIN POLL TIMER
    -- ============================================================

    timer.Create("P51Backup_Think", 0.5, 0, function()
        if not cv_enabled:GetBool() then return end

        local now      = CurTime()
        local interval = math.max(1, cv_interval:GetFloat())

        for _, npc in ipairs(ents.GetAll()) do
            if not IsValid(npc) or not P51_CALLERS[npc:GetClass()] then continue end

            if not npc.__p51backup_hooked then
                npc.__p51backup_hooked    = true
                npc.__p51backup_nextCheck = now + math.Rand(1, interval)
                npc.__p51backup_lastCall  = 0
            end

            if now < npc.__p51backup_nextCheck then continue end

            local jitter = math.min(2, interval * 0.5)
            npc.__p51backup_nextCheck = now + interval + math.Rand(-jitter, jitter)

            if now - npc.__p51backup_lastCall < cv_cooldown:GetFloat() then continue end
            if npc:Health() <= 0 then continue end

            local enemy = npc:GetEnemy()
            if not IsValid(enemy) or not enemy:IsPlayer() or not enemy:Alive() then continue end

            local dist = npc:GetPos():Distance(enemy:GetPos())
            if dist > cv_max_dist:GetFloat() or dist < cv_min_dist:GetFloat() then continue end

            if math.random() > cv_chance:GetFloat() then continue end

            if P51_FireMunition(npc, enemy) then
                npc.__p51backup_lastCall = now
                P51_Debug("Call accepted targeting " .. tostring(enemy))
            end
        end
    end)

end -- SERVER

-- ============================================================
-- CLIENT — flare dynamic light
-- ============================================================

if CLIENT then
    local p51_activeFlares = {}

    net.Receive("P51Backup_FlareSpawned", function()
        local flare = net.ReadEntity()
        if IsValid(flare) then
            p51_activeFlares[flare:EntIndex()] = flare
        end
    end)

    hook.Add("Think", "P51Backup_FlareLight", function()
        for idx, flare in pairs(p51_activeFlares) do
            if not IsValid(flare) then
                p51_activeFlares[idx] = nil
                continue
            end

            local dlight = DynamicLight(flare:EntIndex())
            if dlight then
                dlight.Pos        = flare:GetPos()
                dlight.r          = 0
                dlight.g          = 80
                dlight.b          = 255
                dlight.Brightness = (math.random() > 0.4) and math.Rand(4.0, 6.0) or math.Rand(0.0, 0.2)
                dlight.Size       = 55
                dlight.Decay      = 3000
                dlight.DieTime    = CurTime() + 0.05
            end
        end
    end)
end
