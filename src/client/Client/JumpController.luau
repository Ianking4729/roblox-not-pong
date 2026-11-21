-- JumpController (client; Config.Movement.Jump, 2026-11-19 Pass 12): a moderate, quicker ordinary jump for the LOCAL
-- character without touching workspace.Gravity or the ball physics. While the character is airborne (Jumping /
-- Freefall) one VectorForce on its root adds the extra downward acceleration that gives Height studs at the apex over
-- AirTime seconds (g = 8 h / T^2); the take-off speed is the Humanoid's JumpPower set by the server (MovementService,
-- v = 4 h / T). The local client owns its character's physics, so the force takes effect there and the replicated
-- position (which the server's reach checks use) follows it. Off the ground only; nothing is created per frame.
--
-- ONE JUMP PER GROUNDED CYCLE (Pass 15). Measured root cause of the mid-air second jump: on this x3.37 rig the Humanoid's
-- floor sensor reports a floor (FloorMaterial set, states Landed -> Running) whenever the root is within ~16 studs of the
-- ground, i.e. through the whole 6-stud jump. With Space held, the default control script keeps setting Humanoid.Jump, so
-- every false "landing" re-launched the character (measured: 3 launches in 0.9 s of holding). This controller now owns
-- jump gating: it never trusts the Humanoid's floor state. GROUNDED = a downward raycast from the root finds the floor
-- within GroundTolerance of the rest height AND the root is not rising. Anything else (a jump, a walk off a ledge, a false
-- "landing") latches the character as AIRBORNE: the Jumping state is disabled and Jump is forced false until it is truly
-- grounded again AND the jump input has been released (a fresh press is required). The smash hop (StancePose) is a visual
-- offset, not a jump, and Space during your own serve is sunk by ServeInput before it reaches the Humanoid.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local JumpController = {}

function JumpController.start(player: Player)
	local J = Config.Movement.Jump
	if not J or not J.Enabled then
		return
	end
	local force: VectorForce? = nil
	local humanoid: Humanoid? = nil
	local root: BasePart? = nil
	local latched = false -- airborne (or still holding the input since): no jump may start
	local grounded = true
	local jumpStateOn = true
	local heldAt = -math.huge -- last time a jump input was seen
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.RespectCanCollide = true -- (the ball visual and other non-colliding parts are not floors)
	local OFFSETS = { Vector3.zero, Vector3.new(1.5, 0, 0), Vector3.new(-1.5, 0, 0), Vector3.new(0, 0, 1.5), Vector3.new(0, 0, -1.5) }
	local stats = { jumps = 0, blocked = 0, maxRise = 0, lastAir = 0, startY = nil :: number?, airSince = nil :: number? }

	local function setup(character: Model)
		-- (a respawn starts clean: input history cleared, and LATCHED so a Space still held from the old life cannot jump the
		-- new character; it unlatches on the first frame the input is released)
		latched, grounded, jumpStateOn, heldAt = true, true, true, -math.huge
		rayParams.FilterDescendantsInstances = { character }
		humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
		if not humanoid or not root then
			return
		end
		local a = Instance.new("Attachment")
		a.Name = "NotPongJumpAttachment"
		a.Parent = root
		local f = Instance.new("VectorForce")
		f.Name = "NotPongJumpGravity"
		f.Attachment0 = a
		f.RelativeTo = Enum.ActuatorRelativeTo.World
		f.ApplyAtCenterOfMass = true
		f.Force = Vector3.zero
		f.Enabled = false
		f.Parent = root
		force = f
		humanoid.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping or new == Enum.HumanoidStateType.Freefall then
				-- (the extra gravity from the take-off itself, not a frame later: the apex then matches Height)
				local f, r = force, root
				if f and r then
					local g = 8 * J.Height / math.max(J.AirTime, 0.1) ^ 2
					f.Force = Vector3.new(0, -r.AssemblyMass * math.max(g - workspace.Gravity, 0), 0)
					f.Enabled = true
				end
			end
			if new == Enum.HumanoidStateType.Jumping and J.CutJumpHold ~= false then
				-- measured: the Humanoid's Jumping state HOLDS the take-off speed (~0.12 s, gravity cancelled) before
				-- Freefall, which added ~7 studs to the apex; one frame after take-off it becomes Freefall so the
				-- character's gravity acts on the whole arc (the take-off speed itself is unchanged)
				task.delay(0, function()
					local hh = humanoid
					if hh and hh:GetState() == Enum.HumanoidStateType.Jumping then
						hh:ChangeState(Enum.HumanoidStateType.Freefall)
					end
				end)
			end
			if new == Enum.HumanoidStateType.Jumping then
				stats.jumps += 1
				stats.startY = root and root.Position.Y or nil
				stats.airSince = os.clock()
				stats.maxRise = 0
			elseif (new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running) and stats.airSince then
				stats.lastAir = os.clock() - stats.airSince
				stats.airSince = nil
			end
		end)
	end
	player.CharacterAdded:Connect(function(character)
		force, humanoid, root = nil, nil, nil
		setup(character)
	end)
	if player.Character then
		task.spawn(setup, player.Character)
	end

	-- distance from the root to the floor beneath it minus the rest height (nil = no floor in reach)
	local function floorGap(h: Humanoid, r: BasePart): number?
		local rest = h.HipHeight + r.Size.Y / 2
		local best: number? = nil
		local origin = r.CFrame
		for _, o in OFFSETS do
			local hit = workspace:Raycast(origin.Position + origin:VectorToWorldSpace(o), Vector3.new(0, -(rest + (J.GroundReach or 8)), 0), rayParams)
			if hit then
				local g = hit.Distance - rest
				if not best or g < best then
					best = g
				end
			end
		end
		return best
	end

	-- JUMP GATE: runs right before the physics step, after the control script wrote this frame's Jump
	RunService.PreSimulation:Connect(function()
		local h, r = humanoid, root
		if not h or not r or not h.Parent or not r.Parent then
			return
		end
		-- "still held": any jump input seen within HeldGrace seconds (Humanoid.Jump is rewritten by the control script every
		-- frame and was measured to read false on alternate frames while Space is held; the key / button state is exact)
		local now = os.clock()
		if h.Jump or UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA) then
			heldAt = now
		end
		local held = now - heldAt < (J.HeldGrace or 0.08)
		stats.held = held
		local gap = floorGap(h, r)
		grounded = gap ~= nil and gap <= (J.GroundTolerance or 0.8) and r.AssemblyLinearVelocity.Y < (J.MaxRiseGrounded or 12)
		if not grounded then
			latched = true
		elseif latched and not held then
			latched = false -- landed AND released: the next press is a fresh jump
		end
		if latched then
			if h.Jump then
				stats.blocked += 1
				h.Jump = false
			end
			if jumpStateOn then
				jumpStateOn = false
				h:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
			end
		elseif not jumpStateOn then
			jumpStateOn = true
			h:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end
	end)

	RunService.Heartbeat:Connect(function()
		local f, h, r = force, humanoid, root
		if not f or not h or not r or not f.Parent then
			return
		end
		-- airborne by the RAYCAST (the Humanoid's own states report a false floor through the jump; see the header)
		local air = not grounded
		if air then
			local g = 8 * J.Height / math.max(J.AirTime, 0.1) ^ 2
			local extra = math.max(g - workspace.Gravity, 0)
			f.Force = Vector3.new(0, -r.AssemblyMass * extra, 0)
			if stats.startY then
				stats.maxRise = math.max(stats.maxRise, r.Position.Y - stats.startY)
			end
		end
		if f.Enabled ~= air then
			f.Enabled = air
		end
	end)

	if Config.ShotControl.ShowDiagnostics then
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongJumpDebug"
		bridge.OnInvoke = function()
			local h = humanoid
			return {
				jumps = stats.jumps,
				maxRise = stats.maxRise,
				lastAir = stats.lastAir,
				jumpPower = h and h.JumpPower or 0,
				useJumpPower = h and h.UseJumpPower or false,
				forceOn = force ~= nil and force.Enabled,
				latched = latched,
				grounded = grounded,
				blocked = stats.blocked,
				held = stats.held,
				gravity = workspace.Gravity,
				state = h and tostring(h:GetState()) or "none",
			}
		end
		bridge.Parent = player
	end
end

return JumpController
