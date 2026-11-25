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

local SmartHeader = require(script.Parent.SmartHeader)
local Types = require(script.Parent.Types)

local HEADER_BYTES: number = SmartHeader.BYTE_SIZE
local RECORD_BYTES: number = 20
local CONTROL_BYTES: number = 12
local CONTROL_MAGIC: number = 0x4354524C
local CONTROL_ACK: number = 1
local CONTROL_RESYNC: number = 2
local CONTROL_EPOCH_MASK: number = 0x7FFFFF
local MAX_RECORDS_PER_PACKET: number = 16_384

export type DecodedBatch = {
	header: SmartHeader.HeaderFields,
	count: number,
	entityIds: { number },
	quotientClasses: { number },
	xs: { number },
	ys: { number },
	zs: { number },
}

export type ControlFrame = {
	kind: number,
	epoch: number,
	digest: number,
}

export type PacketModule = {
	RECORD_BYTES: number,
	HEADER_BYTES: number,
	CONTROL_BYTES: number,
	CONTROL_ACK: number,
	CONTROL_RESYNC: number,
	computeBatchDigest: (
		count: number,
		entityIds: { number },
		quotientClasses: { number },
		xs: { number },
		ys: { number },
		zs: { number }
	) -> number,
	encodeBatch: (
		epoch: number,
		subspaceId: number,
		channel: Types.ChannelKind,
		digest: number,
		count: number,
		entityIds: { number },
		quotientClasses: { number },
		xs: { number },
		ys: { number },
		zs: { number }
	) -> buffer,
	encodeControl: (kind: number, epoch: number, digest: number) -> buffer,
	decodeControl: (pkt: buffer) -> ControlFrame?,
	decodeBatch: (pkt: buffer, maxAllowedBytes: number?) -> (DecodedBatch?, string?),
	decodeBatchInto: (pkt: buffer, maxAllowedBytes: number?, out: DecodedBatch) -> (boolean, string?),
	newDecodedBatch: (capacity: number?) -> DecodedBatch,
}

local Packet: PacketModule = {} :: PacketModule
Packet.RECORD_BYTES = RECORD_BYTES
Packet.HEADER_BYTES = HEADER_BYTES
Packet.CONTROL_BYTES = CONTROL_BYTES
Packet.CONTROL_ACK = CONTROL_ACK
Packet.CONTROL_RESYNC = CONTROL_RESYNC

local scratchF32 = buffer.create(4)

local function floatBits(v: number): number
	buffer.writef32(scratchF32, 0, v)
	return buffer.readu32(scratchF32, 0)
end

local function hasCapacity(batch: DecodedBatch, count: number): boolean
	return #batch.entityIds >= count
		and #batch.quotientClasses >= count
		and #batch.xs >= count
		and #batch.ys >= count
		and #batch.zs >= count
end

function Packet.computeBatchDigest(
	count: number,
	entityIds: { number },
	quotientClasses: { number },
	xs: { number },
	ys: { number },
	zs: { number }
): number
	assert(
		#entityIds >= count and #quotientClasses >= count and #xs >= count and #ys >= count and #zs >= count,
		"digest array length mismatch"
	)
	local digest = 0
	for i = 1, count do
		local id = entityIds[i]
		local qClass = quotientClasses[i]
		local h = bit32.bxor(bit32.band(id, 0xFFFFFFFF), bit32.lrotate(bit32.band(qClass, 0xFFFFFFFF), 11))
		h = bit32.bxor(h, bit32.lrotate(floatBits(xs[i]), 3))
		h = bit32.bxor(h, bit32.lrotate(floatBits(ys[i]), 7))
		h = bit32.bxor(h, bit32.lrotate(floatBits(zs[i]), 13))
		digest = SmartHeader.stepDigest(digest, id, h)
	end
	return digest
end

function Packet.encodeControl(kind: number, epoch: number, digest: number): buffer
	assert(kind == CONTROL_ACK or kind == CONTROL_RESYNC, "invalid control frame kind")
	assert(
		epoch >= 0 and epoch <= CONTROL_EPOCH_MASK and epoch == math.floor(epoch),
		"control epoch out of range"
	)
	local out = buffer.create(CONTROL_BYTES)
	buffer.writeu32(out, 0, CONTROL_MAGIC)
	buffer.writeu32(out, 4, bit32.bor(bit32.band(kind, 0xFF), bit32.lshift(epoch, 8)))
	buffer.writeu32(out, 8, bit32.band(digest, 0xFFFFFFFF))
	return out
end

function Packet.decodeControl(pkt: buffer): ControlFrame?
	if buffer.len(pkt) ~= CONTROL_BYTES then
		return nil
	end
	if buffer.readu32(pkt, 0) ~= CONTROL_MAGIC then
		return nil
	end
	local kindAndEpoch = buffer.readu32(pkt, 4)
	if bit32.band(kindAndEpoch, 0x80000000) ~= 0 then
		return nil
	end
	return {
		kind = bit32.band(kindAndEpoch, 0xFF),
		epoch = bit32.rshift(kindAndEpoch, 8),
		digest = buffer.readu32(pkt, 8),
	}
