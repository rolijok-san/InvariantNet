--!strict
--!native
--[[
AUTHOR: CRIMOFD 
██╗███╗   ██╗██╗   ██╗ █████╗ ██████╗ ██╗ █████╗ ███╗   ██╗████████╗███╗   ██╗███████╗████████╗
██║████╗  ██║██║   ██║██╔══██╗██╔══██╗██║██╔══██╗████╗  ██║╚══██╔══╝████╗  ██║██╔════╝╚══██╔══╝
██║██╔██╗ ██║██║   ██║███████║██████╔╝██║███████║██╔██╗ ██║   ██║   ██╔██╗ ██║█████╗     ██║   
██║██║╚██╗██║╚██╗ ██╔╝██╔══██║██╔══██╗██║██╔══██║██║╚██╗██║   ██║   ██║╚██╗██║██╔══╝     ██║   
██║██║ ╚████║ ╚████╔╝ ██║  ██║██║  ██║██║██║  ██║██║ ╚████║   ██║   ██║ ╚████║███████╗   ██║   
╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝   ╚═╝  ╚═══╝╚══════╝   ╚═╝   
 ]]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InvariantNetRoot = (ReplicatedStorage:WaitForChild("InvariantNet") :: any) :: Folder

local SmartHeader = require(ReplicatedStorage.InvariantNet.SmartHeader)
local Packet = require(ReplicatedStorage.InvariantNet.Packet)
local ChannelRouter = require(ReplicatedStorage.InvariantNet.ChannelRouter)
local PartitionGraph = require(ReplicatedStorage.InvariantNet.PartitionGraph)
local CutCuller = require(ReplicatedStorage.InvariantNet.CutCuller)
local FrameBatcher = require(ReplicatedStorage.InvariantNet.FrameBatcher)
local Predictor = require(ReplicatedStorage.InvariantNet.Predictor)
local SubspaceProjector = require(ReplicatedStorage.InvariantNet.Predictor.SubspaceProjector)
local QuotientMonoid = require(ReplicatedStorage.InvariantNet.QuotientMonoid)

export type EntityId = number
export type ZoneId = number
export type QuotientClassId = number
export type ChannelKind = "Reliable" | "Unreliable"
export type DecodedBatch = any
export type SubspaceConfig = any
export type CutFilter = any
export type PartitionGraphType = any
export type FrameBatcherType = any
export type RouterType = any
export type QuotientMonoidType<TState, TDelta> = any

export type EntityStateSample = {
	entityId: EntityId,
	zoneId: ZoneId,
	quotientClass: QuotientClassId,
	x: number,
	y: number,
	z: number,
}

export type EntityStateDelta = {
	dx: number,
	dy: number,
	dz: number,
	zoneId: ZoneId?,
	quotientClass: QuotientClassId?,
	nonCommutative: boolean?,
}

export type ServerConfig = {
	folderName: string?,
	reliableRemoteName: string?,
	unreliableRemoteName: string?,
	maxInboundBytesPerWindow: number?,
	windowSeconds: number?,
	maxPacketBytes: number?,
	batchCapacity: number?,
	epoch: number?,
	subspaceId: number?,
	channel: ChannelKind?,
	defaultTolerance: number?,
	defaultQuantStep: number?,
	requireCommutativeFold: boolean?,
	monoid: QuotientMonoidType<EntityStateSample, EntityStateDelta>?,
	onInboundBatch: ((player: Player, batch: DecodedBatch) -> ())?,
	onRejectedInbound: ((player: Player, reason: string) -> ())?,
}

export type NetServerInstance = {
	graph: PartitionGraphType,
	batcher: FrameBatcherType,
	router: RouterType,
	monoid: QuotientMonoidType<EntityStateSample, EntityStateDelta>,
	reliableRemote: RemoteEvent,
	unreliableRemote: UnreliableRemoteEvent,
	setEpoch: (self: NetServerInstance, epoch: number) -> (),
	setSubspace: (self: NetServerInstance, subspaceId: number) -> (),
	setChannel: (self: NetServerInstance, channel: ChannelKind) -> (),
	setEntityState: (
		self: NetServerInstance,
		entityId: EntityId,
		zoneId: ZoneId,
		quotientClass: QuotientClassId,
		x: number,
		y: number,
		z: number,
		predX: number?,
		predY: number?,
		predZ: number?,
		subspaceCfg: SubspaceConfig?,
		forceEmit: boolean?
	) -> boolean,
	enqueueDelta: (self: NetServerInstance, entityId: EntityId, delta: EntityStateDelta) -> (),
	commitEntityDeltas: (
		self: NetServerInstance,
		entityId: EntityId,
		predX: number?,
		predY: number?,
		predZ: number?,
		subspaceCfg: SubspaceConfig?,
		forceEmit: boolean?
	) -> boolean,
	commitAllDeltas: (
		self: NetServerInstance,
		subspaceCfg: SubspaceConfig?,
		forceEmit: boolean?
	) -> number,
	removeEntity: (self: NetServerInstance, entityId: EntityId) -> (),
	flushToPlayer: (self: NetServerInstance, player: Player, filter: CutFilter?) -> boolean,
	flushBroadcast: (self: NetServerInstance, exclude: Player?) -> (),
	clearBatch: (self: NetServerInstance) -> (),
	destroy: (self: NetServerInstance) -> (),
}

