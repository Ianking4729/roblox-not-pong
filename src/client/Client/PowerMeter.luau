-- PowerMeter (client, cosmetic): the bottom-right "Power" and "Curve" bars.
--   Power fills from HOLD TIME only (the value comes from ShotController.power(), which ignores the mouse).
--   Curve shows the strength of the selected spin (0..MaxSpin).
-- Segmented bars, shown while charging and briefly after the release. All tunables: Config.Feedback.PowerMeter.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local PowerMeter = {}

local P = Config.Feedback.PowerMeter

function PowerMeter.new(screen: ScreenGui)
	local W = P.Width
	local panel = Instance.new("Frame")
	panel.Name = "PowerMeter"
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -24, 1, -110)
	panel.Size = UDim2.fromOffset(W + 96, 66)
	panel.BackgroundColor3 = Color3.fromRGB(22, 14, 40)
	panel.BackgroundTransparency = 0.3
	panel.Visible = false
	panel.Parent = screen
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 10)
	pc.Parent = panel
	local ps = Instance.new("UIStroke")
	ps.Color = Color3.fromRGB(190, 140, 255)
	ps.Transparency = 0.45
	ps.Thickness = 1.5
	ps.Parent = panel

	local function row(name: string, y: number, color: Color3)
		local l = Instance.new("TextLabel")
		l.Name = name .. "Label"
		l.BackgroundTransparency = 1
		l.Position = UDim2.fromOffset(12, y)
		l.Size = UDim2.fromOffset(70, 22)
		l.Font = Enum.Font.GothamBold
		l.TextSize = 16
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextColor3 = Color3.new(1, 1, 1)
		l.Text = name
		l.Parent = panel
		local track = Instance.new("Frame")
		track.Name = name .. "Track"
		track.Position = UDim2.fromOffset(82, y + 4)
		track.Size = UDim2.fromOffset(W, 14)
		track.BackgroundColor3 = Color3.fromRGB(10, 6, 22)
		track.BackgroundTransparency = 0.2
		track.ClipsDescendants = true
		track.Parent = panel
		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(0.5, 0)
		tc.Parent = track
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = color
		fill.BorderSizePixel = 0
		fill.Parent = track
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0.5, 0)
		fc.Parent = fill
		for i = 1, P.Segments - 1 do -- segment dividers
			local d = Instance.new("Frame")
			d.Size = UDim2.new(0, 2, 1, 0)
			d.Position = UDim2.fromScale(i / P.Segments, 0)
			d.AnchorPoint = Vector2.new(0.5, 0)
			d.BackgroundColor3 = Color3.fromRGB(10, 6, 22)
			d.BackgroundTransparency = 0.25
			d.BorderSizePixel = 0
			d.ZIndex = 3
			d.Parent = track
		end
		return fill
	end
	local powerFill = row("Power", 8, P.PowerColor)
	local curveFill = row("Curve", 36, P.CurveColor)

	local self = {}
	-- power, curve: 0..1
	function self.set(show: boolean, power: number, curve: number)
		panel.Visible = show
		if not show then
			return
		end
		power, curve = math.clamp(power, 0, 1), math.clamp(curve, 0, 1)
		powerFill.Size = UDim2.fromScale(power, 1)
		powerFill.BackgroundColor3 = if power >= 0.999 then P.FullColor else P.PowerColor
		curveFill.Size = UDim2.fromScale(curve, 1)
	end
	self.panel = panel
	self.powerFill = powerFill
	self.curveFill = curveFill
	return self
end

return PowerMeter
