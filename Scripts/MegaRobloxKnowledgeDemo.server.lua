--!strict
-- MegaRobloxKnowledgeDemo.server.lua
-- Place in ServerScriptService
-- Demo: server-authoritative movement intent, physics root, projectile raycast pipeline,
-- pooling, telemetry, anti-spam/rate-limit, relevance routing, cleanup.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

-- =========================================================
-- Config / Flags
-- =========================================================
local FeatureFlags = {
	NewCombatV2 = true,
	VerboseLogs = false,
}

local CONFIG = {
	INPUT_HZ = 20,
	INPUT_MSG_LIMIT_PER_SEC = 35,
	MAX_MOVE_VECTOR = 1.0,
	MAX_TURRET_YAW = math.pi,
	MAX_PROJECTILE_RANGE = 450,
	DEFAULT_PROJECTILE_SPEED = 220,
	FIRE_COOLDOWN_SEC = 0.55,
	MAX_DAMAGE = 120,
	PROXIMITY_BROADCAST_RADIUS = 280,
	MAX_CLIENT_TICK_DRIFT = 10, -- only hint; not authoritative reject reason
	TANK_FORCE_CLAMP = 120000,
}

-- =========================================================
-- Folders / remotes
-- =========================================================
local gameFolder = ReplicatedStorage:FindFirstChild("Game") or Instance.new("Folder")
gameFolder.Name = "Game"
gameFolder.Parent = ReplicatedStorage

local remoteFolder = gameFolder:FindFirstChild("RemoteEvents") or Instance.new("Folder")
remoteFolder.Name = "RemoteEvents"
remoteFolder.Parent = gameFolder

local function getOrCreateRemote(name: string): RemoteEvent
	local r = remoteFolder:FindFirstChild(name)
	if r and r:IsA("RemoteEvent") then
		return r
	end
	local ev = Instance.new("RemoteEvent")
	ev.Name = name
	ev.Parent = remoteFolder
	return ev
end

local inputEvent = getOrCreateRemote("Input") -- client -> server
local combatEvent = getOrCreateRemote("CombatEvent") -- server -> client
local timeSyncEvent = getOrCreateRemote("TimeSync") -- handshake helper

-- =========================================================
-- Helpers
-- =========================================================
local function log(...: any)
	if FeatureFlags.VerboseLogs then
		print("[MegaDemo]", ...)
	end
end

local function isNumberInRange(v: any, minV: number, maxV: number): boolean
	return type(v) == "number" and v >= minV and v <= maxV
end

local function isVector3(v: any): boolean
	return typeof(v) == "Vector3"
end

local function getCharacterRoot(character: Model?): BasePart?
	if not character then return nil end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getNearPlayers(origin: Vector3, radius: number): {Player}
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local root = getCharacterRoot(p.Character)
		if root and (root.Position - origin).Magnitude <= radius then
			table.insert(out, p)
		end
	end
	return out
end

local function fireNearby(origin: Vector3, action: string, payload: {[string]: any}, radius: number)
	for _, p in ipairs(getNearPlayers(origin, radius)) do
		combatEvent:FireClient(p, action, payload)
	end
end

-- =========================================================
-- Types / state
-- =========================================================
export type InputPayload = {
	moveVector: Vector3,
	turretYaw: number,
	fire: boolean,
	clientTick: number?,
}

type TankState = {
	model: Model,
	root: BasePart,
	vectorForce: VectorForce,
	attachment: Attachment,
	cooldownRemaining: number,
	lastInput: InputPayload?,
}

local tanksByUserId: {[number]: TankState} = {}
local stateByUserId: {[number]: {health: number, maxHealth: number, ammo: number}} = {}

local inputRate: {[number]: {count: number, windowStart: number}} = {}
local rejectCounters: {[number]: number} = {}

-- =========================================================
-- Simple projectile pool (server)
-- =========================================================
type ProjectileObject = Part
local projectilePool: {ProjectileObject} = {}
local POOL_SIZE = 80

