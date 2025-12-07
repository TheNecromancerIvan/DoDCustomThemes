AddCSLuaFile()
killicon.Add("npc_atrocity", "npc_atrocity/killicon_anim", color_white)
ENT.Base = "base_nextbot"
ENT.PhysgunDisabled = true
ENT.AutomaticFrameAdvance = false
ENT.TauntSounds = {
	Sound("npc_atrocity/taunt.mp3"),
}
local chaseMusic = Sound("npc_atrocity/atrocity.mp3")

local workshopID = "174117071"

local IsValid = IsValid

if SERVER then

local npc_atrocity_acquire_distance =
	CreateConVar("npc_atrocity_acquire_distance", 2500, FCVAR_NONE,
	"The maximum distance at which atrocity will chase a target.")

local npc_atrocity_spawn_protect =
	CreateConVar("npc_atrocity_spawn_protect", 1, FCVAR_NONE,
	"If set to 1, atrocity will not target players or hide within 200 units of \z
	a spawn point.")

local npc_atrocity_attack_distance =
	CreateConVar("npc_atrocity_attack_distance", 80, FCVAR_NONE,
	"The reach of atrocity's attack.")

local npc_atrocity_attack_interval =
	CreateConVar("npc_atrocity_attack_interval", 0.2, FCVAR_NONE,
	"The delay between atrocity's attacks.")

local npc_atrocity_attack_force =
	CreateConVar("npc_atrocity_attack_force", 800, FCVAR_NONE,
	"The physical force of atrocity's attack. Higher values throw things \z
	farther.")

local npc_atrocity_smash_props =
	CreateConVar("npc_atrocity_smash_props", 1, FCVAR_NONE,
	"If set to 1, atrocity will punch through any props placed in their way.")

local npc_atrocity_allow_jump =
	CreateConVar("npc_atrocity_allow_jump", 1, FCVAR_NONE,
	"If set to 1, atrocity will be able to jump.")

local npc_atrocity_hiding_scan_interval =
	CreateConVar("npc_atrocity_hiding_scan_interval", 3, FCVAR_NONE,
	"atrocity will only seek out hiding places every X seconds. This can be an \z
	expensive operation, so it is not recommended to lower this too much. \z
	However, if distant atrocitys are not hiding from you quickly enough, you \z
	may consider lowering this a small amount.")

local npc_atrocity_hiding_repath_interval =
	CreateConVar("npc_atrocity_hiding_repath_interval", 1, FCVAR_NONE,
	"The path to atrocity's hiding spot will be redetermined every X seconds.")

local npc_atrocity_chase_repath_interval =
	CreateConVar("npc_atrocity_chase_repath_interval", 0.1, FCVAR_NONE,
	"The path to and position of atrocity's target will be redetermined every \z
	X seconds.")

local npc_atrocity_expensive_scan_interval =
	CreateConVar("npc_atrocity_expensive_scan_interval", 1, FCVAR_NONE,
	"Slightly expensive operations (distance calculations and entity \z
	searching) will occur every X seconds.")

local npc_atrocity_force_download =
	CreateConVar("npc_atrocity_force_download", 1, FCVAR_ARCHIVE,
	"If set to 1, clients will be forced to download atrocity resources \z
	(restart required after changing).\n\z
	WARNING: If this option is disabled, clients will be unable to see or \z
	hear atrocity!")

local TAUNT_INTERVAL = 1.2
local PATH_INFRACTION_TIMEOUT = 5

if npc_atrocity_force_download:GetBool() then
	resource.AddWorkshop(workshopID)
end

util.AddNetworkString("atrocity_nag")
util.AddNetworkString("atrocity_navgen")

local trace = {
	mask = MASK_SOLID_BRUSHONLY
}

local function isPointNearSpawn(point, distance)
	if not GAMEMODE.SpawnPoints then return false end

	local distanceSqr = distance * distance
	for _, spawnPoint in pairs(GAMEMODE.SpawnPoints) do
		if not IsValid(spawnPoint) then continue end

		if point:DistToSqr(spawnPoint:GetPos()) <= distanceSqr then
			return true
		end
	end

	return false
end

local function isPositionExposed(pos)
	for _, ply in pairs(player.GetAll()) do
		if IsValid(ply) and ply:Alive() and ply:IsLineOfSightClear(pos) then
			return true
		end
	end

	return false
end

local VECTOR_atrocity_HEIGHT = Vector(0, 0, 96)
local function isPointSuitableForHiding(point)
	trace.start = point
	trace.endpos = point + VECTOR_atrocity_HEIGHT
	local tr = util.TraceLine(trace)

	return (not tr.Hit)
end

local g_hidingSpots = nil
local function buildHidingSpotCache()
	local rStart = SysTime()

	g_hidingSpots = {}

	local areas = navmesh.GetAllNavAreas()
	local goodSpots, badSpots = 0, 0
	for _, area in pairs(areas) do
		for _, hidingSpot in pairs(area:GetHidingSpots()) do
			if isPointSuitableForHiding(hidingSpot) then
				g_hidingSpots[goodSpots + 1] = {
					pos = hidingSpot,
					nearSpawn = isPointNearSpawn(hidingSpot, 200),
					occupant = nil
				}
				goodSpots = goodSpots + 1
			else
				badSpots = badSpots + 1
			end
		end
	end

	print(string.format("npc_atrocity: found %d suitable (%d unsuitable) hiding \z
		places in %d areas over %.2fms!", goodSpots, badSpots, #areas,
		(SysTime() - rStart) * 1000))
end

local ai_ignoreplayers = GetConVar("ai_ignoreplayers")
local function isValidTarget(ent)
	if not IsValid(ent) then return false end

	if ent:IsPlayer() then
		if ai_ignoreplayers:GetBool() then return false end
		return ent:Alive()
	end

	local class = ent:GetClass()
	return (ent:IsNPC()
		and ent:Health() > 0
		and class ~= "npc_atrocity"
		and not class:find("bullseye"))
end

hook.Add("PlayerSpawnedNPC", "atrocityMissingNavmeshNag", function(ply, ent)
	if not IsValid(ent) then return end
	if ent:GetClass() ~= "npc_atrocity" then return end
	if navmesh.GetNavAreaCount() > 0 then return end

	net.Start("atrocity_nag")
	net.Send(ply)
end)

local generateStart = 0
local function navEndGenerate()
	local timeElapsedStr = string.NiceTime(SysTime() - generateStart)

	if not navmesh.IsGenerating() then
		print("npc_atrocity: Navmesh generation completed in " .. timeElapsedStr)
	else
		print("npc_atrocity: Navmesh generation aborted after " .. timeElapsedStr)
	end

	RunConsoleCommand("developer", "0")
end

local DEFAULT_SEEDCLASSES = {
	"info_player_start",

	"gmod_player_start", "info_spawnpoint",

	"info_player_combine", "info_player_rebel", "info_player_deathmatch",

	"info_player_counterterrorist", "info_player_terrorist",

	"info_player_allies", "info_player_axis",

	"info_player_teamspawn",

	"info_survivor_position",

	"info_coop_spawn",

	"aoc_spawnpoint",

	"diprip_start_team_red", "diprip_start_team_blue",

	"dys_spawn_point",

	"ins_spawnpoint",

	"info_player_pirate", "info_player_viking", "info_player_knight",

	"info_player_red", "info_player_blue",

	"info_player_coop",

	"info_player_zombiemaster",

	"info_player_human", "info_player_zombie",

	"info_teleport_destination",
}

local function addEntitiesToSet(set, ents)
	for _, ent in pairs(ents) do
		if IsValid(ent) then
			set[ent] = true
		end
	end
end

local NAV_GEN_STEP_SIZE = 25
local function navGenerate()
	local seeds = {}

	for _, class in pairs(DEFAULT_SEEDCLASSES) do
		addEntitiesToSet(seeds, ents.FindByClass(class))
	end

	addEntitiesToSet(seeds, GAMEMODE.SpawnPoints or {})

	if next(seeds, nil) == nil then
		print("npc_atrocity: Couldn't find any places to seed nav_generate")
		return false
	end

	for seed in pairs(seeds) do
		local pos = seed:GetPos()
		pos.x = NAV_GEN_STEP_SIZE * math.Round(pos.x / NAV_GEN_STEP_SIZE)
		pos.y = NAV_GEN_STEP_SIZE * math.Round(pos.y / NAV_GEN_STEP_SIZE)

		trace.start = pos + vector_up
		trace.endpos = pos - vector_up * 16384
		local tr = util.TraceLine(trace)

		if not tr.StartSolid and tr.Hit then
			print(string.format("npc_atrocity: Adding seed %s at %s", seed, pos))
			navmesh.AddWalkableSeed(tr.HitPos, tr.HitNormal)
		else
			print(string.format("npc_atrocity: Couldn't add seed %s at %s", seed,
				pos))
		end
	end

	for _, atrocity in pairs(ents.FindByClass("npc_atrocity")) do
		atrocity:Remove()
	end

	navmesh.SetPlayerSpawnName(next(seeds, nil):GetClass())

	navmesh.BeginGeneration()

	if navmesh.IsGenerating() then
		generateStart = SysTime()
		hook.Add("ShutDown", "atrocityNavGen", navEndGenerate)
	else
		print("npc_atrocity: nav_generate failed to initialize")
		navmesh.ClearWalkableSeeds()
	end

	return navmesh.IsGenerating()
end

concommand.Add("npc_atrocity_learn", function(ply, cmd, args)
	if navmesh.IsGenerating() then
		return
	end

	local isConsole = (ply:EntIndex() == 0)
	if game.SinglePlayer() then
		print("npc_atrocity: Beginning nav_generate requested by " .. ply:Name())

		RunConsoleCommand("nav_max_view_distance", "1")
		RunConsoleCommand("nav_quicksave", "1")

		RunConsoleCommand("developer", "1")
	elseif isConsole then
		print("npc_atrocity: Beginning nav_generate requested by server console")
	else
		return
	end

	local success = navGenerate()

	local recipients = (success and player.GetHumans() or {ply})

	net.Start("atrocity_navgen")
		net.WriteBool(success)
	net.Send(recipients)
end)

ENT.LastPathRecompute = 0
ENT.LastTargetSearch = 0
ENT.LastJumpScan = 0
ENT.LastCeilingUnstick = 0
ENT.LastAttack = 0
ENT.LastHidingPlaceScan = 0
ENT.LastTaunt = 0

ENT.CurrentTarget = nil
ENT.HidingSpot = nil

function ENT:Initialize()
	self:SetSpawnEffect(false)

	self:SetBloodColor(DONT_BLEED)

	self:SetHealth(1e8)

	self:SetRenderMode(RENDERMODE_TRANSALPHA)
	self:SetColor(Color(255, 255, 255, 1))

	self:SetCollisionBounds(Vector(-13, -13, 0), Vector(13, 13, 72))

	self.loco:SetDeathDropHeight(600)

	self.loco:SetDesiredSpeed(game.SinglePlayer() and 650 or 500)

	self.loco:SetAcceleration(500)
	self.loco:SetDeceleration(500)

	self.loco:SetJumpHeight(300)

	self:OnReloaded()
end

function ENT:OnInjured(dmg)
	dmg:SetDamage(0)
end

function ENT:OnReloaded()
	if g_hidingSpots == nil then
		buildHidingSpotCache()
	end
end

function ENT:OnRemove()
	self:ClaimHidingSpot(nil)
end

function ENT:GetNearestTarget()
	local maxAcquireDist = npc_atrocity_acquire_distance:GetInt()
	local maxAcquireDistSqr = maxAcquireDist * maxAcquireDist
	local myPos = self:GetPos()
	local acquirableEntities = ents.FindInSphere(myPos, maxAcquireDist)
	local distToSqr = myPos.DistToSqr
	local getPos = self.GetPos
	local target = nil
	local getClass = self.GetClass

	for _, ent in pairs(acquirableEntities) do
		if not isValidTarget(ent) then continue end

		if npc_atrocity_spawn_protect:GetBool() and ent:IsPlayer()
			and isPointNearSpawn(ent:GetPos(), 200)
		then
			continue
		end

		local distSqr = distToSqr(getPos(ent), myPos)
		if distSqr < maxAcquireDistSqr then
			target = ent
			maxAcquireDistSqr = distSqr
		end
	end

	return target
end

function ENT:AttackNearbyTargets(radius)
	local attackForce = npc_atrocity_attack_force:GetInt()
	local hitSource = self:LocalToWorld(self:OBBCenter())
	local nearEntities = ents.FindInSphere(hitSource, radius)
	local hit = false
	for _, ent in pairs(nearEntities) do
		if isValidTarget(ent) then
			local health = ent:Health()

			if ent:IsPlayer() and IsValid(ent:GetVehicle()) then
				local vehicle = ent:GetVehicle()

				local vehiclePos = vehicle:LocalToWorld(vehicle:OBBCenter())
				local hitDirection = (vehiclePos - hitSource):GetNormal()

				local phys = vehicle:GetPhysicsObject()
				if IsValid(phys) then
					phys:Wake()
					local hitOffset = vehicle:NearestPoint(hitSource)
					phys:ApplyForceOffset(hitDirection
						* (attackForce * phys:GetMass()),
						hitOffset)
				end
				vehicle:TakeDamage(math.max(1e8, ent:Health()), self, self)

				vehicle:EmitSound(string.format(
					"physics/metal/metal_sheet_impact_hard%d.wav",
					math.random(6, 8)), 350, 120)
			else
				ent:EmitSound(string.format(
					"physics/body/body_medium_impact_hard%d.wav",
					math.random(1, 6)), 350, 120)
			end

			local hitDirection = (ent:GetPos() - hitSource):GetNormal()
			ent:SetVelocity(hitDirection * attackForce + vector_up * 500)

			local dmgInfo = DamageInfo()
			dmgInfo:SetAttacker(self)
			dmgInfo:SetInflictor(self)
			dmgInfo:SetDamage(1e8)
			dmgInfo:SetDamagePosition(self:GetPos())
			dmgInfo:SetDamageForce((hitDirection * attackForce
				+ vector_up * 500) * 100)
			ent:TakeDamageInfo(dmgInfo)

			local newHealth = ent:Health()

			hit = (hit or (newHealth < health))
		elseif ent:GetMoveType() == MOVETYPE_VPHYSICS then
			if not npc_atrocity_smash_props:GetBool() then continue end
			if ent:IsVehicle() and IsValid(ent:GetDriver()) then continue end

			local entPos = ent:LocalToWorld(ent:OBBCenter())
			local hitDirection = (entPos - hitSource):GetNormal()
			local hitOffset = ent:NearestPoint(hitSource)

			constraint.RemoveAll(ent)

			local phys = ent:GetPhysicsObject()
			local mass = 0
			local material = "Default"
			if IsValid(phys) then
				mass = phys:GetMass()
				material = phys:GetMaterial()
			end

			if mass >= 5 then
				ent:EmitSound(material .. ".ImpactHard", 350, 120)
			end

			for id = 0, ent:GetPhysicsObjectCount() - 1 do
				local phys = ent:GetPhysicsObjectNum(id)
				if IsValid(phys) then
					phys:EnableMotion(true)
					phys:ApplyForceOffset(hitDirection * (attackForce * mass),
						hitOffset)
				end
			end

			ent:TakeDamage(25, self, self)
		end
	end

	return hit
end

function ENT:IsHidingSpotFull(hidingSpot)
	local occupant = hidingSpot.occupant
	if not IsValid(occupant) or occupant == self then
		return false
	end

	return true
end

function ENT:GetNearestUsableHidingSpot()
	local nearestHidingSpot = nil
	local nearestHidingDistSqr = 1e8

	local myPos = self:GetPos()
	local isHidingSpotFull = self.IsHidingSpotFull
	local distToSqr = myPos.DistToSqr

	for _, hidingSpot in pairs(g_hidingSpots) do
		if hidingSpot.nearSpawn or isHidingSpotFull(self, hidingSpot) then
			continue
		end

		local hidingSpotDistSqr = distToSqr(hidingSpot.pos, myPos)
		if hidingSpotDistSqr < nearestHidingDistSqr
			and not isPositionExposed(hidingSpot.pos)
		then
			nearestHidingDistSqr = hidingSpotDistSqr
			nearestHidingSpot = hidingSpot
		end
	end

	return nearestHidingSpot
end

function ENT:ClaimHidingSpot(hidingSpot)
	if self.HidingSpot ~= nil then
		self.HidingSpot.occupant = nil
	end

	if hidingSpot == nil or self:IsHidingSpotFull(hidingSpot) then
		self.HidingSpot = nil
		return false
	end

	self.HidingSpot = hidingSpot
	self.HidingSpot.occupant = self
	return true
end

local HIGH_JUMP_HEIGHT = 500
function ENT:AtatrocitytJumpAtTarget()
	if not self:IsOnGround() then return end

	local targetPos = self.CurrentTarget:GetPos()
	local xyDistSqr = (targetPos - self:GetPos()):Length2DSqr()
	local zDifference = targetPos.z - self:GetPos().z
	local maxAttackDistance = npc_atrocity_attack_distance:GetInt()
	if xyDistSqr <= math.pow(maxAttackDistance + 200, 2)
		and zDifference >= maxAttackDistance
	then
		local jumpHeight = zDifference + 50
		self.loco:SetJumpHeight(jumpHeight)
		self.loco:Jump()
		self.loco:SetJumpHeight(300)

	end
end

local VECTOR_HIGH = Vector(0, 0, 16384)
ENT.LastPathingInfraction = 0
function ENT:RecomputeTargetPath()
	if CurTime() - self.LastPathingInfraction < PATH_INFRACTION_TIMEOUT then
		return
	end

	local targetPos = self.CurrentTarget:GetPos()

	trace.start = targetPos
	trace.endpos = targetPos - VECTOR_HIGH
	trace.filter = self.CurrentTarget
	local tr = util.TraceEntity(trace, self.CurrentTarget)

	if tr.Hit and util.IsInWorld(tr.HitPos) then
		targetPos = tr.HitPos
	end

	local rTime = SysTime()
	self.MovePath:Compute(self, targetPos)

	if SysTime() - rTime > 0.005 then
		self.LastPathingInfraction = CurTime()
	end
end

function ENT:BehaveStart()
	self.MovePath = Path("Follow")
	self.MovePath:SetMinLookAheadDistance(500)
	self.MovePath:SetGoalTolerance(10)
end

local ai_disabled = GetConVar("ai_disabled")
function ENT:BehaveUpdate()
	if ai_disabled:GetBool() then
		return
	end

	local currentTime = CurTime()

	local scanInterval = npc_atrocity_expensive_scan_interval:GetFloat()
	if currentTime - self.LastTargetSearch > scanInterval then
		local target = self:GetNearestTarget()

		if target ~= self.CurrentTarget then
			self.LastPathRecompute = 0
		end

		self.CurrentTarget = target
		self.LastTargetSearch = currentTime
	end

	if IsValid(self.CurrentTarget) then
		self.LastHidingPlaceScan = 0

		local attackInterval = npc_atrocity_attack_interval:GetFloat()
		if currentTime - self.LastAttack > attackInterval then
			local attackDistance = npc_atrocity_attack_distance:GetInt()
			if self:AttackNearbyTargets(attackDistance) then
				if currentTime - self.LastTaunt > TAUNT_INTERVAL then
					self.LastTaunt = currentTime
					self:EmitSound(table.Random(self.TauntSounds), 350, 100)
				end

				self.LastTargetSearch = 0
			end

			self.LastAttack = currentTime
		end

		local repathInterval = npc_atrocity_chase_repath_interval:GetFloat()
		if currentTime - self.LastPathRecompute > repathInterval then
			self.LastPathRecompute = currentTime
			self:RecomputeTargetPath()
		end

		self.MovePath:Update(self)

		if self:IsOnGround() and npc_atrocity_allow_jump:GetBool()
			and currentTime - self.LastJumpScan >= scanInterval
		then
			self:AtatrocitytJumpAtTarget()
			self.LastJumpScan = currentTime
		end
	else
		local hidingScanInterval = npc_atrocity_hiding_scan_interval:GetFloat()
		if currentTime - self.LastHidingPlaceScan >= hidingScanInterval then
			self.LastHidingPlaceScan = currentTime

			local hidingSpot = self:GetNearestUsableHidingSpot()
			self:ClaimHidingSpot(hidingSpot)
		end

		if self.HidingSpot ~= nil then
			local hidingInterval = npc_atrocity_hiding_repath_interval:GetFloat()
			if currentTime - self.LastPathRecompute >= hidingInterval then
				self.LastPathRecompute = currentTime
				self.MovePath:Compute(self, self.HidingSpot.pos)
			end
			self.MovePath:Update(self)
		else
		end
	end

	if currentTime - self.LastCeilingUnstick >= scanInterval then
		self:UnstickFromCeiling()
		self.LastCeilingUnstick = currentTime
	end

	if currentTime - self.LastStuck >= 5 then
		self.StuckTries = 0
	end
end

ENT.LastStuck = 0
ENT.StuckTries = 0
function ENT:OnStuck()
	self.LastStuck = CurTime()

	local newCursor = self.MovePath:GetCursorPosition()
		+ 40 * math.pow(2, self.StuckTries)
	self:SetPos(self.MovePath:GetPositionOnPath(newCursor))
	self.StuckTries = self.StuckTries + 1

	self.loco:ClearStuck()
end

function ENT:UnstickFromCeiling()
	if self:IsOnGround() then return end

	local myPos = self:GetPos()
	local myHullMin, myHullMax = self:GetCollisionBounds()
	local myHull = myHullMax - myHullMin
	local myHullTop = myPos + vector_up * myHull.z
	trace.start = myPos
	trace.endpos = myHullTop
	trace.filter = self
	local upTrace = util.TraceLine(trace, self)

	if upTrace.Hit and upTrace.HitNormal ~= vector_origin
		and upTrace.Fraction > 0.5
	then
		local unstuckPos = myPos
			+ upTrace.HitNormal * (myHull.z * (1 - upTrace.Fraction))
		self:SetPos(unstuckPos)
	end
end

else

local MAT_atrocity = Material("npc_atrocity/atrocity")
killicon.Add("npc_atrocity", "npc_atrocity/killicon", color_white)
language.Add("npc_atrocity", "atrocity")

ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

local developer = GetConVar("developer")
local function DevPrint(devLevel, msg)
	if developer:GetInt() >= devLevel then
		print("npc_atrocity: " .. msg)
	end
end

local panicMusic = nil
local lastPanic = 0

local npc_atrocity_music_volume =
	CreateConVar("npc_atrocity_music_volume", 1,
	bit.bor(FCVAR_DEMO, FCVAR_ARCHIVE),
	"Maximum music volume when being chased by atrocity. (0-1, where 0 is muted)")

local MUSIC_RESTART_DELAY = 2

local MUSIC_CUTOFF_DISTANCE = 1000

local MUSIC_PANIC_DISTANCE = 200

local MUSIC_atrocity_PANIC_COUNT = 8

local MUSIC_atrocity_MAX_DISTANCE_SCORE =
	(MUSIC_CUTOFF_DISTANCE - MUSIC_PANIC_DISTANCE) * MUSIC_atrocity_PANIC_COUNT

local function updatePanicMusic()
	if #ents.FindByClass("npc_atrocity") == 0 then
		DevPrint(4, "Halting music timer.")
		timer.Remove("atrocityPanicMusicUpdate")

		if panicMusic ~= nil then
			panicMusic:Stop()
		end

		return
	end

	if panicMusic == nil then
		if IsValid(LocalPlayer()) then
			panicMusic = CreateSound(LocalPlayer(), chaseMusic)
			panicMusic:Stop()
		else
			return
		end
	end

	local userVolume = math.Clamp(npc_atrocity_music_volume:GetFloat(), 0, 1)
	if userVolume == 0 or not IsValid(LocalPlayer()) then
		panicMusic:Stop()
		return
	end

	local totalDistanceScore = 0
	local nearEntities = ents.FindInSphere(LocalPlayer():GetPos(), 1000)
	for _, ent in pairs(nearEntities) do
		if IsValid(ent) and ent:GetClass() == "npc_atrocity" then
			local distanceScore = math.max(0, MUSIC_CUTOFF_DISTANCE
				- LocalPlayer():GetPos():Distance(ent:GetPos()))
			totalDistanceScore = totalDistanceScore + distanceScore
		end
	end

	local musicVolume = math.min(1,
		totalDistanceScore / MUSIC_atrocity_MAX_DISTANCE_SCORE)

	local shouldRestartMusic = (CurTime() - lastPanic >= MUSIC_RESTART_DELAY)
	if musicVolume > 0 then
		if shouldRestartMusic then
			panicMusic:Play()
		end

		if not LocalPlayer():Alive() then
			musicVolume = musicVolume / 4
		end

		lastPanic = CurTime()
	elseif shouldRestartMusic then
		panicMusic:Stop()
		return
	else
		musicVolume = 0
	end

	musicVolume = math.max(0.01, musicVolume * userVolume)

	panicMusic:Play()

	panicMusic:ChangePitch(math.Clamp(game.GetTimeScale() * 100, 50, 255), 0)
	panicMusic:ChangeVolume(musicVolume, 0)
end

local REPEAT_FOREVER = 0
local function startTimer()
	if not timer.Exists("atrocityPanicMusicUpdate") then
		timer.Create("atrocityPanicMusicUpdate", 0.05, REPEAT_FOREVER,
			updatePanicMusic)
		DevPrint(4, "Beginning music timer.")
	end
end

local SPRITE_SIZE = 128
function ENT:Initialize()
	self:SetRenderBounds(
		Vector(-SPRITE_SIZE / 2, -SPRITE_SIZE / 2, 0),
		Vector(SPRITE_SIZE / 2, SPRITE_SIZE / 2, SPRITE_SIZE),
		Vector(5, 5, 5)
	)

	startTimer()
end

local DRAW_OFFSET = SPRITE_SIZE / 2 * vector_up
function ENT:DrawTranslucent()
	render.SetMaterial(MAT_atrocity)

	local pos = self:GetPos() + DRAW_OFFSET
	local normal = EyePos() - pos
	normal:Normalize()
	local xyNormal = Vector(normal.x, normal.y, 0)
	xyNormal:Normalize()

	local pitch = math.acos(math.Clamp(normal:Dot(xyNormal), -1, 1)) / 3
	local cos = math.cos(pitch)
	normal = Vector(
		xyNormal.x * cos,
		xyNormal.y * cos,
		math.sin(pitch)
	)

	render.DrawQuadEasy(pos, normal, SPRITE_SIZE, SPRITE_SIZE,
		color_white, 180)
end

surface.CreateFont("atrocityHUD", {
	font = "Arial",
	size = 56
})

surface.CreateFont("atrocityHUDSmall", {
	font = "Arial",
	size = 24
})

local function string_ToHMS(seconds)
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds / 60) % 60)
	local seconds = math.floor(seconds % 60)

	if hours > 0 then
		return string.format("%02d:%02d:%02d", hours, minutes, seconds)
	else
		return string.format("%02d:%02d", minutes, seconds)
	end
end

local flavourTexts = {
	{
		"Gotta learn fast!",
		"Learning this'll be a piece of cake!",
		"This is too easy."
	}, {
		"This must be a big map.",
		"This map is a bit bigger than I thought.",
	}, {
		"Just how big is this place?",
		"This place is pretty big."
	}, {
		"This place is enormous!",
		"A guy could get lost around here."
	}, {
		"Surely I'm almost done...",
		"There can't be too much more...",
		"This isn't gm_bigcity, is it?",
		"Is it over yet?",
		"You never told me the map was this big!"
	}
}
local SECONDS_PER_BRACKET = 300
local color_yellow = Color(255, 255, 80)
local flavourText = ""
local lastBracket = 0
local generateStart = 0
local function navGenerateHUDOverlay()
	draw.SimpleTextOutlined("atrocity is studying this map.", "atrocityHUD",
		ScrW() / 2, ScrH() / 2, color_white,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2, color_black)
	draw.SimpleTextOutlined("Please wait...", "atrocityHUD",
		ScrW() / 2, ScrH() / 2, color_white,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 2, color_black)

	local elapsed = SysTime() - generateStart
	local elapsedStr = string_ToHMS(elapsed)
	draw.SimpleTextOutlined("Time Elapsed:", "atrocityHUDSmall",
		ScrW() / 2, ScrH() * 3/4, color_white,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
	draw.SimpleTextOutlined(elapsedStr, "atrocityHUDSmall",
		ScrW() / 2, ScrH() * 3/4, color_white,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black)

	local textBracket = math.floor(elapsed / SECONDS_PER_BRACKET) + 1
	if textBracket ~= lastBracket then
		flavourText = table.Random(flavourTexts[math.min(5, textBracket)])
		lastBracket = textBracket
	end
	draw.SimpleTextOutlined(flavourText, "atrocityHUDSmall",
		ScrW() / 2, ScrH() * 4/5, color_yellow,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
end

net.Receive("atrocity_navgen", function()
	local startSuccess = net.ReadBool()
	if startSuccess then
		generateStart = SysTime()
		lastBracket = 0
		hook.Add("HUDPaint", "atrocityNavGenOverlay", navGenerateHUDOverlay)
	else
		Derma_Message("Oh no. atrocity doesn't even know where to start with \z
		this map.\n\z
		If you're not running the Sandbox gamemode, switch to that and try \z
		again.", "Error!")
	end
end)

local nagMe = true

local function requestNavGenerate()
	RunConsoleCommand("npc_atrocity_learn")
end

local function stopNagging()
	nagMe = false
end

local function navWarning()
	Derma_Query("It will take a while (possibly hours) for atrocity to figure \z
		this map out.\n\z
		While he's studying it, you won't be able to play,\n\z
		and the game will appear to have frozen/crashed.\n\z
		\n\z
		Also note that THE MAP WILL BE RESTARTED.\n\z
		Anything that has been built will be deleted.", "Warning!",
		"Go ahead!", requestNavGenerate,
		"Not right now.", nil)
end

net.Receive("atrocity_nag", function()
	if not nagMe then return end

	if game.SinglePlayer() then
		Derma_Query("Uh oh! atrocity doesn't know this map.\n\z
			Would you like him to learn it?",
			"This map is not yet atrocity-compatible!",
			"Yes", navWarning,
			"No", nil,
			"No. Don't ask again.", stopNagging)
	else
		Derma_Query("Uh oh! atrocity doesn't know this map. \z
			He won't be able to move!\n\z
			Because you're not in a single-player game, he isn't able to \z
			learn it.\n\z
			\n\z
			Ask the server host about teaching this map to atrocity.\n\z
			\n\z
			If you ARE the server host, you can run npc_atrocity_learn over \z
			rcon.\n\z
			Keep in mind that it may take hours during which you will be \z
			unable\n\z
			to play, and THE MAP WILL BE RESTARTED.",
			"This map is currently not atrocity-compatible!",
			"Ok", nil,
			"Ok. Don't say this again.", stopNagging)
	end
end)

end

list.Set("NPC", "npc_atrocity", {
	Name = "atrocity",
	Class = "npc_atrocity",
	Category = "BIAST",
	AdminOnly = false
})
