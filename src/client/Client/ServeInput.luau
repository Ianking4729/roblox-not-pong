-- ServeInput (client): the PLAYER's manual serve presentation and input (2026-11-15 pass 2). Requests only: the server
-- (RallyService + Shared/ServeRules) validates the spot, owns the toss, the apex slow motion and the strike.
--
--   * ReadyToServe on your serve: the ball rests in your free (left) hand (BallView draws it there; the toss clip's first
--     frame holds the arm), the LEGAL REGION is outlined on the floor (where to stand: blue = a toss from here is legal,
--     red = not, with the reason on screen), and the AIM CUE follows the cursor's screen X: a line from your hand to a ring
--     on the receiver's half where the serve's second bounce is aimed (its depth follows the power while charging).
--     Walk anywhere to reposition before tossing.
--   * Space: tosses (the request; the toss clip plays at Config.Serve.TossAnimSpeed and releases the ball at its Release
--     marker, the same moment the server releases it). Space never jumps while it is your serve. From then on the server
--     holds you in place until the serve resolves. Everything runs at normal speed (no serve slow motion).
--   * The strike is the normal shot input (ShotController, CLICK-AND-FLICK since 2026-11-17): a FRESH left-click after
--     the toss locks the aim; a FLICK while holding strikes (flick speed = power, direction = spin; forehand: the serve
--     strike clip from the cocked pose; backhand: the backhand swing). Releasing without a flick cancels (click again
--     while the toss is still up). The timing bar shows the toss's contact phase; a contact inside it is a legal serve.
-- Visual only besides the two requests; nothing here decides anything.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GameStates = require(Shared:WaitForChild("GameStates"))
local ServeRules = require(Shared:WaitForChild("ServeRules"))
local StancePose = require(Shared:WaitForChild("StancePose"))

local BallView = require(script.Parent:WaitForChild("BallView"))
local PlatformZone = require(script.Parent:WaitForChild("PlatformZone"))
local StanceController = require(script.Parent:WaitForChild("StanceController"))

local ServeInput = {}

local shot: any = nil -- ShotController (attached by Main)
local aimLocked: number? = nil
local strikeAt = -math.huge -- os.clock() of the serve strike (the posture is held through the follow-through)

function ServeInput.attachShotController(controller: any)
	shot = controller
	controller.on(function(event: string, data: any)
		if event == "serveAim" then
			aimLocked = data.aim
		elseif event == "cancel" and controller.serving == false and aimLocked ~= nil and BallView.getInfo().serve then
			aimLocked = nil -- released without a flick: the aim follows the cursor again until the next click
		elseif event == "swing" and data.serve then
			strikeAt = os.clock()
			ServeInput._strike(data.stroke)
		end
	end)
end