end

local function validate(pkt: buffer, maxAllowedBytes: number?): (SmartHeader.HeaderFields?, string?)
	local len = buffer.len(pkt)
	if maxAllowedBytes ~= nil and len > maxAllowedBytes then
		return nil, "packet exceeds max allowed bytes"
	end

	local header, hdrErr = SmartHeader.read(pkt, 0)
	if header == nil then
		return nil, hdrErr
	end

	local count = header.count
	if count < 0 or count > MAX_RECORDS_PER_PACKET then
		return nil, "record count out of bounds"
	end

	if len ~= HEADER_BYTES + count * RECORD_BYTES then
		return nil, "packet byte length mismatch"
	end

	return header, nil
end

local function fill(
	pkt: buffer,
	count: number,
	entityIds: { number },
	quotientClasses: { number },
	xs: { number },
	ys: { number },
	zs: { number }
): boolean
	local offset = HEADER_BYTES
	for i = 1, count do
		local x = buffer.readf32(pkt, offset + 8)
		local y = buffer.readf32(pkt, offset + 12)
		local z = buffer.readf32(pkt, offset + 16)

		if (x - x) + (y - y) + (z - z) ~= 0 then
			return false
		end

		entityIds[i] = buffer.readu32(pkt, offset)
		quotientClasses[i] = buffer.readu32(pkt, offset + 4)
		xs[i] = x
		ys[i] = y
		zs[i] = z
		offset += RECORD_BYTES
	end

	return true
end

function Packet.encodeBatch(
	epoch: number,
	subspaceId: number,
	channel: Types.ChannelKind,
	digest: number,
	count: number,
	entityIds: { number },
	quotientClasses: { number },
	xs: { number },
	ys: { number },
	zs: { number }
): buffer
	assert(
		count >= 0 and count <= MAX_RECORDS_PER_PACKET and count == math.floor(count),
		"invalid record count"
	)
	assert(
		#entityIds >= count and #quotientClasses >= count and #xs >= count and #ys >= count and #zs >= count,
		"batch array length mismatch"
	)

	local reliable = channel == "Reliable"
	local out = buffer.create(HEADER_BYTES + count * RECORD_BYTES)

	SmartHeader.write(out, 0, epoch, subspaceId, reliable, digest, count)

	local offset = HEADER_BYTES
	for i = 1, count do
		buffer.writeu32(out, offset, entityIds[i])
		buffer.writeu32(out, offset + 4, quotientClasses[i])
		buffer.writef32(out, offset + 8, xs[i])
		buffer.writef32(out, offset + 12, ys[i])
		buffer.writef32(out, offset + 16, zs[i])
		offset += RECORD_BYTES
	end

	return out
end

function Packet.decodeBatch(
	pkt: buffer,
	maxAllowedBytes: number?
): (DecodedBatch?, string?)
	local header, err = validate(pkt, maxAllowedBytes)
	if header == nil then
		return nil, err
	end

	local count = header.count
	local entityIds: { number } = table.create(count, 0)
	local quotientClasses: { number } = table.create(count, 0)
	local xs: { number } = table.create(count, 0)
	local ys: { number } = table.create(count, 0)
	local zs: { number } = table.create(count, 0)

	if not fill(pkt, count, entityIds, quotientClasses, xs, ys, zs) then
		return nil, "non-finite coordinate"
	end

	return {
		header = header,
		count = count,
		entityIds = entityIds,
		quotientClasses = quotientClasses,
		xs = xs,
		ys = ys,
		zs = zs,
	}, nil
end

function Packet.newDecodedBatch(capacity: number?): DecodedBatch
	local cap = math.clamp(math.floor(capacity or 0), 0, MAX_RECORDS_PER_PACKET)
	return {
		header = {
			version = SmartHeader.VERSION,
			epoch = 0,
			subspaceId = 0,
			reliable = false,
			digest = 0,
			count = 0,
		},
		count = 0,
		entityIds = table.create(cap, 0),
		quotientClasses = table.create(cap, 0),
		xs = table.create(cap, 0),
		ys = table.create(cap, 0),
		zs = table.create(cap, 0),
	}
end

function Packet.decodeBatchInto(pkt: buffer, maxAllowedBytes: number?, out: DecodedBatch): (boolean, string?)
	out.count = 0

	local header, err = validate(pkt, maxAllowedBytes)
	if header == nil then
		return false, err
	end

	local count = header.count
	if not hasCapacity(out, count) then
		return false, "output batch capacity exceeded"
	end

	if not fill(pkt, count, out.entityIds, out.quotientClasses, out.xs, out.ys, out.zs) then
		return false, "non-finite coordinate"
	end

	out.header = header
	out.count = count
	return true, nil
end

return Packet