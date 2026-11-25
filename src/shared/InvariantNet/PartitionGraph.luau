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

export type PartitionGraphModule = {
	new: () -> PartitionGraph,
	setZone: (self: PartitionGraph, entityId: Types.EntityId, zoneId: Types.ZoneId) -> (),
	removeEntity: (self: PartitionGraph, entityId: Types.EntityId) -> (),
	getZone: (self: PartitionGraph, entityId: Types.EntityId) -> Types.ZoneId?,
	getZoneEntities: (self: PartitionGraph, zoneId: Types.ZoneId) -> { Types.EntityId },
	connectZones: (self: PartitionGraph, zoneA: Types.ZoneId, zoneB: Types.ZoneId) -> (),
	disconnectZones: (self: PartitionGraph, zoneA: Types.ZoneId, zoneB: Types.ZoneId) -> (),
	areZonesAdjacent: (self: PartitionGraph, zoneA: Types.ZoneId, zoneB: Types.ZoneId) -> boolean,
	getAdjacentZones: (self: PartitionGraph, zoneId: Types.ZoneId) -> { Types.ZoneId },
	isOnBoundary: (self: PartitionGraph, entityId: Types.EntityId) -> boolean,
	clear: (self: PartitionGraph) -> (),
}

export type PartitionGraph = {
	setZone: (self: PartitionGraph, entityId: Types.EntityId, zoneId: Types.ZoneId) -> (),
	removeEntity: (self: PartitionGraph, entityId: Types.EntityId) -> (),
	getZone: (self: PartitionGraph, entityId: Types.EntityId) -> Types.ZoneId?,
	getZoneEntities: (self: PartitionGraph, zoneId: Types.ZoneId) -> { Types.EntityId },
	connectZones: (self: PartitionGraph, zoneA: Types.ZoneId, zoneB: Types.ZoneId) -> (),
	disconnectZones: (self: PartitionGraph, zoneA: Types.ZoneId, zoneB: Types.ZoneId) -> (),
	areZonesAdjacent: (self: PartitionGraph, zoneA: Types.ZoneId, zoneB: Types.ZoneId) -> boolean,
	getAdjacentZones: (self: PartitionGraph, zoneId: Types.ZoneId) -> { Types.ZoneId },
	isOnBoundary: (self: PartitionGraph, entityId: Types.EntityId) -> boolean,
	clear: (self: PartitionGraph) -> (),
}

local PartitionGraphImpl = {}
PartitionGraphImpl.__index = PartitionGraphImpl

local function removeFromList(list: { Types.EntityId }, entityId: Types.EntityId): ()
	local n = #list
	for i = 1, n do
		if list[i] == entityId then
			list[i] = list[n]
			list[n] = nil
			return
		end
	end
end

function PartitionGraphImpl.new(): PartitionGraph
	local entityToZone: { [Types.EntityId]: Types.ZoneId } = {}
	local zoneSets: { [Types.ZoneId]: { [Types.EntityId]: boolean } } = {}
	local zoneLists: { [Types.ZoneId]: { Types.EntityId } } = {}
	local adjacency: { [Types.ZoneId]: { [Types.ZoneId]: boolean } } = {}

	local self = setmetatable({}, PartitionGraphImpl) :: any

	function self:setZone(entityId: Types.EntityId, zoneId: Types.ZoneId): ()
		local prevZone = entityToZone[entityId]
		if prevZone == zoneId then
			return
		end

		if prevZone ~= nil then
			local prevSet = zoneSets[prevZone]
			if prevSet ~= nil then
				prevSet[entityId] = nil
			end
			local prevList = zoneLists[prevZone]
			if prevList ~= nil then
				removeFromList(prevList, entityId)
			end
		end

		entityToZone[entityId] = zoneId

		local nextSet = zoneSets[zoneId]
		if nextSet == nil then
			nextSet = {}
			zoneSets[zoneId] = nextSet
		end
		nextSet[entityId] = true

		local nextList = zoneLists[zoneId]
		if nextList == nil then
			nextList = {}
			zoneLists[zoneId] = nextList
		end
		table.insert(nextList, entityId)
	end

	function self:removeEntity(entityId: Types.EntityId): ()
		local zoneId = entityToZone[entityId]
		if zoneId == nil then
			return
		end
		entityToZone[entityId] = nil

		local zSet = zoneSets[zoneId]
		if zSet ~= nil then
			zSet[entityId] = nil
		end

		local zList = zoneLists[zoneId]
		if zList ~= nil then
			removeFromList(zList, entityId)
		end
	end

	function self:getZone(entityId: Types.EntityId): Types.ZoneId?
		return entityToZone[entityId]
	end

	function self:getZoneEntities(zoneId: Types.ZoneId): { Types.EntityId }
		return zoneLists[zoneId] or {}
	end

	function self:connectZones(zoneA: Types.ZoneId, zoneB: Types.ZoneId): ()
		if zoneA == zoneB then
			return
		end

		local adjA = adjacency[zoneA]
		if adjA == nil then
			adjA = {}
			adjacency[zoneA] = adjA
		end
		adjA[zoneB] = true

		local adjB = adjacency[zoneB]
		if adjB == nil then
			adjB = {}
			adjacency[zoneB] = adjB
		end
		adjB[zoneA] = true
	end

	function self:disconnectZones(zoneA: Types.ZoneId, zoneB: Types.ZoneId): ()
		local adjA = adjacency[zoneA]
		if adjA ~= nil then
			adjA[zoneB] = nil
		end
		local adjB = adjacency[zoneB]
		if adjB ~= nil then
			adjB[zoneA] = nil
		end
	end

	function self:areZonesAdjacent(zoneA: Types.ZoneId, zoneB: Types.ZoneId): boolean
		if zoneA == zoneB then
			return true
		end
		local adjA = adjacency[zoneA]
		return adjA ~= nil and adjA[zoneB] == true
	end

	function self:getAdjacentZones(zoneId: Types.ZoneId): { Types.ZoneId }
		local out: { Types.EntityId } = {}
		local adj = adjacency[zoneId]
		if adj ~= nil then
			for neighbor in pairs(adj) do
				table.insert(out, neighbor)
			end
		end
		return out
	end

	function self:isOnBoundary(entityId: Types.EntityId): boolean
		local zoneId = entityToZone[entityId]
		if zoneId == nil then
			return false
		end
		local adj = adjacency[zoneId]
		if adj == nil then
			return false
		end
		for neighbor in pairs(adj) do
			local nSet = zoneSets[neighbor]
			if nSet ~= nil and next(nSet) ~= nil then
				return true
			end
		end
		return false
	end

	function self:clear(): ()
		table.clear(entityToZone)
		table.clear(zoneSets)
		table.clear(zoneLists)
		table.clear(adjacency)
	end

	return self :: PartitionGraph
end

return (PartitionGraphImpl :: any) :: PartitionGraphModule