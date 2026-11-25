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

local SMART_MAGIC: number = 0x534D4152
local SMART_VERSION: number = 1
local HEADER_BYTES: number = 16
local MAX_COUNT: number = 0x7FFF
local EPOCH_MASK: number = 0x7FFFFF
local MAX_SUBSPACE: number = 0x00FF
local TWO_POW_32: number = 4294967296

export type HeaderFields = {
	version: number,
	epoch: number,
	subspaceId: number,
	reliable: boolean,
	digest: number,
	count: number,
}

export type SmartHeaderModule = {
	BYTE_SIZE: number,
	MAGIC: number,
	VERSION: number,
	mul32: (a: number, b: number) -> number,
	fmix32: (h: number) -> number,
	stepDigest: (prevDigest: number, key: number, payloadHash: number) -> number,
	write: (
		out: buffer,
		offset: number,
		epoch: number,
		subspaceId: number,
		reliable: boolean,
		digest: number,
		count: number
	) -> (),
	read: (pkt: buffer, offset: number) -> (HeaderFields?, string?),
}

local SmartHeader: SmartHeaderModule = {} :: SmartHeaderModule
SmartHeader.BYTE_SIZE = HEADER_BYTES
SmartHeader.MAGIC = SMART_MAGIC
SmartHeader.VERSION = SMART_VERSION

function SmartHeader.mul32(a: number, b: number): number
	local ah = bit32.rshift(a, 16)
	local al = bit32.band(a, 0xFFFF)
	local bh = bit32.rshift(b, 16)
	local bl = bit32.band(b, 0xFFFF)
	return (((ah * bl + al * bh) % 65536) * 65536 + al * bl) % TWO_POW_32
end

local mul32 = SmartHeader.mul32

function SmartHeader.fmix32(h: number): number
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	return bit32.bxor(h, bit32.rshift(h, 16))
end

local function mixWord(h: number, w: number): number
	local k = mul32(w, 0xCC9E2D51)
	k = bit32.lrotate(k, 15)
	k = mul32(k, 0x1B873593)
	h = bit32.bxor(h, k)
	h = bit32.lrotate(h, 13)
	return (mul32(h, 5) + 0xE6546B64) % TWO_POW_32
end

function SmartHeader.stepDigest(prevDigest: number, key: number, payloadHash: number): number
	local h = mixWord(bit32.band(prevDigest, 0xFFFFFFFF), bit32.band(key, 0xFFFFFFFF))
	h = mixWord(h, bit32.band(payloadHash, 0xFFFFFFFF))
	return SmartHeader.fmix32(h)
end

function SmartHeader.write(
	out: buffer,
	offset: number,
	epoch: number,
	subspaceId: number,
	reliable: boolean,
	digest: number,
	count: number
): ()
	assert(offset >= 0 and offset + HEADER_BYTES <= buffer.len(out), "header write out of bounds")
	assert(count >= 0 and count <= MAX_COUNT and count == math.floor(count), "header count out of range")
	assert(epoch >= 0 and epoch <= EPOCH_MASK and epoch == math.floor(epoch), "header epoch out of range")
	assert(subspaceId >= 0 and subspaceId <= MAX_SUBSPACE and subspaceId == math.floor(subspaceId), "header subspaceId out of range")

	local relBit = if reliable then 1 else 0

	local epochLow15 = bit32.band(epoch, 0x7FFF)
	local epochExt = bit32.rshift(epoch, 15)

	local flagsByte = bit32.bor(bit32.lshift(relBit, 7), bit32.band(bit32.rshift(epochLow15, 8), 0x7F))
	local epochLowByte = bit32.band(epochLow15, 0x00FF)

	local packedWord67 = bit32.bor(epochLowByte, bit32.lshift(subspaceId, 8))
	local packedVerFlags = bit32.bor(bit32.band(SMART_VERSION, 0x00FF), bit32.lshift(flagsByte, 8))
	local countWord = bit32.bor(count, bit32.lshift(epochExt, 15))

	buffer.writeu32(out, offset, SMART_MAGIC)
	buffer.writeu16(out, offset + 4, packedVerFlags)
	buffer.writeu16(out, offset + 6, packedWord67)
	buffer.writeu32(out, offset + 8, bit32.band(digest, 0xFFFFFFFF))
	buffer.writeu32(out, offset + 12, countWord)
end

function SmartHeader.read(pkt: buffer, offset: number): (HeaderFields?, string?)
	if offset < 0 or buffer.len(pkt) < offset + HEADER_BYTES then
		return nil, "header truncated"
	end

	if buffer.readu32(pkt, offset) ~= SMART_MAGIC then
		return nil, "invalid smart header magic"
	end

	local verFlags = buffer.readu16(pkt, offset + 4)
	local version = bit32.band(verFlags, 0x00FF)
	if version ~= SMART_VERSION then
		return nil, "unsupported smart header version"
	end

	local countWord = buffer.readu32(pkt, offset + 12)
	if bit32.rshift(countWord, 23) ~= 0 then
		return nil, "reserved header bits set"
	end

	local flagsByte = bit32.rshift(verFlags, 8)
	local reliable = bit32.band(bit32.rshift(flagsByte, 7), 1) == 1
	local epochHighTop = bit32.band(flagsByte, 0x7F)

	local word67 = buffer.readu16(pkt, offset + 6)
	local epochLowByte = bit32.band(word67, 0x00FF)
	local subspaceId = bit32.band(bit32.rshift(word67, 8), 0x00FF)

	local epochLow15 = bit32.bor(bit32.lshift(epochHighTop, 8), epochLowByte)
	local epoch = bit32.bor(epochLow15, bit32.lshift(bit32.rshift(countWord, 15), 15))
	local digest = buffer.readu32(pkt, offset + 8)
	local count = bit32.band(countWord, MAX_COUNT)

	return {
		version = version,
		epoch = epoch,
		subspaceId = subspaceId,
		reliable = reliable,
		digest = digest,
		count = count,
	}, nil
end

return SmartHeader