export type ServerModule = {
	new: (config: ServerConfig?) -> NetServerInstance,
}

local DEFAULT_FOLDER_NAME: string = "InvariantNetRemotes"
local DEFAULT_RELIABLE_NAME: string = "InvariantNetReliable"
local DEFAULT_UNRELIABLE_NAME: string = "InvariantNetUnreliable"

local IDENTITY_DELTA: EntityStateDelta = {
	dx = 0,
	dy = 0,
	dz = 0,
	zoneId = nil,
	quotientClass = nil,
	nonCommutative = false,
}

local DEFAULT_MONOID: QuotientMonoidType<EntityStateSample, EntityStateDelta> = QuotientMonoid.new(
	IDENTITY_DELTA,
	function(state: EntityStateSample): QuotientClassId
		return state.quotientClass
	end,
	function(a: EntityStateDelta, b: EntityStateDelta): EntityStateDelta
		local ordered = (a.nonCommutative == true) or (b.nonCommutative == true)
		return {
			dx = a.dx + b.dx,
			dy = a.dy + b.dy,
			dz = a.dz + b.dz,
			zoneId = if b.zoneId ~= nil then b.zoneId else a.zoneId,
			quotientClass = if b.quotientClass ~= nil then b.quotientClass else a.quotientClass,
			nonCommutative = ordered,
		}
	end,
	function(state: EntityStateSample, delta: EntityStateDelta): EntityStateSample
		return {
			entityId = state.entityId,
			zoneId = if delta.zoneId ~= nil then delta.zoneId else state.zoneId,
			quotientClass = if delta.quotientClass ~= nil then delta.quotientClass else state.quotientClass,
			x = state.x + delta.dx,
			y = state.y + delta.dy,
			z = state.z + delta.dz,
		}
	end,
	function(a: EntityStateSample, b: EntityStateSample): boolean
		return a.zoneId == b.zoneId
			and a.quotientClass == b.quotientClass
			and math.abs(a.x - b.x) < 1e-6
			and math.abs(a.y - b.y) < 1e-6
			and math.abs(a.z - b.z) < 1e-6
	end
)