local function createProjectileTemplate(): ProjectileObject
	local p = Instance.new("Part")
	p.Name = "PooledProjectile"
	p.Size = Vector3.new(0.3, 0.3, 1.8)
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 190, 60)
	p.CanCollide = false
	p.Anchored = true -- visual-only shell for this demo
	p.Transparency = 1
	p.Parent = workspace
	return p
end

for _ = 1, POOL_SIZE do
	table.insert(projectilePool, createProjectileTemplate())
end

local function acquireProjectile(): ProjectileObject
	local p = table.remove(projectilePool)
	if p then
		p.Transparency = 0
		return p
	end
	return createProjectileTemplate()
end

local function releaseProjectile(p: ProjectileObject)
	p.Transparency = 1
	p.CFrame = CFrame.new(0, -5000, 0)
	table.insert(projectilePool, p)
end

-- =========================================================
-- Tank construction (demo assembly-root)
-- =========================================================
local function createDemoTankForPlayer(player: Player): TankState?
	local character = player.Character
	local charRoot = getCharacterRoot(character)
	if not charRoot then return nil end

	local model = Instance.new("Model")
	model.Name = player.Name .. "_DemoTank"
	model.Parent = workspace

	local root = Instance.new("Part")
	root.Name = "PhysicsRoot"
	root.Size = Vector3.new(6, 2.2, 8)
	root.Color = Color3.fromRGB(60, 80, 90)
	root.Material = Enum.Material.Metal
	root.Anchored = false
	root.CanCollide = true
	root.CFrame = charRoot.CFrame * CFrame.new(0, 3, 0)
	root.Parent = model

	local turret = Instance.new("Part")
	turret.Name = "Turret"
	turret.Size = Vector3.new(4.5, 1.5, 4.5)
	turret.Color = Color3.fromRGB(80, 95, 110)
	turret.Material = Enum.Material.Metal
	turret.Anchored = false
	turret.CanCollide = true
	turret.CFrame = root.CFrame * CFrame.new(0, 1.8, 0)
	turret.Parent = model

	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Size = Vector3.new(0.8, 0.8, 4.8)
	barrel.Color = Color3.fromRGB(95, 95, 95)
	barrel.Material = Enum.Material.Metal
	barrel.Anchored = false
	barrel.CanCollide = true
	barrel.CFrame = turret.CFrame * CFrame.new(0, 0, -3.2)
	barrel.Parent = model

	local w1 = Instance.new("WeldConstraint")
	w1.Part0 = root
	w1.Part1 = turret
	w1.Parent = turret

	local w2 = Instance.new("WeldConstraint")
	w2.Part0 = turret
	w2.Part1 = barrel
	w2.Parent = barrel

	model.PrimaryPart = root

	local attach = Instance.new("Attachment")
	attach.Name = "DriveAttachment"
	attach.Parent = root

	local vf = Instance.new("VectorForce")
	vf.Attachment0 = attach
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.Force = Vector3.zero
	vf.Parent = root

	return {
		model = model,
		root = root,
		vectorForce = vf,
		attachment = attach,
		cooldownRemaining = 0,
		lastInput = nil,
	}
end

local function cleanupPlayer(player: Player)
	local uid = player.UserId
	local tank = tanksByUserId[uid]
	if tank then
		pcall(function() tank.model:Destroy() end)
	end
	tanksByUserId[uid] = nil
	stateByUserId[uid] = nil
	inputRate[uid] = nil
	rejectCounters[uid] = nil
end

-- =========================================================
-- Validation / anti-cheat helpers
-- =========================================================
local function checkRate(player: Player, action: string): boolean
	local uid = player.UserId
	local now = workspace:GetServerTimeNow()
	local row = inputRate[uid]
	if not row then
		row = {count = 0, windowStart = now}
		inputRate[uid] = row
	end
	if now - row.windowStart >= 1 then
		row.windowStart = now
		row.count = 0
	end
	row.count += 1
	if row.count > CONFIG.INPUT_MSG_LIMIT_PER_SEC then
		rejectCounters[uid] = (rejectCounters[uid] or 0) + 1
		log("rate reject", uid, action, row.count)
		return false
	end
	return true
