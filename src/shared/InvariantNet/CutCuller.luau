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

export type CutFilter = {
	activeZones: { [Types.ZoneId]: boolean },
	maxDistanceSq: number,
	originX: number,
	originY: number,
	originZ: number,
}

export type CutCullerModule = {
	new: (
		activeZones: { [Types.ZoneId]: boolean },
		maxDistance: number,
		originX: number,
		originY: number,
		originZ: number
	) -> CutFilter,
	setOrigin: (filter: CutFilter, originX: number, originY: number, originZ: number) -> (),
	setMaxDistance: (filter: CutFilter, maxDistance: number) -> (),
	accepts: (filter: CutFilter, zoneId: Types.ZoneId, x: number, y: number, z: number) -> boolean,
}

local CutCuller: CutCullerModule = {} :: CutCullerModule

function CutCuller.new(
	activeZones: { [Types.ZoneId]: boolean },
	maxDistance: number,
	originX: number,
	originY: number,
	originZ: number
): CutFilter
	assert(maxDistance >= 0, "maxDistance must be non-negative")
	return {
		activeZones = activeZones,
		maxDistanceSq = maxDistance * maxDistance,
		originX = originX,
		originY = originY,
		originZ = originZ,
	}
end

function CutCuller.setOrigin(filter: CutFilter, originX: number, originY: number, originZ: number): ()
	filter.originX = originX
	filter.originY = originY
	filter.originZ = originZ
end

function CutCuller.setMaxDistance(filter: CutFilter, maxDistance: number): ()
	assert(maxDistance >= 0, "maxDistance must be non-negative")
	filter.maxDistanceSq = maxDistance * maxDistance
end

function CutCuller.accepts(
	filter: CutFilter,
	zoneId: Types.ZoneId,
	x: number,
	y: number,
	z: number
): boolean
	if not filter.activeZones[zoneId] then
		return false
	end

	local dx = x - filter.originX
	local dy = y - filter.originY
	local dz = z - filter.originZ
	local distSq = dx * dx + dy * dy + dz * dz
	return distSq <= filter.maxDistanceSq
end

return CutCuller