local function part(name: string, color: Color3, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 1
	p.Parent = parent
	return p
end

function ServeInput.start()
	local player = Players.LocalPlayer
	local arena = workspace:WaitForChild(Config.Names.Arena)
	local remotes = ReplicatedStorage:WaitForChild(Config.Names.Remotes)
	local serveRemote = remotes:WaitForChild("ServeRequest") :: RemoteEvent
	local resultRemote = remotes:WaitForChild("ServeResult") :: RemoteEvent
	local Attr, S = GameStates.Attributes, Config.Serve

	-- ---------- visuals (local only) ----------
	local folder = Instance.new("Folder")
	folder.Name = "NotPongServeVisuals"
	folder.Parent = workspace.CurrentCamera
	local edges = {}
	for i = 1, 4 do
		edges[i] = part("RegionEdge" .. i, S.RegionColor, folder)
	end
	local aimLine = part("AimLine", S.AimColor, folder)
	local aimRing = part("AimRing", S.AimColor, folder)
	aimRing.Shape = Enum.PartType.Cylinder
	aimRing.Size = Vector3.new(0.08, S.AimRingRadius * 2, S.AimRingRadius * 2)

	local gui = Instance.new("ScreenGui")
	gui.Name = "NotPongServe"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = player:WaitForChild("PlayerGui")
	local label = Instance.new("TextLabel")
	label.Name = "Hint"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -150)
	label.Size = UDim2.fromOffset(900, 30)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Text = ""
	label.Parent = gui

	local function myServe(): boolean
		return arena:GetAttribute(Attr.Server) == GameStates.Side.Player
			and arena:GetAttribute(Config.Names.SeatedPlayerAttribute) == player.UserId
	end
	local function state(): string?
		return arena:GetAttribute(Attr.State)
	end

	-- ---------- the toss animation ----------
	local handle: StancePose.ServeHandle? = nil
	local handleCharacter: Model? = nil
	local tossing = false -- Space accepted locally (until the serve resolves)
	local refusedText, refusedUntil = "", 0
	-- SERVING POSTURE (Config.Serve.Posture): Q toggles it before the toss; Space locks it for that serve. Independent of
	-- the cursor (the cursor is only the aim). The choice is remembered for the next serve.
	local posture = ServeRules.posture(S.Posture.Default)
	local lockedPosture: string? = nil
	local function getHandle(): StancePose.ServeHandle?
		local character = player.Character
		if not character then
			return nil
		end
		if handleCharacter ~= character or not handle then
			if handle then
				handle:stop()
			end
			handle = StancePose.serve(character)
			handleCharacter = character
		end
		return handle
	end
	function ServeInput._strike(stroke: string?)
		local h = getHandle()
		if h then
			h:strike(stroke)
		end
	end

	resultRemote.OnClientEvent:Connect(function(msg)
		if typeof(msg) ~= "table" or msg.ok then
			return
		end
		-- refused: back to holding the ball, and say why
		tossing = false
		lockedPosture = nil
		local h = getHandle()
		if h then
			h:hold()
		end
		refusedText, refusedUntil = "Serve refused: " .. tostring(msg.reason), os.clock() + 2
	end)

	ContextActionService:BindActionAtPriority("NotPongServe", function(_, inputState)
		local st = state()
		local mine = myServe()
		if not mine or (st ~= GameStates.State.ReadyToServe and st ~= GameStates.State.Serving) then
			return Enum.ContextActionResult.Pass -- not our serve: Space jumps as usual
		end
		-- our serve: Space never jumps
		if inputState == Enum.UserInputState.Begin and st == GameStates.State.ReadyToServe and not tossing and BallView.getInfo().mode == "hand" then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and character then
				local ok, why = ServeRules.check(root.CFrame, character:GetScale(), posture)
				if ok then
					tossing = true
					aimLocked = nil
					lockedPosture = posture -- Q cannot change it until this serve resolves
					serveRemote:FireServer({ posture = posture })
					local h = getHandle()
					if h then
						h:toss() -- the ball leaves the hand at the clip's Release marker (the server's release moment)
					end
				else
					refusedText, refusedUntil = "Can't serve from here: " .. why, os.clock() + 1.5
				end
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space)

	-- Q: switch the serving posture, only before the toss (while the ball rests in your hand on your serve).
	local function togglePosture(): boolean
		local st = state()
		if not myServe() or st ~= GameStates.State.ReadyToServe or tossing or BallView.getInfo().mode ~= "hand" then
			return false
		end
		posture = if posture == "LeftLead" then "RightLead" else "LeftLead"
		return true
	end
	ContextActionService:BindActionAtPriority("NotPongServePosture", function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		return if togglePosture() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Q)
	if Config.ShotControl.ShowDiagnostics then
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongServeDebug"
		bridge.OnInvoke = function(cmd: string?)
			local toggled = if cmd == "toggle" then togglePosture() else nil
			return { posture = posture, locked = lockedPosture, tossing = tossing, toggled = toggled, yaw = StanceController.getServePostureYaw(), footwork = StanceController.debug() }
		end
		bridge.Parent = player
	end

	-- ---------- per frame ----------
	local holding = false
	RunService.RenderStepped:Connect(function()
		local st = state()
		local info = BallView.getInfo()
		local mine = myServe()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local ready = mine and st == GameStates.State.ReadyToServe
		local inHand = mine and info.mode == "hand"
		local tossInAir = mine and info.serve == true

		-- hold / release the toss pose (only on the platform: off it, Roblox's own animations show, unchanged)
		local onPlatform = PlatformZone.isOn()
		if ready and inHand and not tossing and onPlatform then
			aimLocked = nil -- a new serve: the aim follows the cursor again
			if not holding then
				holding = true
				local h = getHandle()
				if h then
					h:hold()
				end
			end
		elseif holding and not tossing and (not inHand or not onPlatform) then
			holding = false
			local h = getHandle()
			if h then
				h:stop()
			end
		end
		if tossing and not (st == GameStates.State.ReadyToServe or st == GameStates.State.Serving) then
			tossing, holding = false, false -- the serve resolved (point, let, reset)
			local h = handle
			if h then
				h:stop()
			end
		end
		if tossing and st == GameStates.State.Serving and not tossInAir and info.mode ~= "hand" then
			tossing = false -- struck (the ball is in play) or dropped
		end

		-- the serving posture shown: the selected one while the ball rests in the hand, the LOCKED one from Space through
		-- the toss, the strike and its follow-through; none otherwise (rallies, the bot's serve, off the platform)
		local followThrough = os.clock() - strikeAt < S.Posture.FollowThroughHold
		if not tossing and not followThrough and not (ready and inHand) then
			lockedPosture = nil
		end
		local active: string? = nil
		if onPlatform and mine and ((ready and inHand) or tossing or (followThrough and lockedPosture ~= nil)) then
			active = lockedPosture or posture
		end
		StanceController.setServePosture(if active then ServeRules.hipYaw(active) else 0)
		local wantStroke = if active then ServeRules.postureStroke(active) else nil
		if shot and shot.setServeStroke and shot.serveStrokeOverride ~= wantStroke then
			shot.setServeStroke(wantStroke) -- the serve stroke follows the posture, never the cursor's screen side
		end

		-- legal region outline (where to STAND) + hint
		local showRegion = ready and inHand and root ~= nil and not tossing and PlatformZone.isOn()
		local ok, why = false, ""
		if showRegion and root and character then
			ok, why = ServeRules.check(root.CFrame, character:GetScale(), posture)
			local r = ServeRules.region()
			-- the region is for the ball's release point; the stander's root sits behind/right of it by the hand offset
			local off = ServeRules.handPoint(root.CFrame, character:GetScale(), "release", posture) - root.Position
			local minX, maxX = r.minX - off.X, r.maxX - off.X
			local minZ, maxZ = r.minZ - off.Z, r.maxZ - off.Z
			local y = Config.Layout.FloorY + 0.06
			local w = 0.35
			local color = if ok then S.RegionColor else S.RegionBadColor
			local spans = {
				{ CFrame.new((minX + maxX) / 2, y, minZ), Vector3.new(maxX - minX, 0.08, w) },
				{ CFrame.new((minX + maxX) / 2, y, maxZ), Vector3.new(maxX - minX, 0.08, w) },
				{ CFrame.new(minX, y, (minZ + maxZ) / 2), Vector3.new(w, 0.08, maxZ - minZ) },
				{ CFrame.new(maxX, y, (minZ + maxZ) / 2), Vector3.new(w, 0.08, maxZ - minZ) },
			}
			for i, e in edges do
				e.CFrame, e.Size, e.Color, e.Transparency = spans[i][1], spans[i][2], color, 0.25
			end
		else
			for _, e in edges do
				e.Transparency = 1
			end
		end

		-- aim cue on the table: a line from the hand to the second-bounce target ring; follows the cursor until the press
		-- locks it; the ring sits at a nominal depth until the flick sets the power. A placement cue, not a predicted path.
		local showAim = mine and root ~= nil and character ~= nil and (ready or tossing) and (inHand or tossInAir)
		if showAim and root and character then
			local aim = aimLocked
			if aim == nil then
				aim = if shot and shot.pointerAim then shot.pointerAim() else 0
			end
			-- the ring's depth: a nominal pace until the flick decides the power (then the flick's power)
			local power = if shot and shot.flick then shot.power else 0.5
			local from = ServeRules.handPoint(root.CFrame, character:GetScale(), "release", lockedPosture or posture)
			from = Vector3.new(from.X, Config.Layout.SurfaceY + 0.06, from.Z)
			local target = ServeRules.target(aim, power)
			local to = Vector3.new(target.X, Config.Layout.SurfaceY + 0.06, target.Z)
			local L = (to - from).Magnitude
			local color = if aimLocked ~= nil then S.AimLockedColor else S.AimColor
			if L > 0.5 then
				aimLine.Size = Vector3.new(0.3, 0.06, L)
				aimLine.CFrame = CFrame.lookAt((from + to) / 2, to)
				aimLine.Color = color
				aimLine.Transparency = 0.45
			else
				aimLine.Transparency = 1
			end
			aimRing.CFrame = CFrame.new(to) * CFrame.Angles(0, 0, math.rad(90))
			aimRing.Color = color
			aimRing.Transparency = 0.35
		else
			aimLine.Transparency = 1
			aimRing.Transparency = 1
		end

		-- hint text
		local text, color = "", Color3.new(1, 1, 1)
		if os.clock() < refusedUntil then
			text, color = refusedText, S.RegionBadColor
		elseif showRegion then
			if ok then
				local which = if posture == "LeftLead" then "left hip forward (forehand)" else "right hip forward (backhand)"
				text, color = "Your serve: " .. which .. ". Q: switch stance. Aim with the mouse, Space to toss", S.RegionColor
			else
				text, color = "Can't serve from here: " .. why, S.RegionBadColor
			end
		elseif tossInAir and not aimLocked then
			text, color = "Click and hold to lock the aim, then flick the mouse to strike (speed = power, direction = spin)", S.AimColor
		elseif tossInAir and aimLocked then
			text, color = "Flick now!", S.AimLockedColor
		end
		label.Text, label.TextColor3 = text, color
	end)

	player.CharacterAdded:Connect(function()
		tossing, holding, aimLocked, lockedPosture = false, false, nil, nil
		strikeAt = -math.huge
		if handle then
			handle:stop()
		end
		handle, handleCharacter = nil, nil
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		-- nothing to cancel locally: a started toss resolves on the server (a dropped toss is a fault)
	end)
end

return ServeInput
