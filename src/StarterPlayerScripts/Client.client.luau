--!strict
--!native
--[[
AUTHOR: CRIMOFD
REF: StarterPlayerScripts/InvariantNet/Client

Client runtime: receives and validates transport batches, keeps predicted entity state with dead reckoning (Linear, Ballistic, Orbit flows), reconciles against authoritative anchors with error blending and hard snaps, tracks zone volumes through CollectionService tags, culls entities outside the active cut, and exposes signals and a read API for gameplay code.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type FlowKind = "Linear" | "Ballistic" | "Orbit"

export type OrbitProfile = {
	center: Vector3,
	radius: number?,
	omega: number?,
	yBobAmp: number?,
	yBobFreq: number?,
	seed: number?,
	omegaRange: NumberRange?,
	radiusRange: NumberRange?,
}

export type FlowProfile = {
	kind: FlowKind,
	gravity: Vector3?,
	orbit: OrbitProfile?,
}

export type ClientEntityState = {
	entityId: number,
	zoneId: number,
	quotientClass: number,
	seq: number,
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	lastEpoch: number,
	lastDigest: number,
	flow: FlowKind,
	active: boolean,
	lastPacketTime: number,
	index: number,
	ax: number,
	ay: number,
	az: number,
	anchorTime: number,
	offX: number,
	offY: number,
	offZ: number,
	lastStepTime: number,
	nextZoneCheck: number,
	settled: boolean,
	hasVelocity: boolean,
	gx: number,
	gy: number,
	gz: number,
	profile: FlowProfile?,
	orbitCx: number,
	orbitCz: number,
	orbitRadius: number,
	orbitOmega: number,
	orbitPhase: number,
	orbitBobAmp: number,
	orbitBobFreq: number,
	orbitFixedOmega: boolean,
	orbitFixedRadius: boolean,
	orbitHasPhase: boolean,
	part: BasePart?,
	boundIndex: number,
}

export type ClientConfig = {
	cullRadius: number?,
	snapDistance: number?,
	blendTime: number?,
	maxExtrapolation: number?,
	velocitySmoothing: number?,
	epochHz: number?,
	maxEntities: number?,
	staleSeconds: number?,
	resyncCooldown: number?,
	maxEpochGap: number?,
	lodInterval: number?,
	stepEvent: ("PreRender" | "Heartbeat")?,
	zoneTag: string?,
	remoteTimeout: number?,
}

export type ClientStats = {
	received: number,
	accepted: number,
	rejected: number,
	stale: number,
	digestMismatches: number,
	acksSent: number,
	snaps: number,
	resyncs: number,
	created: number,
	removed: number,
	dropped: number,
}

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T> = {
	Connect: (self: Signal<T>, handler: (T) -> ()) -> Connection,
	Fire: (self: Signal<T>, value: T) -> (),
	DisconnectAll: (self: Signal<T>) -> (),
}

export type NetClient = {
	entityAdded: Signal<ClientEntityState>,
	entityRemoved: Signal<ClientEntityState>,
	stepped: Signal<number>,
	zoneChanged: Signal<number?>,
	resyncRequested: Signal<string>,
	getState: (self: NetClient, entityId: number) -> ClientEntityState?,
	getPosition: (self: NetClient, entityId: number) -> Vector3?,
	getVelocity: (self: NetClient, entityId: number) -> Vector3?,
	getList: (self: NetClient) -> ({ ClientEntityState }, number),
	getCount: (self: NetClient) -> number,
	registerFlow: (self: NetClient, classId: number, profile: FlowProfile) -> (),
	bind: (self: NetClient, entityId: number, part: BasePart) -> BasePart?,
	unbind: (self: NetClient, entityId: number) -> (),
	removeEntity: (self: NetClient, entityId: number) -> (),
	requestResync: (self: NetClient, reason: string?) -> (),
	setCullRadius: (self: NetClient, radius: number) -> (),
	getActiveZones: (self: NetClient) -> { [number]: boolean },
	getPlayerZone: (self: NetClient) -> number?,
	getSyncInfo: (self: NetClient) -> (number, number),
	getStats: (self: NetClient) -> ClientStats,
	destroy: (self: NetClient) -> (),
}

local REMOTES_FOLDER_NAME: string = "InvariantNetRemotes"
local RELIABLE_REMOTE_NAME: string = "InvariantNetReliable"
local UNRELIABLE_REMOTE_NAME: string = "InvariantNetUnreliable"

local EPOCH_MODULUS: number = 8388608
local DEFAULT_ZONE: number = 1
local RECORD_BYTES: number = 20
local HEADER_BYTES: number = 16
local MAX_PACKET_BYTES: number = HEADER_BYTES + 16_384 * RECORD_BYTES
local MIN_VELOCITY_DT: number = 0.02
local ZONE_RECHECK_SECONDS: number = 0.5
local ZONE_POLL_SECONDS: number = 0.25
local EPOCH_RESET_SECONDS: number = 3
local SETTLE_VELOCITY_SQ: number = 1e-6
local SETTLE_OFFSET_SQ: number = 1e-6
local IS_STUDIO: boolean = RunService:IsStudio()

local function waitForBounded(parent: Instance, name: string, timeout: number, destroyedFlag: () -> boolean): Instance?
	if destroyedFlag() or timeout <= 0 then
		return nil
	end
	local deadline = os.clock() + timeout
	while not destroyedFlag() do
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			return nil
		end
		local found = parent:WaitForChild(name, math.min(remaining, 1))
		if found ~= nil then
			return found
		end
	end
	return nil
end

local rootInstance = waitForBounded(ReplicatedStorage, "InvariantNet", 15, function()
	return false
end)
assert(rootInstance ~= nil and rootInstance:IsA("ModuleScript"), "InvariantNet client requires ReplicatedStorage.InvariantNet")

local InvariantNet = require(rootInstance) :: any
local Packet = InvariantNet.Packet
local CutCuller = InvariantNet.CutCuller
local PartitionGraph = InvariantNet.PartitionGraph
local TrajectoryFlow = InvariantNet.Predictor.TrajectoryFlow
local SeedStream = InvariantNet.Predictor.SeedStream

local function epochDelta(newer: number, older: number): number
	local d = (newer - older) % EPOCH_MODULUS
	if d >= EPOCH_MODULUS / 2 then
		d -= EPOCH_MODULUS
	end
	return d
end

local function newSignal<T>(): Signal<T>
	type Slot = { fn: (T) -> (), conn: Connection }
	local slots: { Slot } = {}
	local firing = false
	local dirty = false
	local self = {} :: any

	local function compact()
		for i = #slots, 1, -1 do
			if not slots[i].conn.Connected then
				table.remove(slots, i)
			end
		end
		dirty = false
	end

	function self:Connect(handler: (T) -> ()): Connection
		local conn: Connection = {
			Connected = true,
			Disconnect = function(c: Connection)
				if not c.Connected then
					return
				end
				c.Connected = false
				if firing then
					dirty = true
				else
					compact()
				end
			end,
		}
		table.insert(slots, { fn = handler, conn = conn })
		return conn
	end

	function self:Fire(value: T): ()
		local n = #slots
		if n == 0 then
			return
		end
		local wasFiring = firing
		firing = true
		for i = 1, n do
			local slot = slots[i]
			if slot ~= nil and slot.conn.Connected then
				local ok, err = pcall(slot.fn, value)
				if not ok and IS_STUDIO then
					warn("[InvariantNet Client] handler error:", err)
				end
			end
		end
		firing = wasFiring
		if dirty and not firing then
			compact()
		end
	end

	function self:DisconnectAll(): ()
		for i = 1, #slots do
			slots[i].conn.Connected = false
		end
		table.clear(slots)
		dirty = false
	end

	return self :: Signal<T>
end

local outX: { number } = { 0 }
local outY: { number } = { 0 }
local outZ: { number } = { 0 }

local linearFlow = { x0 = 0, y0 = 0, z0 = 0, vx = 0, vy = 0, vz = 0 }
local ballisticFlow = { x0 = 0, y0 = 0, z0 = 0, vx = 0, vy = 0, vz = 0, gx = 0, gy = 0, gz = 0 }
local orbitFlow = { cx = 0, cy = 0, cz = 0, radius = 0, omega = 0, phase = 0, yBobAmp = 0, yBobFreq = 0 }

local function sample(s: ClientEntityState, t: number): ()
	local kind = s.flow
	if kind == "Ballistic" then
		local f = ballisticFlow
		f.x0, f.y0, f.z0 = s.ax, s.ay, s.az
		f.vx, f.vy, f.vz = s.vx, s.vy, s.vz
		f.gx, f.gy, f.gz = s.gx, s.gy, s.gz
		TrajectoryFlow.writeBallisticInto(f, t, outX, outY, outZ, 1)
	elseif kind == "Orbit" then
		local f = orbitFlow
		f.cx, f.cy, f.cz = s.orbitCx, s.ay, s.orbitCz
		f.radius = s.orbitRadius
		f.omega = s.orbitOmega
		f.phase = s.orbitPhase
		f.yBobAmp = s.orbitBobAmp
		f.yBobFreq = s.orbitBobFreq
		TrajectoryFlow.writeOrbitInto(f, t, outX, outY, outZ, 1)
	else
		local f = linearFlow
		f.x0, f.y0, f.z0 = s.ax, s.ay, s.az
		f.vx, f.vy, f.vz = s.vx, s.vy, s.vz
		TrajectoryFlow.writeLinearInto(f, t, outX, outY, outZ, 1)
	end
end

local Client = {}
local instance: NetClient? = nil

function Client.new(config: ClientConfig?): NetClient
	local cfg: ClientConfig = config or {}
	local localPlayer = Players.LocalPlayer :: Player

	local cullRadius: number = cfg.cullRadius or 650
	local snapDistance: number = cfg.snapDistance or 24
	local snapSq: number = snapDistance * snapDistance
	local blendTime: number = math.max(1e-3, cfg.blendTime or 0.12)
	local maxExtrapolation: number = cfg.maxExtrapolation or 0.75
	local velocitySmoothing: number = math.clamp(cfg.velocitySmoothing or 0.6, 0.01, 1)
	local epochHz: number = cfg.epochHz or 0
	local maxEntities: number = cfg.maxEntities or 8192
	local staleSeconds: number = cfg.staleSeconds or 30
	local resyncCooldown: number = cfg.resyncCooldown or 3
	local maxEpochGap: number = cfg.maxEpochGap or 600
	local lodInterval: number = cfg.lodInterval or 0.1
	local zoneTag: string = cfg.zoneTag or "InvariantNetZone"
	local stepEventName: string = cfg.stepEvent or "PreRender"
	local remoteTimeout: number = math.max(1, cfg.remoteTimeout or 30)

	local states: { [number]: ClientEntityState } = {}
	local list: { ClientEntityState } = {}
	local count = 0
	local boundList: { ClientEntityState } = {}
	local boundCount = 0
	local pendingBindings: { [number]: BasePart } = {}
	local flowProfiles: { [number]: FlowProfile } = {}
	local entitySeqCounter: { [number]: number } = {}

	local activeZones: { [number]: boolean } = { [DEFAULT_ZONE] = true }
	local cutFilter = CutCuller.new(activeZones, cullRadius, 0, 0, 0)
	local graph = PartitionGraph.new()

	type ZoneVolume = { part: BasePart, zoneId: number }
	local volumes: { ZoneVolume } = {}
	local playerZone: number? = nil
	local zonesInitialized = false
	local nextZonePoll = 0

	local lastEpochSeen = 0
	local lastDigestSeen = 0
	local hasEpoch = false
	local lastAcceptTime = 0
	local lastResyncTime = -math.huge
	local resyncQueued: string? = nil
	local ackPendingEpoch: number? = nil
	local ackPendingDigest: number = 0
	local nextSweep = 0
	local warnedCap = false

	local stats: ClientStats = {
		received = 0,
		accepted = 0,
		rejected = 0,
		stale = 0,
		digestMismatches = 0,
		acksSent = 0,
		snaps = 0,
		resyncs = 0,
		created = 0,
		removed = 0,
		dropped = 0,
	}

	local rootPart: BasePart? = nil
	local lastOX, lastOY, lastOZ = 0, 0, 0

	local reliableRemote: RemoteEvent? = nil
	local connections: { RBXScriptConnection } = {}
	local destroyed = false
	local teardownEpoch = 0

	local function isDestroyed(): boolean
		return destroyed
	end

	local function track(conn: RBXScriptConnection): RBXScriptConnection
		if destroyed then
			conn:Disconnect()
			return conn
		end
		table.insert(connections, conn)
		if destroyed then
			conn:Disconnect()
		end
		return conn
	end

	local scratchBatch = Packet.newDecodedBatch(256)
	local bulkParts: { Instance } = {}
	local bulkCFrames: { CFrame } = {}

	local entityAdded = newSignal() :: Signal<ClientEntityState>
	local entityRemoved = newSignal() :: Signal<ClientEntityState>
	local stepped = newSignal() :: Signal<number>
	local zoneChanged = newSignal() :: Signal<number?>
	local resyncRequested = newSignal() :: Signal<string>

	local self = {} :: any
	self.entityAdded = entityAdded
	self.entityRemoved = entityRemoved
	self.stepped = stepped
	self.zoneChanged = zoneChanged
	self.resyncRequested = resyncRequested

	local function flushAck(): ()
		if destroyed or ackPendingEpoch == nil then
			return
		end
		local remote = reliableRemote
		if remote == nil then
			return
		end
		local epoch = ackPendingEpoch :: number
		local digest = ackPendingDigest
		ackPendingEpoch = nil
		stats.acksSent += 1
		remote:FireServer(Packet.encodeControl(Packet.CONTROL_ACK, epoch, digest))
	end

	local function queueAck(epoch: number, digest: number): ()
		ackPendingEpoch = epoch
		ackPendingDigest = digest
		flushAck()
	end

	local function sendResync(reason: string): ()
		if destroyed then
			return
		end
		local remote = reliableRemote
		if remote == nil then
			resyncQueued = reason
			return
		end
		lastResyncTime = os.clock()
		stats.resyncs += 1
		remote:FireServer(Packet.encodeControl(Packet.CONTROL_RESYNC, lastEpochSeen, lastDigestSeen))
		resyncRequested:Fire(reason)
	end

	local function requestResync(reason: string): ()
		if destroyed or os.clock() - lastResyncTime < resyncCooldown then
			return
		end
		sendResync(reason)
	end

	local function zoneAt(x: number, y: number, z: number): number?
		local p = Vector3.new(x, y, z)
		for i = 1, #volumes do
			local v = volumes[i]
			local lp = v.part.CFrame:PointToObjectSpace(p)
			local h = v.part.Size * 0.5
			if math.abs(lp.X) <= h.X and math.abs(lp.Y) <= h.Y and math.abs(lp.Z) <= h.Z then
				return v.zoneId
			end
		end
		return nil
	end

	local function addVolume(inst: Instance): ()
		if destroyed or not inst:IsA("BasePart") then
			return
		end
		local zid = inst:GetAttribute("ZoneId")
		if typeof(zid) ~= "number" then
			if IS_STUDIO then
				warn(("[InvariantNet Client] zone volume %s has no numeric ZoneId attribute"):format(inst:GetFullName()))
			end
			return
		end
		table.insert(volumes, { part = inst, zoneId = zid })
		local adj = inst:GetAttribute("Adjacent")
		if typeof(adj) == "string" then
			for token in string.gmatch(adj, "%d+") do
				local other = tonumber(token)
				if other ~= nil then
					graph:connectZones(zid, other)
				end
			end
		end
		zonesInitialized = false
	end

	local function removeVolume(inst: Instance): ()
		for i = #volumes, 1, -1 do
			if volumes[i].part == inst then
				table.remove(volumes, i)
			end
		end
		zonesInitialized = false
	end

	local function refreshZones(now: number, ox: number, oy: number, oz: number): ()
		if now < nextZonePoll then
			return
		end
		nextZonePoll = now + ZONE_POLL_SECONDS

		if #volumes == 0 then
			activeZones[DEFAULT_ZONE] = true
			return
		end

		local zone = zoneAt(ox, oy, oz)
		if zonesInitialized and zone == playerZone then
			return
		end
		zonesInitialized = true
		playerZone = zone

		table.clear(activeZones)
		activeZones[DEFAULT_ZONE] = true
		if zone == nil then
			for i = 1, #volumes do
				activeZones[volumes[i].zoneId] = true
			end
		else
			activeZones[zone] = true
			local adj = graph:getAdjacentZones(zone)
			for i = 1, #adj do
				activeZones[adj[i]] = true
			end
		end
		zoneChanged:Fire(zone)
	end

	local function readOrigin(): (number, number, number)
		local root = rootPart
		if root ~= nil and root.Parent ~= nil then
			local pos = root.Position
			lastOX, lastOY, lastOZ = pos.X, pos.Y, pos.Z
			return lastOX, lastOY, lastOZ
		end
		local cam = workspace.CurrentCamera
		if cam ~= nil then
			local pos = cam.CFrame.Position
			lastOX, lastOY, lastOZ = pos.X, pos.Y, pos.Z
			return lastOX, lastOY, lastOZ
		end
		return lastOX, lastOY, lastOZ
	end

	local function applyProfile(s: ClientEntityState, profile: FlowProfile?): ()
		s.profile = profile
		s.flow = if profile ~= nil then profile.kind else "Linear"

		local g = if profile ~= nil and profile.gravity ~= nil
			then profile.gravity
			else Vector3.new(0, -workspace.Gravity, 0)
		s.gx, s.gy, s.gz = g.X, g.Y, g.Z

		s.orbitFixedOmega = false
		s.orbitFixedRadius = false
		local ob = if profile ~= nil then profile.orbit else nil
		if s.flow == "Orbit" and ob ~= nil then
			s.orbitCx, s.orbitCz = ob.center.X, ob.center.Z
			s.orbitBobAmp = ob.yBobAmp or 0
			s.orbitBobFreq = ob.yBobFreq or 0
			local seed = ob.seed
			if seed ~= nil then
				local wr = ob.omegaRange
				if wr ~= nil then
					s.orbitOmega = SeedStream.rangeFloat(SeedStream.atStepLane(seed, s.entityId, 0, 0), wr.Min, wr.Max)
					s.orbitFixedOmega = true
				end
				local rr = ob.radiusRange
				if rr ~= nil then
					s.orbitRadius = SeedStream.rangeFloat(SeedStream.atStepLane(seed, s.entityId, 0, 1), rr.Min, rr.Max)
					s.orbitFixedRadius = true
				end
			end
			if ob.omega ~= nil then
				s.orbitOmega = ob.omega
				s.orbitFixedOmega = true
			end
			if ob.radius ~= nil then
				s.orbitRadius = ob.radius
				s.orbitFixedRadius = true
			end
		end
		s.settled = false
	end

	local function orbitReanchor(s: ClientEntityState, x: number, z: number, dtA: number): ()
		local dx = x - s.orbitCx
		local dz = z - s.orbitCz
		local phase = math.atan2(dz, dx)
		if not s.orbitFixedOmega and s.orbitHasPhase and dtA >= MIN_VELOCITY_DT then
			local dth = (phase - s.orbitPhase + math.pi) % (2 * math.pi) - math.pi
			local est = dth / dtA
			s.orbitOmega += (est - s.orbitOmega) * velocitySmoothing
		end
		if not s.orbitFixedRadius then
			s.orbitRadius = math.sqrt(dx * dx + dz * dz)
		end
		s.orbitPhase = phase
		s.orbitHasPhase = true

		s.vx = -s.orbitRadius * s.orbitOmega * math.sin(phase)
		s.vz = s.orbitRadius * s.orbitOmega * math.cos(phase)
		s.vy = 0
	end

	local partOwners: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any

	local function detach(s: ClientEntityState): ()
		local bound = s.part
		if bound == nil then
			return
		end
		partOwners[bound] = nil
		local i = s.boundIndex
		local last = boundList[boundCount]
		boundList[i] = last
		if last ~= nil then
			last.boundIndex = i
		end
		boundList[boundCount] = nil :: any
		boundCount -= 1
		s.part = nil
		s.boundIndex = 0
	end

	local function attach(s: ClientEntityState, part: BasePart): BasePart?
		local previous = s.part
		if previous == part then
			return nil
		end
		if previous ~= nil then
			partOwners[previous] = nil
		else
			boundCount += 1
			boundList[boundCount] = s
			s.boundIndex = boundCount
		end
		s.part = part
		partOwners[part] = s.entityId
		return previous
	end

	local function removeEntityInternal(s: ClientEntityState): ()
		detach(s)
		local i = s.index
		local last = list[count]
		list[i] = last
		if last ~= nil then
			last.index = i
		end
		list[count] = nil :: any
		count -= 1
		states[s.entityId] = nil
		pendingBindings[s.entityId] = nil
		graph:removeEntity(s.entityId)
		stats.removed += 1
		entityRemoved:Fire(s)
	end

	local function createEntity(
		id: number,
		qClass: number,
		seq: number,
		x: number,
		y: number,
		z: number,
		now: number,
		epoch: number,
		digest: number
	): ClientEntityState
		local zone = if #volumes > 0 then (zoneAt(x, y, z) or DEFAULT_ZONE) else DEFAULT_ZONE
		local s: ClientEntityState = {
			entityId = id,
			zoneId = zone,
			quotientClass = qClass,
			seq = seq,
			x = x,
			y = y,
			z = z,
			vx = 0,
			vy = 0,
			vz = 0,
			lastEpoch = epoch,
			lastDigest = digest,
			flow = "Linear",
			active = true,
			lastPacketTime = now,
			index = 0,
			ax = x,
			ay = y,
			az = z,
			anchorTime = now,
			offX = 0,
			offY = 0,
			offZ = 0,
			lastStepTime = now,
			nextZoneCheck = now + ZONE_RECHECK_SECONDS,
			settled = true,
			hasVelocity = false,
			gx = 0,
			gy = -196.2,
			gz = 0,
			orbitCx = x,
			orbitCz = z,
			orbitRadius = 0,
			orbitOmega = 0,
			orbitPhase = 0,
			orbitBobAmp = 0,
			orbitBobFreq = 0,
			orbitFixedOmega = false,
			orbitFixedRadius = false,
			orbitHasPhase = false,
			boundIndex = 0,
		}
		applyProfile(s, flowProfiles[qClass])
		if s.flow == "Orbit" then
			orbitReanchor(s, x, z, 0)
		end

		count += 1
		list[count] = s
		s.index = count
		states[id] = s
		graph:setZone(id, zone)
		stats.created += 1

		local pending = pendingBindings[id]
		if pending ~= nil then
			pendingBindings[id] = nil
			attach(s, pending)
		end
		entityAdded:Fire(s)
		return s
	end

	local function updateEntity(
		s: ClientEntityState,
		qClass: number,
		seq: number,
		x: number,
		y: number,
		z: number,
		now: number,
		epoch: number,
		digest: number
	): ()
		if s.quotientClass ~= qClass then
			s.quotientClass = qClass
			applyProfile(s, flowProfiles[qClass])
		end

		local dtA = if epochHz > 0 then epochDelta(epoch, s.lastEpoch) / epochHz else now - s.anchorTime
		if dtA >= MIN_VELOCITY_DT then
			local ivx = (x - s.ax) / dtA
			local ivy = (y - s.ay) / dtA
			local ivz = (z - s.az) / dtA
			if s.flow == "Ballistic" then
				ivx += s.gx * dtA * 0.5
				ivy += s.gy * dtA * 0.5
				ivz += s.gz * dtA * 0.5
			end
			local k = if s.hasVelocity then velocitySmoothing else 1
			s.vx += (ivx - s.vx) * k
			s.vy += (ivy - s.vy) * k
			s.vz += (ivz - s.vz) * k
			s.hasVelocity = true
		end

		local ox, oy, oz = s.x - x, s.y - y, s.z - z
		local errSq = ox * ox + oy * oy + oz * oz
		if errSq > snapSq then
			stats.snaps += 1
			ox, oy, oz = 0, 0, 0
		elseif errSq < SETTLE_OFFSET_SQ then
			ox, oy, oz = 0, 0, 0
		end
		s.offX, s.offY, s.offZ = ox, oy, oz

		s.ax, s.ay, s.az = x, y, z
		s.anchorTime = now
		s.x, s.y, s.z = x + ox, y + oy, z + oz

		if s.flow == "Orbit" then
			orbitReanchor(s, x, z, dtA)
		end

		if #volumes > 0 and now >= s.nextZoneCheck then
			s.nextZoneCheck = now + ZONE_RECHECK_SECONDS
			local zone = zoneAt(x, y, z) or DEFAULT_ZONE
			if zone ~= s.zoneId then
				s.zoneId = zone
				graph:setZone(s.entityId, zone)
			end
		end

		s.seq = seq
		s.lastEpoch = epoch
		s.lastDigest = digest
		s.lastPacketTime = now
		s.lastStepTime = now
		s.settled = false
	end

	local function applyBatch(batch: any, now: number): ()
		if destroyed then
			return
		end
		local header = batch.header
		local epoch = header.epoch
		local digest = header.digest

		local computedDigest = Packet.computeBatchDigest(
			batch.count,
			batch.entityIds,
			batch.quotientClasses,
			batch.xs,
			batch.ys,
			batch.zs
		)
		if computedDigest ~= digest then
			stats.digestMismatches += 1
			stats.rejected += 1
			if IS_STUDIO then
				warn(("[InvariantNet Client] digest mismatch on epoch %d: expected %d, got %d"):format(epoch, digest, computedDigest))
			end
			requestResync("digest mismatch")
			return
		end

		local resyncReason: string? = nil
		local epochReset = false

		if hasEpoch then
			local d = epochDelta(epoch, lastEpochSeen)
			if d < 0 then
				if now - lastAcceptTime < EPOCH_RESET_SECONDS then
					stats.stale += 1
					return
				end
				epochReset = true
				resyncReason = "epoch reset"
			elseif d > maxEpochGap then
				resyncReason = "epoch gap"
			end
		end

		hasEpoch = true
		lastEpochSeen = epoch
		lastDigestSeen = digest
		lastAcceptTime = now
		stats.accepted += 1

		if epochReset then
			table.clear(entitySeqCounter)
			for i = 1, count do
				local s = list[i]
				s.seq = 0
				s.lastEpoch = epoch
				s.lastDigest = digest
				s.ax, s.ay, s.az = s.x, s.y, s.z
				s.anchorTime = now
				s.lastStepTime = now
				s.vx, s.vy, s.vz = 0, 0, 0
				s.offX, s.offY, s.offZ = 0, 0, 0
				s.hasVelocity = false
				s.orbitHasPhase = false
				if s.flow == "Orbit" then
					s.orbitPhase = math.atan2(s.z - s.orbitCz, s.x - s.orbitCx)
					if not s.orbitFixedOmega then
						s.orbitOmega = 0
					end
				end
				s.settled = false
			end
		end

		local ids = batch.entityIds
		local classes = batch.quotientClasses
		local xs, ys, zs = batch.xs, batch.ys, batch.zs
		for i = 1, batch.count do
			local id = ids[i]
			local nextSeq = (entitySeqCounter[id] or 0) + 1
			entitySeqCounter[id] = nextSeq

			local s = states[id]
			if s == nil then
				if count >= maxEntities then
					stats.dropped += 1
					if not warnedCap and IS_STUDIO then
						warnedCap = true
						warn(("[InvariantNet Client] entity cap (%d) reached, dropping new entities"):format(maxEntities))
					end
				else
					createEntity(id, classes[i], nextSeq, xs[i], ys[i], zs[i], now, epoch, digest)
				end
			elseif epochReset or nextSeq > s.seq then
				updateEntity(s, classes[i], nextSeq, xs[i], ys[i], zs[i], now, epoch, digest)
			else
				stats.stale += 1
			end
		end

		queueAck(epoch, digest)

		if resyncReason ~= nil then
			requestResync(resyncReason)
		end
	end

	local function onBufferReceived(pkt: unknown): ()
		if destroyed or typeof(pkt) ~= "buffer" then
			return
		end
		stats.received += 1
		local ok, err = Packet.decodeBatchInto(pkt, MAX_PACKET_BYTES, scratchBatch)
		if not ok then
			stats.rejected += 1
			if IS_STUDIO and err ~= nil then
				warn("[InvariantNet Client] Rejected batch:", err)
			end
			return
		end
		applyBatch(scratchBatch, os.clock())
	end

	local function advance(s: ClientEntityState, now: number, decay: number): ()
		s.lastStepTime = now
		if s.settled then
			return
		end

		local t = now - s.anchorTime
		local capped = false
		if s.flow ~= "Orbit" and t > maxExtrapolation then
			t = maxExtrapolation
			capped = true
		end
		if t < 0 then
			t = 0
		end
		sample(s, t)

		local ox, oy, oz = s.offX * decay, s.offY * decay, s.offZ * decay
		local offSq = ox * ox + oy * oy + oz * oz
		if offSq < SETTLE_OFFSET_SQ then
			ox, oy, oz = 0, 0, 0
			offSq = 0
		end
		s.offX, s.offY, s.offZ = ox, oy, oz
		s.x, s.y, s.z = outX[1] + ox, outY[1] + oy, outZ[1] + oz

		if offSq == 0 and s.flow ~= "Orbit" then
			local vSq = s.vx * s.vx + s.vy * s.vy + s.vz * s.vz
			if capped or (s.flow == "Linear" and vSq < SETTLE_VELOCITY_SQ) then
				s.settled = true
			end
		end
	end

	local function sweepStale(now: number): ()
		for i = count, 1, -1 do
			local s = list[i]
			if not s.active and now - s.lastPacketTime > staleSeconds then
				removeEntityInternal(s)
			end
		end
	end

	local function step(dt: number): ()
		if destroyed then
			return
		end
		local now = os.clock()
		local ox, oy, oz = readOrigin()
		CutCuller.setOrigin(cutFilter, ox, oy, oz)
		refreshZones(now, ox, oy, oz)

		local decay = math.exp(-dt / blendTime)
		for i = 1, count do
			local s = list[i]
			local live = CutCuller.accepts(cutFilter, s.zoneId, s.x, s.y, s.z)
			s.active = live
			if live then
				advance(s, now, decay)
			else
				local el = now - s.lastStepTime
				if el >= lodInterval then
					advance(s, now, math.exp(-el / blendTime))
				end
			end
		end

		if boundCount > 0 then
			local n = 0
			for i = 1, boundCount do
				local s = boundList[i]
				local part = s.part
				if part ~= nil and part.Parent ~= nil then
					n += 1
					bulkParts[n] = part
					bulkCFrames[n] = CFrame.new(s.x, s.y, s.z) * part.CFrame.Rotation
				end
			end
			for i = #bulkParts, n + 1, -1 do
				bulkParts[i] = nil :: any
				bulkCFrames[i] = nil :: any
			end
			if n > 0 then
				workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
			end
		end

		if now >= nextSweep then
			nextSweep = now + 1
			sweepStale(now)
		end

		stepped:Fire(dt)
	end

	function self:getState(entityId: number): ClientEntityState?
		return states[entityId]
	end

	function self:getPosition(entityId: number): Vector3?
		local s = states[entityId]
		if s == nil then
			return nil
		end
		return Vector3.new(s.x, s.y, s.z)
	end

	function self:getVelocity(entityId: number): Vector3?
		local s = states[entityId]
		if s == nil then
			return nil
		end
		return Vector3.new(s.vx, s.vy, s.vz)
	end

	function self:getList(): ({ ClientEntityState }, number)
		return list, count
	end

	function self:getCount(): number
		return count
	end

	function self:registerFlow(classId: number, profile: FlowProfile): ()
		if profile.kind == "Orbit" and profile.orbit == nil then
			warn(("[InvariantNet Client] registerFlow(%d): Orbit needs an orbit profile with a center"):format(classId))
			return
		end
		flowProfiles[classId] = profile
		for i = 1, count do
			local s = list[i]
			if s.quotientClass == classId then
				applyProfile(s, profile)
				if s.flow == "Orbit" then
					orbitReanchor(s, s.ax, s.az, 0)
				end
			end
		end
	end

	function self:bind(entityId: number, part: BasePart): BasePart?
		if destroyed then
			return nil
		end

		local owner = partOwners[part]
		if owner ~= nil and owner ~= entityId then
			if IS_STUDIO then
				warn(("[InvariantNet Client] %s was bound to entity %d, rebinding to %d"):format(part:GetFullName(), owner, entityId))
			end
			local ownerState = states[owner]
			if ownerState ~= nil then
				detach(ownerState)
			end
			if pendingBindings[owner] == part then
				pendingBindings[owner] = nil
			end
			partOwners[part] = nil
		end

		local s = states[entityId]
		if s ~= nil then
			local prevPending = pendingBindings[entityId]
			if prevPending ~= nil then
				pendingBindings[entityId] = nil
				if prevPending ~= part then
					partOwners[prevPending] = nil
				end
			end
			return attach(s, part)
		end

		local previous = pendingBindings[entityId]
		if previous == part then
			return nil
		end
		if previous ~= nil then
			partOwners[previous] = nil
		end
		pendingBindings[entityId] = part
		partOwners[part] = entityId
		return previous
	end

	function self:unbind(entityId: number): ()
		local pending = pendingBindings[entityId]
		if pending ~= nil then
			pendingBindings[entityId] = nil
			if partOwners[pending] == entityId then
				partOwners[pending] = nil
			end
		end
		local s = states[entityId]
		if s ~= nil then
			detach(s)
		end
	end

	function self:removeEntity(entityId: number): ()
		entitySeqCounter[entityId] = nil
		local s = states[entityId]
		if s ~= nil then
			removeEntityInternal(s)
		else
			local pending = pendingBindings[entityId]
			if pending ~= nil then
				pendingBindings[entityId] = nil
				if partOwners[pending] == entityId then
					partOwners[pending] = nil
				end
			end
		end
	end

	function self:requestResync(reason: string?): ()
		requestResync(reason or "manual")
	end

	function self:setCullRadius(radius: number): ()
		cullRadius = radius
		CutCuller.setMaxDistance(cutFilter, radius)
	end

	function self:getActiveZones(): { [number]: boolean }
		return activeZones
	end

	function self:getPlayerZone(): number?
		return playerZone
	end

	function self:getSyncInfo(): (number, number)
		return lastEpochSeen, lastDigestSeen
	end

	function self:getStats(): ClientStats
		return stats
	end

	function self:destroy(): ()
		if destroyed then
			return
		end
		destroyed = true
		teardownEpoch += 1
		reliableRemote = nil
		ackPendingEpoch = nil
		for i = 1, #connections do
			connections[i]:Disconnect()
		end
		table.clear(connections)
		entityAdded:DisconnectAll()
		entityRemoved:DisconnectAll()
		stepped:DisconnectAll()
		zoneChanged:DisconnectAll()
		resyncRequested:DisconnectAll()
		table.clear(states)
		table.clear(list)
		table.clear(boundList)
		table.clear(pendingBindings)
		table.clear(partOwners)
		table.clear(volumes)
		table.clear(entitySeqCounter)
		graph:clear()
		count = 0
		boundCount = 0
		if instance == (self :: any) then
			instance = nil
		end
	end

	local function onCharacter(char: Model): ()
		if destroyed then
			return
		end
		rootPart = nil
		local gen = teardownEpoch
		task.spawn(function()
			local hrp = char:WaitForChild("HumanoidRootPart", 10)
			if destroyed or teardownEpoch ~= gen or localPlayer.Character ~= char then
				return
			end
			if hrp ~= nil and hrp:IsA("BasePart") then
				rootPart = hrp
				requestResync("respawn")
			end
		end)
	end

	track(localPlayer.CharacterAdded:Connect(onCharacter))
	track(localPlayer.CharacterRemoving:Connect(function()
		rootPart = nil
	end))
	if localPlayer.Character ~= nil then
		onCharacter(localPlayer.Character)
	end

	for _, inst in CollectionService:GetTagged(zoneTag) do
		addVolume(inst)
	end
	track(CollectionService:GetInstanceAddedSignal(zoneTag):Connect(addVolume))
	track(CollectionService:GetInstanceRemovedSignal(zoneTag):Connect(removeVolume))

	if stepEventName == "Heartbeat" then
		track(RunService.Heartbeat:Connect(step))
	else
		track(RunService.PreRender:Connect(step))
	end

	local gen = teardownEpoch
	task.spawn(function()
		local folder = waitForBounded(rootInstance, REMOTES_FOLDER_NAME, math.min(15, remoteTimeout), isDestroyed)
		if folder == nil and not destroyed and teardownEpoch == gen then
			if IS_STUDIO then
				warn(
					"[InvariantNet Client] "
						.. REMOTES_FOLDER_NAME
						.. " not found after 15s. The server script must call require(...).new() (ServerImpl.new) to create the remotes."
				)
			end
			local remaining = remoteTimeout - 15
			if remaining > 0 then
				folder = waitForBounded(rootInstance, REMOTES_FOLDER_NAME, remaining, isDestroyed)
			end
		end

		local reliable = if folder ~= nil then waitForBounded(folder, RELIABLE_REMOTE_NAME, 10, isDestroyed) else nil
		local unreliable = if folder ~= nil then waitForBounded(folder, UNRELIABLE_REMOTE_NAME, 10, isDestroyed) else nil

		if destroyed or teardownEpoch ~= gen then
			return
		end
		if reliable == nil or unreliable == nil then
			if IS_STUDIO then
				warn(("[InvariantNet Client] remotes unavailable after %ds, transport disabled"):format(remoteTimeout))
			end
			return
		end

		if reliable:IsA("RemoteEvent") then
			reliableRemote = reliable
			track(reliable.OnClientEvent:Connect(onBufferReceived))
		end
		if unreliable:IsA("UnreliableRemoteEvent") then
			track(unreliable.OnClientEvent:Connect(onBufferReceived))
		end
		if destroyed or teardownEpoch ~= gen then
			return
		end

		flushAck()
		local queued = resyncQueued
		if queued ~= nil then
			resyncQueued = nil
			requestResync(queued)
		end
	end)

	return self :: NetClient
end

function Client.start(config: ClientConfig?): NetClient
	if instance ~= nil then
		return instance
	end
	local created = Client.new(config)
	instance = created
	return created
end

function Client.get(): NetClient
	return Client.start()
end

return Client