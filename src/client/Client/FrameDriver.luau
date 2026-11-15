-- FrameDriver (client): the one place per-frame visual work is registered. Every callback runs on the render loop
-- (BindToRenderStep) exactly as if bound directly. Development only (Config.ShotControl.ShowDiagnostics): a
-- BindableFunction "NotPongFrameDebug" lets Studio test scripts step the registered callbacks by hand, because a
-- Studio that is not in front has no render loop at all (RenderStepped never fires, the viewport is 1x1).
--   Invoke("step", dt, count)  runs every callback in priority order `count` times
--   Invoke("frames")           how many real render frames have run

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local FrameDriver = {}

local callbacks: { { name: string, priority: number, fn: (number) -> () } } = {}
local realFrames = 0

function FrameDriver.bind(name: string, priority: number, fn: (number) -> ())
	table.insert(callbacks, { name = name, priority = priority, fn = fn })
	table.sort(callbacks, function(a, b)
		return a.priority < b.priority
	end)
	RunService:BindToRenderStep(name, priority, function(dt)
		realFrames += 1
		fn(dt)
	end)
end

function FrameDriver.startDebugBridge(playerGui: Instance)
	if not Config.ShotControl.ShowDiagnostics then
		return
	end
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "NotPongFrameDebug"
	bridge.OnInvoke = function(cmd: string, dt: number?, count: number?)
		if cmd == "step" then
			for _ = 1, count or 1 do
				for _, c in callbacks do
					c.fn(dt or 1 / 60)
				end
			end
		elseif cmd == "frames" then
			return realFrames
		end
		return nil
	end
	bridge.Parent = playerGui
end

return FrameDriver