end

local function validateInputPayload(payload: any): (boolean, string)
	if type(payload) ~= "table" then return false, "not_table" end
	if not isVector3(payload.moveVector) then return false, "bad_moveVector" end
	if payload.moveVector.Magnitude > CONFIG.MAX_MOVE_VECTOR + 0.001 then return false, "move_oob" end
	if not isNumberInRange(payload.turretYaw, -CONFIG.MAX_TURRET_YAW, CONFIG.MAX_TURRET_YAW) then return false, "bad_turretYaw" end
	if type(payload.fire) ~= "boolean" then return false, "bad_fire" end
	if payload.clientTick ~= nil and type(payload.clientTick) ~= "number" then return false, "bad_clientTick" end
	return true, "ok"
end

-- =========================================================
-- Combat pipeline
-- =========================================================
local function applyDamage(targetPlayer: Player, rawDamage: number, sourcePlayer: Player?)
	local uid = targetPlayer.UserId
	local row = stateByUserId[uid]
	if not row then return end
	local damage = math.clamp(rawDamage, 0, CONFIG.MAX_DAMAGE)
	row.health = math.max(0, row.health - damage)

	combatEvent:FireClient(targetPlayer, "ShowDamage", {
		target = uid,
		amount = damage,
		source = sourcePlayer and sourcePlayer.UserId or nil,
	})

	if row.health <= 0 then
		-- lightweight respawn-ish reset for demo
		row.health = row.maxHealth
	end
end

local function serverFireRaycast(attacker: Player, fromPart: BasePart, direction: Vector3)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {attacker.Character, fromPart.Parent}
	params.IgnoreWater = true

	local origin = fromPart.Position + direction.Unit * 2
	local result = workspace:Raycast(origin, direction.Unit * CONFIG.MAX_PROJECTILE_RANGE, params)

	-- Visual projectile trace via pooled object
	local proj = acquireProjectile()
	proj.CFrame = CFrame.new(origin, origin + direction)
	Debris:AddItem(Instance.new("Folder"), 0) -- no-op to keep Debris referenced in demo

	if result and result.Instance then
		local hitPos = result.Position
		local distance = (hitPos - origin).Magnitude
		local travelTime = math.clamp(distance / CONFIG.DEFAULT_PROJECTILE_SPEED, 0.03, 1.5)

		task.delay(travelTime, function()
			proj.Position = hitPos
			fireNearby(hitPos, "PlayVFX", {
				effectType = "HitSpark",
				position = hitPos,
			}, CONFIG.PROXIMITY_BROADCAST_RADIUS)
			releaseProjectile(proj)
		end)

		local maybeModel = result.Instance:FindFirstAncestorOfClass("Model")
		if maybeModel then
			local hitPlayer = Players:GetPlayerFromCharacter(maybeModel)
			if hitPlayer then
				applyDamage(hitPlayer, 35, attacker)
			end
		end
	else
		-- no hit, return projectile after short travel
		task.delay(0.25, function()
			releaseProjectile(proj)
		end)
	end

	fireNearby(origin, "ProjectileSpawn", {
		id = tostring(attacker.UserId) .. ":" .. tostring(math.floor(workspace:GetServerTimeNow() * 1000)),
		origin = origin,
		dir = direction,
		speed = CONFIG.DEFAULT_PROJECTILE_SPEED,
		projectileType = "DemoShell",
		owner = attacker.UserId,
	}, CONFIG.PROXIMITY_BROADCAST_RADIUS)
end

