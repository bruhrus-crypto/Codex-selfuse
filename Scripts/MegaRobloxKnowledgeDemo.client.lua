--!strict
-- MegaRobloxKnowledgeDemo.client.lua
-- Place in StarterPlayerScripts
-- Demo: HUD (theme), input throttling, time sync, local-only VFX handling with validation.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gameFolder = ReplicatedStorage:WaitForChild("Game")
local remotes = gameFolder:WaitForChild("RemoteEvents")
local inputEvent = remotes:WaitForChild("Input") :: RemoteEvent
local combatEvent = remotes:WaitForChild("CombatEvent") :: RemoteEvent
local timeSyncEvent = remotes:WaitForChild("TimeSync") :: RemoteEvent

-- =========================================================
-- Theme tokens (UI consistency)
-- =========================================================
local Theme = {
	bg = Color3.fromRGB(12, 12, 15),
	surface = Color3.fromRGB(34, 34, 40),
	primary = Color3.fromRGB(40, 125, 255),
	text = Color3.fromRGB(235, 235, 240),
	muted = Color3.fromRGB(170, 170, 180),
	danger = Color3.fromRGB(240, 80, 80),
	radius = 8,
}

-- =========================================================
-- GUI setup
-- =========================================================
local screen = Instance.new("ScreenGui")
screen.Name = "MegaDemoHUD"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.Parent = playerGui

local top = Instance.new("Frame")
top.Size = UDim2.new(1, 0, 0, 72)
top.BackgroundTransparency = 1
top.Parent = screen

local card = Instance.new("Frame")
card.Size = UDim2.new(0, 320, 0, 56)
card.Position = UDim2.new(0, 12, 0, 8)
card.BackgroundColor3 = Theme.surface
card.BorderSizePixel = 0
card.Parent = top

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, Theme.radius)
corner.Parent = card

local hpLabel = Instance.new("TextLabel")
hpLabel.Size = UDim2.new(1, -16, 0, 20)
hpLabel.Position = UDim2.new(0, 8, 0, 6)
hpLabel.BackgroundTransparency = 1
hpLabel.Font = Enum.Font.SourceSansSemibold
hpLabel.TextSize = 18
hpLabel.TextColor3 = Theme.text
hpLabel.TextXAlignment = Enum.TextXAlignment.Left
hpLabel.Text = "Health: 100"
hpLabel.Parent = card

local barBg = Instance.new("Frame")
barBg.Size = UDim2.new(1, -16, 0, 14)
barBg.Position = UDim2.new(0, 8, 0, 32)
barBg.BackgroundColor3 = Theme.bg
barBg.BorderSizePixel = 0
barBg.Parent = card
local bgCorner = Instance.new("UICorner")
bgCorner.CornerRadius = UDim.new(0, 7)
bgCorner.Parent = barBg

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(1, 0, 1, 0)
barFill.BackgroundColor3 = Theme.danger
barFill.BorderSizePixel = 0
barFill.Parent = barBg
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 7)
fillCorner.Parent = barFill

local firePanel = Instance.new("Frame")
firePanel.Size = UDim2.new(0, 250, 0, 70)
firePanel.Position = UDim2.new(1, -264, 1, -84)
firePanel.BackgroundTransparency = 1
firePanel.Parent = screen

local fireBtn = Instance.new("TextButton")
fireBtn.Size = UDim2.new(0, 110, 0, 48)
fireBtn.Position = UDim2.new(0, 0, 0, 0)
fireBtn.BackgroundColor3 = Theme.primary
fireBtn.TextColor3 = Theme.text
fireBtn.Text = "Fire"
fireBtn.Font = Enum.Font.SourceSansBold
fireBtn.TextSize = 20
fireBtn.AutoButtonColor = false
fireBtn.Parent = firePanel
local fireCorner = Instance.new("UICorner")
fireCorner.CornerRadius = UDim.new(0, Theme.radius)
fireCorner.Parent = fireBtn

local infoLabel = Instance.new("TextLabel")
infoLabel.Size = UDim2.new(0, 126, 0, 48)
infoLabel.Position = UDim2.new(0, 120, 0, 0)
infoLabel.BackgroundColor3 = Theme.surface
infoLabel.BorderSizePixel = 0
infoLabel.TextColor3 = Theme.muted
infoLabel.Font = Enum.Font.SourceSans
infoLabel.TextSize = 16
infoLabel.Text = "Cooldown: 0.0"
infoLabel.Parent = firePanel
local iCorner = Instance.new("UICorner")
iCorner.CornerRadius = UDim.new(0, Theme.radius)
iCorner.Parent = infoLabel

