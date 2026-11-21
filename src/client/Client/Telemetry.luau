-- Telemetry (client, diagnosis only; Config.Telemetry): records what actually happens to every ball coming to the local
-- player, so rally difficulty can be diagnosed from REAL attempts instead of perfect scripted input. Changes nothing.
--
-- One outcome per incoming ball (the hit counter identifies it):
--   unreachable      never had a contact window from where you stood (positioning), no attempt
--   noAttempt        a window existed (the ring went green) but you never clicked
--   noFlick          you clicked, but no flick was recognised before the ball was gone / you released
--                    (logged with how close the hand came: peak speed, net distance, coherence vs the thresholds)
--   early / late / outOfReach   a recognised flick the server judged a miss for that reason
--   contactOk / contactNet / contactOut / contactOwn   the server accepted the contact; where the shot was predicted to
--                    land (ok = on the opponent's half)
--   save*            the same for emergency saves
-- Plus, per flick: recognition delay (hand starts -> flick recognised), flick start relative to the ring turning green,
-- speed / power / spin, the arm's stroke time; per ball: stroke changes and cursor travel while it approached.
-- Lines start with "[Tel]"; Player.NotPongTelemetry:Invoke("summary") returns the counters.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ShotInput = require(Shared:WaitForChild("ShotInput"))

local BallView = require(script.Parent:WaitForChild("BallView"))

local Telemetry = {}

local T, F, S = Config.Telemetry, Config.Flick, Config.ShotControl

local function fmt(n: any, d: number?): string
	if typeof(n) ~= "number" then
		return "-"
	end
	return string.format("%." .. tostring(d or 2) .. "f", n)
end

function Telemetry.start(player: Player, controller: any)
	if not T.Enabled then
		return
	end
	local counts: { [string]: number } = {}
	local attempts = 0
	local recog: { number } = {} -- recognition delays (s)
	local fromGreen: { number } = {} -- flick start minus ring-green start (s; negative = before green)
	local noFlickPeaks: { string } = {}

	local function out(line: string)
		if T.Print then
			print("[Tel] " .. line)
		end
	end
	local function bump(key: string)
		counts[key] = (counts[key] or 0) + 1
	end
	local function median(list: { number }): number?
		if #list == 0 then
			return nil
		end
		local c = table.clone(list)
		table.sort(c)
		return c[math.floor((#c + 1) / 2)]
	end
	local function summary(): { [string]: any }
		return {
			balls = counts.balls or 0,
			outcomes = table.clone(counts),
			attempts = attempts,
			recognitionDelayMedian = median(recog),
			flickFromGreenMedian = median(fromGreen),
			flickFromGreenSamples = table.clone(fromGreen),
			noFlickPeaks = table.clone(noFlickPeaks),
		}
	end
	local function printSummary()
		local s = summary()
		local parts = {}
		for k, v in s.outcomes do
			table.insert(parts, k .. "=" .. v)
		end
		table.sort(parts)
		out(("SUMMARY %s | recognition delay median %s s | flick start vs green median %s s"):format(
			table.concat(parts, " "), fmt(s.recognitionDelayMedian, 3), fmt(s.flickFromGreenMedian, 3)))
	end

	-- ---------- per incoming ball ----------
	local ball: any = nil -- { hits, t0, reachable, emergencyOnly, greenAt, greenFrames, committed, flicked, strokeChanges,
	--                        aim0, profile0, outcome, holdDuringGreen }
	local function finishBall(why: string)
		local b = ball
		ball = nil
		if not b or b.outcome then
			return
		end
		local outcome
		if b.flicked then
			return -- (resolved by the swing / result path)
		elseif b.committed then
			outcome = "noFlick"
		elseif b.greenAt then
			outcome = "noAttempt"
		elseif b.reachable then
			outcome = "noAttemptNeverGreen" -- a window existed but it never became flickable before the ball left
		else
			outcome = "unreachable"
		end
		bump(outcome)
		out(("BALL %d %s (%s) | reachable %s%s, green %s for %s s, committed %s, stroke changes %d, aim %s->%s, profile %s->%s"):format(
			b.hits, outcome, why, tostring(b.reachable), if b.emergencyOnly then " (save ring only)" else "",
			tostring(b.greenAt ~= nil), fmt(b.greenFrames * (1 / 60), 2), tostring(b.committed), b.strokeChanges,
			fmt(b.aim0), fmt(controller.aim), fmt(b.profile0), fmt(controller.profile)))
	end

	RunService.Heartbeat:Connect(function()
		local info = BallView.getInfo()
		local incoming = BallView.getState() ~= nil and info.mode == "free" and info.incoming and not info.serve
		if ball and (not incoming or info.hits ~= ball.hits) then
			finishBall(if info.mode == "held" or info.mode == "hand" then "point over" else "ball gone")
		end
		if incoming and not ball and info.hits ~= controller.swungHits then
			ball = {
				hits = info.hits,
				t0 = os.clock(),
				reachable = false,
				emergencyOnly = false,
				greenAt = nil,
				greenFrames = 0,
				committed = false,
				flicked = false,
				strokeChanges = 0,
				aim0 = controller.aim,
				profile0 = controller.profile,
			}
			bump("balls")
		end
		local b = ball
		if b then
			local w = controller.window
			local ow = controller.outerWindow
			local win = w or ow
			if win and not win.cleanStart then
				b.reachable = true
				b.emergencyOnly = w == nil
				local now = workspace:GetServerTimeNow()
				if ShotInput.classify(now + F.ContactDelay, win) ~= "miss" then
					b.greenAt = b.greenAt or os.clock()
					b.greenFrames += 1
					if controller.state == "COMMITTED" then
						b.holdDuringGreen = true
					end
				end
			end
		end
	end)

	controller.on(function(event: string, data: any)
		local b = ball
		if event == "stroke" and b and not data.locked then
			b.strokeChanges += 1
		elseif event == "strokeSelect" then
			bump(if data.queued then "qQueued" else "qSelect")
		elseif event == "commit" then
			if data.serve then
				return
			end
			if b then
				b.committed = true
			end
			out(("COMMIT%s stroke %s aim %s profile %s cursor (%s, %s) ball incoming %s"):format(
				if data.mouseOnly then " (mouse-only: preparation from before the flick)" else "",
				data.stroke, fmt(data.aim), fmt(data.profile), fmt(data.fx), fmt(data.fy), tostring(data.incoming)))
		elseif event == "cancel" or event == "reset" then
			local g = controller.lastGesture
			if not g or g.serving or g.logged then
				return
			end
			g.logged = true
			local st = g.stats or {}
			local F2 = F
			-- which recognition condition the best moment missed
			local missing = {}
			if (st.maxNet or 0) < F2.OnsetDistance then
				table.insert(missing, ("distance %s<%d"):format(fmt(st.maxNet, 0), F2.OnsetDistance))
			end
			if (st.maxSpeed or 0) < F2.OnsetSpeed then
				table.insert(missing, ("speed %s<%d"):format(fmt(st.maxSpeed, 0), F2.OnsetSpeed))
			end
			if (st.coherenceAtMax or 0) < F2.Coherence and (st.maxNet or 0) >= F2.OnsetDistance then
				table.insert(missing, ("coherence %s<%s"):format(fmt(st.coherenceAtMax), fmt(F2.Coherence)))
			end
			local tried = (st.maxSpeed or 0) >= F2.OnsetSpeed * 0.5 or (st.maxNet or 0) >= F2.OnsetDistance * 0.5
			local peak = ("peak speed %s px/s, net %s px, coherence %s, %d move events (%d jitter), detector %s"):format(
				fmt(st.maxSpeed, 0), fmt(st.maxNet, 0), fmt(st.coherenceAtMax), st.events or 0, st.jitterEvents or 0, tostring(g.state))
			out(("NOFLICK (%s) held %s s | %s | %s | green during hold %s"):format(
				tostring(g.why), fmt(g.hold), if tried then "LOOKED LIKE A FLICK ATTEMPT, missing: " .. (if #missing > 0 then table.concat(missing, ", ") else "segment invalid") else "hand mostly still",
				peak, tostring(b and b.holdDuringGreen or false)))
			if tried then
				table.insert(noFlickPeaks, peak)
				bump("noFlickTried")
			end
		elseif event == "swing" then
			if data.serve then
				return
			end
			attempts += 1
			if b then
				b.flicked = true
				b.outcome = "pending"
			end
			local fl = data.flick
			local rec = fl and (fl.endT - fl.startT) or nil
			if rec then
				table.insert(recog, rec)
			end
			local g = nil
			if fl and b and b.greenAt then
				g = fl.startT - b.greenAt
			elseif fl and data.window then
				-- green had not started yet: how long before it would start (contact lower bound - ContactDelay)
				local w = data.window
				local half = S.ContactWindowDuration / 2
				local lo = math.max(w.enter, w.ideal - half - S.EarlyReleaseTolerance) - F.ContactDelay
				g = (workspace:GetServerTimeNow() - (os.clock() - fl.startT)) - lo
			end
			if g then
				table.insert(fromGreen, g)
			end
			out(("FLICK %s predicted %s (%s) offset %s | speed %s px/s power %s spin top %s side %s dir (%s,%s) | hand started -> recognised %s s (detect %s) | start vs green %s s | held %s s before"):format(
				data.stroke, tostring(data.quality), tostring(data.reason), fmt(data.offset, 3), fmt(fl and fl.speed, 0), fmt(data.power),
				fmt(data.topspin, 0), fmt(data.sidespin, 0), fmt(fl and fl.dirX), fmt(fl and fl.dirY), fmt(rec, 3),
				fmt(fl and (fl.detectT - fl.startT), 3), fmt(g, 3), fmt(data.hold)))
			if data.noBall then
				bump("flickNoBall")
				if b then
					b.outcome = "flickNoBall"
				end
			end
			task.defer(function()
				local a = controller.lastArmSolve
				if a then
					out(("ARM stroke time %s s, blade-to-ball %s studs"):format(fmt(a.toContact, 3), fmt(a.error)))
				end
			end)
		elseif event == "result" then
			local m = data.msg
			if not m or m.serve then
				return
			end
			local key
			local r = string.lower(data.reason or "")
			local save = m.kind == "emergency"
			if data.result == "clean" or data.result == "weak" then
				local land = m.land or "?"
				key = (if save then "save" else "contact") .. string.upper(string.sub(land, 1, 1)) .. string.sub(land, 2)
				if m.risingHit then
					bump("risingHit") -- (accepted contact the old falling-ball rule would have refused; counted in addition)
				end
			elseif data.result == "rejected" then
				key = "rejected"
			elseif string.find(r, "early") then
				key = if m.risingBlocked then "earlyRisingBall" else "early"
			elseif string.find(r, "late") then
				key = "late"
			else
				key = "outOfReach"
			end
			if save and not string.find(key, "^save") then
				key = "save" .. string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
			end
			bump(key)
			if ball then
				ball.outcome = key
			end
			out(("RESULT %s -> %s (%s) offset %s lag %s | window rel. contact [%s, %s, %s] | rising-rule gap %s s%s | land %s depth %s lateral %s"):format(
				key, tostring(data.result), tostring(data.reason), fmt(m.offset, 3), fmt(m.lag, 3),
				fmt(m.window and m.window.enter, 3), fmt(m.window and m.window.ideal, 3), fmt(m.window and m.window.exit, 3),
				fmt(m.risingGap, 3), if m.risingBlocked then " (ball was in reach but still RISING)" elseif m.risingHit then " (hit while RISING: the old rule would have refused it)" else "",
				tostring(m.land), fmt(m.landDepth, 1), fmt(m.landLateral, 1)))
			-- TIMING (2026-11-18): every stage relative to the hand starting the flick (s): first deliberate movement after the
			-- press, onset recognised, finalised (request sent), first stroke frame, paddle at contact, the judged contact
			-- moment, the server's reply, and when the ball's new flight became visible (predicted locally / server).
			local tr = controller.trace
			if tr and tr.start then task.delay(0.3, function() -- (the server's snapshot may land just after its reply)
				local a = controller.lastArmSolve or {}
				local hit = BallView.hitDebug()
				local function rel(x: any): string
					return if typeof(x) == "number" then fmt(x - tr.start, 3) else "-"
				end
				out(("TIMING first move %s | onset %s | finalised %s | stroke starts %s%s | paddle at contact %s | judged contact %s | server reply %s | ball response %s (predicted) / %s (server)%s"):format(
					rel(tr.firstMove), rel(tr.onset), rel(tr.final), rel(a.startedAt), if a.fromOnset then " (at onset)" else "",
					rel(a.contactAt), rel(tr.contactClock), rel(tr.reply), rel(hit.predictedAt), rel(hit.serverAt),
					if hit.cancelledAt then " cancelled " .. rel(hit.cancelledAt) else ""))
			end) end
			if attempts % T.SummaryEvery == 0 then
				printSummary()
			end
		end
	end)

	local bridge = Instance.new("BindableFunction")
	bridge.Name = "NotPongTelemetry"
	bridge.OnInvoke = function(cmd: string?)
		if cmd == "print" then
			printSummary()
		elseif cmd == "reset" then
			table.clear(counts)
			table.clear(recog)
			table.clear(fromGreen)
			table.clear(noFlickPeaks)
			attempts = 0
		end
		return summary()
	end
	bridge.Parent = player
	out(("telemetry on (diagnosis only), rally input %s"):format(tostring(controller.rallyInput)))
end

return Telemetry
