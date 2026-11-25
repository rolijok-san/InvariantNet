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

local Types = require(script.Parent.Types)

export type BatchSample = {
	entityId: Types.EntityId,
	zoneId: Types.ZoneId,
	quotientClass: Types.QuotientClassId,
	x: number,
	y: number,
	z: number,
}

export type FrameBatcherModule = {
	new: (initialCapacity: number?) -> FrameBatcher,
	push: (
		self: FrameBatcher,
		entityId: Types.EntityId,
		zoneId: Types.ZoneId,
		quotientClass: Types.QuotientClassId,
		x: number,
		y: number,
		z: number
	) -> boolean,
	getCount: (self: FrameBatcher) -> number,
	getSoA: (self: FrameBatcher) -> Types.SoAEntityBuffer,
	clear: (self: FrameBatcher) -> (),
	reset: (self: FrameBatcher) -> (),
}

export type FrameBatcher = {
	push: (
		self: FrameBatcher,
		entityId: Types.EntityId,
		zoneId: Types.ZoneId,
		quotientClass: Types.QuotientClassId,
		x: number,
		y: number,
		z: number
	) -> boolean,
	getCount: (self: FrameBatcher) -> number,
	getSoA: (self: FrameBatcher) -> Types.SoAEntityBuffer,
	clear: (self: FrameBatcher) -> (),
	reset: (self: FrameBatcher) -> (),
}

local DEFAULT_CAPACITY: number = 256
local MAX_CAPACITY: number = 4194304

local FrameBatcherImpl = {}
FrameBatcherImpl.__index = FrameBatcherImpl

function FrameBatcherImpl.new(initialCapacity: number?): FrameBatcher
	local cap: number = math.floor(initialCapacity or DEFAULT_CAPACITY)
	assert(cap >= 0 and cap <= MAX_CAPACITY, "initialCapacity must be an integer in [0, 4194304]")

	local count: number = 0
	local slotByEntity: { [Types.EntityId]: number } = {}
	local entityIds: { Types.EntityId } = table.create(cap, 0)
	local zoneIds: { Types.ZoneId } = table.create(cap, 0)
	local quotientClasses: { Types.QuotientClassId } = table.create(cap, 0)
	local xs: { number } = table.create(cap, 0)
	local ys: { number } = table.create(cap, 0)
	local zs: { number } = table.create(cap, 0)

	local soaView: Types.SoAEntityBuffer = {
		count = 0,
		entityIds = entityIds,
		zoneIds = zoneIds,
		quotientClasses = quotientClasses,
		xs = xs,
		ys = ys,
		zs = zs,
	}

	local self = setmetatable({}, FrameBatcherImpl) :: any

	function self:push(
		entityId: Types.EntityId,
		zoneId: Types.ZoneId,
		quotientClass: Types.QuotientClassId,
		x: number,
		y: number,
		z: number
	): boolean
		local existingSlot = slotByEntity[entityId]
		if existingSlot ~= nil then
			zoneIds[existingSlot] = zoneId
			quotientClasses[existingSlot] = quotientClass
			xs[existingSlot] = x
			ys[existingSlot] = y
			zs[existingSlot] = z
			return false
		end

		local slot = count + 1
		slotByEntity[entityId] = slot
		count = slot
		entityIds[slot] = entityId
		zoneIds[slot] = zoneId
		quotientClasses[slot] = quotientClass
		xs[slot] = x
		ys[slot] = y
		zs[slot] = z
		soaView.count = slot
		return true
	end

	function self:getCount(): number
		return count
	end

	function self:getSoA(): Types.SoAEntityBuffer
		soaView.count = count
		return soaView
	end

	function self:clear(): ()
		for i = 1, count do
			slotByEntity[entityIds[i]] = nil
		end
		count = 0
		soaView.count = 0
	end

	function self:reset(): ()
		table.clear(slotByEntity)
		table.clear(entityIds)
		table.clear(zoneIds)
		table.clear(quotientClasses)
		table.clear(xs)
		table.clear(ys)
		table.clear(zs)
		count = 0
		soaView.count = 0
	end

	return self :: FrameBatcher
end

return (FrameBatcherImpl :: any) :: FrameBatcherModule