-- =========================================================
-- Input + prediction hints
-- =========================================================
local moveX, moveZ = 0, 0
local fireHeld = false
local turretYaw = 0
local serverTimeOffset = 0
local localCooldown = 0

local SEND_HZ = 20
local SEND_INTERVAL = 1 / SEND_HZ
local sendAccumulator = 0

local function clampInputAxis(v: number): number
	if v > 1 then return 1 end
	if v < -1 then return -1 end
	return v
end

local function updateFromKey(code: Enum.KeyCode, down: boolean)
	local d = down and 1 or 0
	if code == Enum.KeyCode.W then moveZ = moveZ - (down and 1 or -1) end
	if code == Enum.KeyCode.S then moveZ = moveZ + (down and 1 or -1) end
	if code == Enum.KeyCode.A then moveX = moveX - (down and 1 or -1) end
	if code == Enum.KeyCode.D then moveX = moveX + (down and 1 or -1) end
	moveX = clampInputAxis(moveX)
	moveZ = clampInputAxis(moveZ)
end

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.S or input.KeyCode == Enum.KeyCode.D then
		updateFromKey(input.KeyCode, true)
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		fireHeld = true
	end
end)

UserInputService.InputEnded:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.S or input.KeyCode == Enum.KeyCode.D then
		updateFromKey(input.KeyCode, false)
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		fireHeld = false
	end
end)

fireBtn.Activated:Connect(function()
	fireHeld = true
	task.delay(0.12, function()
		fireHeld = false
	end)
end)

-- Turret yaw (simple camera-driven placeholder)
RunService.RenderStepped:Connect(function(dt)
	localCooldown = math.max(0, localCooldown - dt)
	infoLabel.Text = string.format("Cooldown: %.1f", localCooldown)

	local cam = workspace.CurrentCamera
	if cam then
		local look = cam.CFrame.LookVector
		turretYaw = math.clamp(math.atan2(look.X, look.Z), -math.pi, math.pi)
	end

	sendAccumulator += dt
	if sendAccumulator >= SEND_INTERVAL then
		sendAccumulator -= SEND_INTERVAL
		inputEvent:FireServer("Input", {
			moveVector = Vector3.new(moveX, 0, moveZ),
			turretYaw = turretYaw,
			fire = fireHeld,
			clientTick = tick(),
		})
		if fireHeld then
			localCooldown = 0.55
		end
	end
end)

-- periodic time-sync handshake (hint only)
task.spawn(function()
	while true do
		task.wait(2)
		timeSyncEvent:FireServer(tick())
	end
end)

timeSyncEvent.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	if type(payload.serverNow) ~= "number" or type(payload.clientTick) ~= "number" then return end
	serverTimeOffset = payload.serverNow - payload.clientTick
end)

-- =========================================================
-- Remote receive validation + visuals
-- =========================================================
local allowedActions: {[string]: boolean} = {
	PlayVFX = true,
	ShowDamage = true,
	ProjectileSpawn = true,
}

local function playVFX(payload: {[string]: any})
	if typeof(payload.position) ~= "Vector3" then return end
	if type(payload.effectType) ~= "string" then return end

	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(0.8, 0.8, 0.8)
	p.Anchored = true
	p.CanCollide = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 210, 80)
	p.Position = payload.position
	p.Parent = workspace

	local t = TweenService:Create(p, TweenInfo.new(0.25, Enum.EasingStyle.Quad), {Size = Vector3.new(3.2, 3.2, 3.2), Transparency = 1})
	t:Play()
	t.Completed:Once(function()
		p:Destroy()
	end)
end

local function showDamage(payload: {[string]: any})
	if type(payload.amount) ~= "number" then return end
	if payload.target == player.UserId then
		local current = hpLabel.Text
		hpLabel.Text = string.format("Health: ???  (-%d)", math.floor(payload.amount))
		task.delay(0.35, function()
			hpLabel.Text = current
		end)
	end
end

combatEvent.OnClientEvent:Connect(function(action: any, payload: any)
	if type(action) ~= "string" or not allowedActions[action] then return end
	if type(payload) ~= "table" then return end

	if action == "PlayVFX" then
		pcall(playVFX, payload)
	elseif action == "ShowDamage" then
		pcall(showDamage, payload)
	elseif action == "ProjectileSpawn" then
		-- optional local trail visualization could go here
	end
end)

print("[MegaDemo] Client HUD loaded")