local ServerImpl = {}
ServerImpl.__index = ServerImpl

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function getOrCreateReliable(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function getOrCreateUnreliable(parent: Instance, name: string): UnreliableRemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("UnreliableRemoteEvent") then
		return existing
	end
	local remote = Instance.new("UnreliableRemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

function ServerImpl.new(config: ServerConfig?): NetServerInstance
	assert(RunService:IsServer(), "InvariantNet.Server can only be created on the server")

	local cfg: ServerConfig = config or {}
	local container = getOrCreateFolder(InvariantNetRoot, cfg.folderName or DEFAULT_FOLDER_NAME)
	local reliableRemote = getOrCreateReliable(container, cfg.reliableRemoteName or DEFAULT_RELIABLE_NAME)
	local unreliableRemote = getOrCreateUnreliable(container, cfg.unreliableRemoteName or DEFAULT_UNRELIABLE_NAME)

	local graph = PartitionGraph.new()
	local batcher = FrameBatcher.new(cfg.batchCapacity)
	local monoid = cfg.monoid or DEFAULT_MONOID
	local requireCommutative = cfg.requireCommutativeFold ~= false

	local router = ChannelRouter.new({
		reliableRemote = reliableRemote,
		unreliableRemote = unreliableRemote,
		maxInboundBytesPerWindow = cfg.maxInboundBytesPerWindow,
		windowSeconds = cfg.windowSeconds,
		maxPacketBytes = cfg.maxPacketBytes,
	})

	local defaultCfg = SubspaceProjector.newConfig(
		true,
		true,
		true,
		cfg.defaultTolerance or 0.05,
		cfg.defaultQuantStep
	)

	local currentEpoch: number = cfg.epoch or 0
	local currentSubspace: number = cfg.subspaceId or 0
	local currentChannel: ChannelKind = cfg.channel or "Unreliable"
	local rollingDigest: number = 0

	local lastPublishedX: { [EntityId]: number } = {}
	local lastPublishedY: { [EntityId]: number } = {}
	local lastPublishedZ: { [EntityId]: number } = {}
	local currentSamples: { [EntityId]: EntityStateSample } = {}
	local pendingDeltas: { [EntityId]: { EntityStateDelta } } = {}

	local filteredIds: { number } = {}
	local filteredClasses: { number } = {}
	local filteredXs: { number } = {}
	local filteredYs: { number } = {}
	local filteredZs: { number } = {}

	local connections: { RBXScriptConnection } = {}

	local function handleInbound(player: Player, pkt: unknown): ()
		if typeof(pkt) ~= "buffer" then
			if cfg.onRejectedInbound then
				cfg.onRejectedInbound(player, "expected buffer")
			end
			return
		end

		local decoded, err = router:decodeInbound(player, pkt)
		if decoded == nil then
			if cfg.onRejectedInbound then
				cfg.onRejectedInbound(player, err or "invalid packet")
			end
			return
		end

		if cfg.onInboundBatch then
			cfg.onInboundBatch(player, decoded)
		end
	end

	table.insert(connections, reliableRemote.OnServerEvent:Connect(function(player: Player, pkt: unknown)
		handleInbound(player, pkt)
	end))

	table.insert(connections, unreliableRemote.OnServerEvent:Connect(function(player: Player, pkt: unknown)
		handleInbound(player, pkt)
	end))

	table.insert(connections, Players.PlayerRemoving:Connect(function(player: Player)
		router:cleanupPlayer(player)
	end))

	local self = setmetatable({}, ServerImpl) :: any
	self.graph = graph
	self.batcher = batcher
	self.router = router
	self.monoid = monoid
	self.reliableRemote = reliableRemote
	self.unreliableRemote = unreliableRemote

	function self:setEpoch(epoch: number): ()
		currentEpoch = epoch
	end

	function self:setSubspace(subspaceId: number): ()
		currentSubspace = subspaceId
	end

	function self:setChannel(channel: ChannelKind): ()
		currentChannel = channel
	end

	function self:setEntityState(
		entityId: EntityId,
		zoneId: ZoneId,
		quotientClass: QuotientClassId,
		x: number,
		y: number,
		z: number,
		predX: number?,
		predY: number?,
		predZ: number?,
		subspaceCfg: SubspaceConfig?,
		forceEmit: boolean?
	): boolean
		graph:setZone(entityId, zoneId)

		local sample: EntityStateSample = {
			entityId = entityId,
			zoneId = zoneId,
			quotientClass = quotientClass,
			x = x,
			y = y,
			z = z,
		}
		currentSamples[entityId] = sample
		local resolvedClass = QuotientMonoid.quotientClass(monoid, sample)

		local px = predX
		local py = predY
		local pz = predZ
		if px == nil or py == nil or pz == nil then
			local fallback = Predictor.predictLinear(x, y, z, 0, 0, 0, 0)
			px = px or fallback.x
			py = py or fallback.y
			pz = pz or fallback.z
		end

		local activeCfg = subspaceCfg or defaultCfg
		local emit = forceEmit == true
			or SubspaceProjector.shouldEmitResidual(activeCfg, x, y, z, px :: number, py :: number, pz :: number)

		if not emit then
			return false
		end

		local projected = SubspaceProjector.projectVec3(activeCfg, x, y, z)
		lastPublishedX[entityId] = projected.x
		lastPublishedY[entityId] = projected.y
		lastPublishedZ[entityId] = projected.z

		batcher:push(entityId, zoneId, resolvedClass, projected.x, projected.y, projected.z)

		local payloadHash = bit32.bxor(
			bit32.band(entityId, 0xFFFFFFFF),
			bit32.lrotate(bit32.band(resolvedClass, 0xFFFFFFFF), 11)
		)
		rollingDigest = SmartHeader.stepDigest(rollingDigest, entityId, payloadHash)
		return true
	end

	function self:enqueueDelta(entityId: EntityId, delta: EntityStateDelta): ()
		local queue = pendingDeltas[entityId]
		if queue == nil then
			queue = {}
			pendingDeltas[entityId] = queue
		end
		table.insert(queue, delta)
	end

	function self:commitEntityDeltas(
		entityId: EntityId,
		predX: number?,
		predY: number?,
		predZ: number?,
		subspaceCfg: SubspaceConfig?,
		forceEmit: boolean?
	): boolean
		local queue = pendingDeltas[entityId]
		if queue == nil or #queue == 0 then
			return false
		end

		local base = currentSamples[entityId]
			or {
				entityId = entityId,
				zoneId = 1,
				quotientClass = 0,
				x = lastPublishedX[entityId] or 0,
				y = lastPublishedY[entityId] or 0,
				z = lastPublishedZ[entityId] or 0,
			}

		local outcome = QuotientMonoid.foldWithOutcome(monoid, base, queue, requireCommutative)
		table.clear(queue)

		local nextState = monoid.apply(base, outcome.delta)
		return self:setEntityState(
			entityId,
			nextState.zoneId,
			nextState.quotientClass,
			nextState.x,
			nextState.y,
			nextState.z,
			predX,
			predY,
			predZ,
			subspaceCfg,
			forceEmit
		)
	end

	function self:commitAllDeltas(
		subspaceCfg: SubspaceConfig?,
		forceEmit: boolean?
	): number
		local committed = 0
		for entityId, queue in pendingDeltas do
			if #queue > 0 then
				if self:commitEntityDeltas(entityId, nil, nil, nil, subspaceCfg, forceEmit) then
					committed += 1
				end
			end
		end
		return committed
	end

	function self:removeEntity(entityId: EntityId): ()
		graph:removeEntity(entityId)
		lastPublishedX[entityId] = nil
		lastPublishedY[entityId] = nil
		lastPublishedZ[entityId] = nil
		currentSamples[entityId] = nil
		pendingDeltas[entityId] = nil
	end

	function self:flushToPlayer(player: Player, filter: CutFilter?): boolean
		local soa = batcher:getSoA()
		local total = soa.count
		if total == 0 then
			return false
		end

		local outCount = 0
		if filter == nil then
			outCount = total
			for i = 1, total do
				filteredIds[i] = soa.entityIds[i]
				filteredClasses[i] = soa.quotientClasses[i]
				filteredXs[i] = soa.xs[i]
				filteredYs[i] = soa.ys[i]
				filteredZs[i] = soa.zs[i]
			end
		else
			for i = 1, total do
				local zoneId = soa.zoneIds[i]
				local x = soa.xs[i]
				local y = soa.ys[i]
				local z = soa.zs[i]
				if CutCuller.accepts(filter, zoneId, x, y, z) then
					outCount += 1
					filteredIds[outCount] = soa.entityIds[i]
					filteredClasses[outCount] = soa.quotientClasses[i]
					filteredXs[outCount] = x
					filteredYs[outCount] = y
					filteredZs[outCount] = z
				end
			end
		end

		if outCount == 0 then
			return false
		end

		local pkt = Packet.encodeBatch(
			currentEpoch,
			currentSubspace,
			currentChannel,
			rollingDigest,
			outCount,
			filteredIds,
			filteredClasses,
			filteredXs,
			filteredYs,
			filteredZs
		)
		return router:sendToPlayer(player, currentChannel, pkt)
	end

	function self:flushBroadcast(exclude: Player?): ()
		local soa = batcher:getSoA()
		local total = soa.count
		if total == 0 then
			return
		end

		for i = 1, total do
			filteredIds[i] = soa.entityIds[i]
			filteredClasses[i] = soa.quotientClasses[i]
			filteredXs[i] = soa.xs[i]
			filteredYs[i] = soa.ys[i]
			filteredZs[i] = soa.zs[i]
		end

		local pkt = Packet.encodeBatch(
			currentEpoch,
			currentSubspace,
			currentChannel,
			rollingDigest,
			total,
			filteredIds,
			filteredClasses,
			filteredXs,
			filteredYs,
			filteredZs
		)
		router:broadcast(currentChannel, pkt, exclude)
	end

	function self:clearBatch(): ()
		batcher:clear()
	end

	function self:destroy(): ()
		for i = 1, #connections do
			connections[i]:Disconnect()
		end
		table.clear(connections)
		router:destroy()
		batcher:reset()
		graph:clear()
		table.clear(lastPublishedX)
		table.clear(lastPublishedY)
		table.clear(lastPublishedZ)
		table.clear(currentSamples)
		table.clear(pendingDeltas)
	end

	return self :: NetServerInstance
end

return (ServerImpl :: any) :: ServerModule