-- =========================================================
-- Networking handlers
-- =========================================================
inputEvent.OnServerEvent:Connect(function(player: Player, action: string, payload: any)
	if type(action) ~= "string" then return end
	if not checkRate(player, action) then return end

	if action == "Input" then
		local ok, reason = validateInputPayload(payload)
		if not ok then
			rejectCounters[player.UserId] = (rejectCounters[player.UserId] or 0) + 1
			log("reject payload", player.UserId, reason)
			return
		end

		local tank = tanksByUserId[player.UserId]
		if not tank then return end

		if payload.clientTick ~= nil then
			local serverNow = workspace:GetServerTimeNow()
			local drift = math.abs(serverNow - payload.clientTick)
			if drift > CONFIG.MAX_CLIENT_TICK_DRIFT then
				-- only telemetry hint; not hard reject for authority checks
				log("clock drift high", player.UserId, drift)
			end
		end

		tank.lastInput = payload
	end
end)

timeSyncEvent.OnServerEvent:Connect(function(player: Player, clientTick: number)
	if type(clientTick) ~= "number" then return end
	timeSyncEvent:FireClient(player, {
		serverNow = workspace:GetServerTimeNow(),
		clientTick = clientTick,
	})
end)

-- =========================================================
-- Main simulation loop
-- =========================================================
local telemetry = {
	inputs = 0,
	shots = 0,
	rejects = 0,
}

RunService.Heartbeat:Connect(function(dt)
	for uid, tank in pairs(tanksByUserId) do
		-- Cooldowns by server time step
		if tank.cooldownRemaining > 0 then
			tank.cooldownRemaining = math.max(0, tank.cooldownRemaining - dt)
		end

		local payload = tank.lastInput
		if payload then
			telemetry.inputs += 1

			-- Movement intent -> server-side force calculation
			local desiredSpeed = 46
			local move = payload.moveVector
			local forward = tank.root.CFrame.LookVector
			local right = tank.root.CFrame.RightVector
			local desiredVel = (forward * -move.Z + right * move.X) * desiredSpeed
			local currVel = tank.root.AssemblyLinearVelocity
			local mass = tank.root.AssemblyMass
			local desiredAccel = (desiredVel - Vector3.new(currVel.X, 0, currVel.Z)) / math.max(dt, 1e-4)
			local force = Vector3.new(desiredAccel.X, 0, desiredAccel.Z) * mass
			if force.Magnitude > CONFIG.TANK_FORCE_CLAMP then
				force = force.Unit * CONFIG.TANK_FORCE_CLAMP
			end
			tank.vectorForce.Force = force

			if payload.fire and tank.cooldownRemaining <= 0 then
				tank.cooldownRemaining = CONFIG.FIRE_COOLDOWN_SEC
				telemetry.shots += 1
				local dir = CFrame.Angles(0, payload.turretYaw, 0).LookVector
				local owner = Players:GetPlayerByUserId(uid)
				if owner then
					serverFireRaycast(owner, tank.root, dir)
				end
			end
		end
	end

	-- rolling reject aggregation
	for _, count in pairs(rejectCounters) do
		telemetry.rejects += count
	end
end)

-- Aggregated telemetry output (not DataStore logging)
task.spawn(function()
	while true do
		task.wait(10)
		print(string.format(
			"[MegaDemo Telemetry] inputs/10s=%d shots/10s=%d rejects(totalSnapshot)=%d tanks=%d poolFree=%d",
			telemetry.inputs,
			telemetry.shots,
			telemetry.rejects,
			(#Players:GetPlayers()),
			#projectilePool
		))
		telemetry.inputs = 0
		telemetry.shots = 0
		telemetry.rejects = 0
	end
end)

-- Player lifecycle
Players.PlayerAdded:Connect(function(player)
	stateByUserId[player.UserId] = {health = 100, maxHealth = 100, ammo = 999}

	player.CharacterAdded:Connect(function()
		task.wait(0.25)
		cleanupPlayer(player)
		local tank = createDemoTankForPlayer(player)
		if tank then
			tanksByUserId[player.UserId] = tank
		end
	end)
end)

Players.PlayerRemoving:Connect(cleanupPlayer)

print("[MegaDemo] Server system loaded.")
