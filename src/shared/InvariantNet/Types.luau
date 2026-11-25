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

export type EntityId = number
export type ZoneId = number
export type ClientId = number
export type QuotientClassId = number
export type EpochId = number
export type SubspaceId = number

export type ChannelKind = "Reliable" | "Unreliable"

export type Vec3Tuple = {
	x: number,
	y: number,
	z: number,
}

export type SoAEntityBuffer = {
	count: number,
	entityIds: { EntityId },
	zoneIds: { ZoneId },
	quotientClasses: { QuotientClassId },
	xs: { number },
	ys: { number },
	zs: { number },
}

export type InnovationMask = {
	words: buffer,
	wordCount: number,
	entityCapacity: number,
	activeCount: number,
}

export type PacketHeaderData = {
	version: number,
	epoch: EpochId,
	subspaceId: SubspaceId,
	reliable: boolean,
	digest: number,
	count: number,
}

export type DecodedFrameBatch = {
	header: PacketHeaderData,
	count: number,
	entityIds: { EntityId },
	quotientClasses: { QuotientClassId },
	xs: { number },
	ys: { number },
	zs: { number },
}

export type BoundaryCut = {
	activeZones: { [ZoneId]: boolean },
	maxDistanceSq: number,
	originX: number,
	originY: number,
	originZ: number,
}

export type ProjectionMetric = {
	observableNormSq: number,
	nullNormSq: number,
	shouldEmit: boolean,
}

export type FoldOutcome<TDelta> = {
	delta: TDelta,
	foldedCount: number,
	orderPreserved: boolean,
}

return {}