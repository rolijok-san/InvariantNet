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

export type SeedStreamModule = {
	mul32: (a: number, b: number) -> number,
	mulHi32: (a: number, b: number) -> number,
	fmix32: (h: number) -> number,
	nextU32: (state: number) -> number,
	next: (state: number) -> (number, number),
	skip: (state: number, n: number) -> number,
	valueAt: (seed: number, index: number) -> number,
	atStep: (baseSeed: number, entityId: number, step: number) -> number,
	atStepLane: (baseSeed: number, entityId: number, step: number, lane: number) -> number,
	unitFloat: (state: number) -> number,
	unit53: (hi: number, lo: number) -> number,
	signedFloat: (state: number) -> number,
	rangeFloat: (state: number, minVal: number, maxVal: number) -> number,
	rangeInt: (state: number, minVal: number, maxVal: number) -> number,
	rangeIntExact: (state: number, minVal: number, maxVal: number) -> (number, number),
	bernoulli: (state: number, p: number) -> boolean,
	gaussian: (stateA: number, stateB: number) -> number,
	exponential: (state: number, rate: number) -> number,
	unitVec3: (stateA: number, stateB: number) -> (number, number, number),
}

local TWO_POW_32: number = 4294967296
local GOLDEN: number = 0x9E3779B9
local TWO_PI: number = 2 * math.pi

local SeedStream: SeedStreamModule = {} :: SeedStreamModule

function SeedStream.mul32(a: number, b: number): number
	local ah = bit32.rshift(a, 16)
	local al = bit32.band(a, 0xFFFF)
	local bh = bit32.rshift(b, 16)
	local bl = bit32.band(b, 0xFFFF)
	return (((ah * bl + al * bh) % 65536) * 65536 + al * bl) % TWO_POW_32
end

function SeedStream.mulHi32(a: number, b: number): number
	local ah = bit32.rshift(a, 16)
	local al = bit32.band(a, 0xFFFF)
	local bh = bit32.rshift(b, 16)
	local bl = bit32.band(b, 0xFFFF)
	return ah * bh + math.floor(((ah * bl + al * bh) * 65536 + al * bl) / TWO_POW_32)
end

local mul32 = SeedStream.mul32
local mulHi32 = SeedStream.mulHi32

function SeedStream.fmix32(h: number): number
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	return bit32.bxor(h, bit32.rshift(h, 16))
end

local fmix32 = SeedStream.fmix32

local function absorb(h: number, w: number): number
	local k = mul32(bit32.band(w, 0xFFFFFFFF), 0xCC9E2D51)
	k = bit32.lrotate(k, 15)
	k = mul32(k, 0x1B873593)
	h = bit32.bxor(h, k)
	h = bit32.lrotate(h, 13)
	return (mul32(h, 5) + 0xE6546B64) % TWO_POW_32
end

function SeedStream.next(state: number): (number, number)
	local s = (bit32.band(state, 0xFFFFFFFF) + GOLDEN) % TWO_POW_32
	return s, fmix32(s)
end

function SeedStream.nextU32(state: number): number
	local s = (bit32.band(state, 0xFFFFFFFF) + GOLDEN) % TWO_POW_32
	return fmix32(s)
end

function SeedStream.skip(state: number, n: number): number
	return (bit32.band(state, 0xFFFFFFFF) + mul32(bit32.band(n, 0xFFFFFFFF), GOLDEN)) % TWO_POW_32
end

function SeedStream.valueAt(seed: number, index: number): number
	return fmix32(SeedStream.skip(seed, index + 1))
end

function SeedStream.atStep(baseSeed: number, entityId: number, step: number): number
	local h = bit32.band(baseSeed, 0xFFFFFFFF)
	h = absorb(h, entityId)
	h = absorb(h, step)
	return fmix32(bit32.bxor(h, 8))
end

function SeedStream.atStepLane(baseSeed: number, entityId: number, step: number, lane: number): number
	local h = bit32.band(baseSeed, 0xFFFFFFFF)
	h = absorb(h, entityId)
	h = absorb(h, step)
	h = absorb(h, lane)
	return fmix32(bit32.bxor(h, 12))
end

function SeedStream.unitFloat(state: number): number
	return bit32.band(state, 0xFFFFFFFF) / TWO_POW_32
end

function SeedStream.unit53(hi: number, lo: number): number
	return (bit32.rshift(hi, 5) * 67108864 + bit32.rshift(lo, 6)) / 9007199254740992
end

function SeedStream.signedFloat(state: number): number
	return SeedStream.unitFloat(state) * 2 - 1
end

function SeedStream.rangeFloat(state: number, minVal: number, maxVal: number): number
	return minVal + (maxVal - minVal) * SeedStream.unitFloat(state)
end

function SeedStream.rangeInt(state: number, minVal: number, maxVal: number): number
	if maxVal <= minVal then
		return minVal
	end

	local u = bit32.band(state, 0xFFFFFFFF)
	local span = maxVal - minVal + 1
	if span >= TWO_POW_32 then
		return minVal + u
	end

	return minVal + mulHi32(u, span)
end

function SeedStream.rangeIntExact(state: number, minVal: number, maxVal: number): (number, number)
	if maxVal <= minVal then
		return minVal, state
	end

	local span = maxVal - minVal + 1
	local s, v = SeedStream.next(state)
	if span >= TWO_POW_32 then
		return minVal + v, s
	end

	local threshold = (TWO_POW_32 - span) % span
	while mul32(v, span) < threshold do
		s, v = SeedStream.next(s)
	end

	return minVal + mulHi32(v, span), s
end

function SeedStream.bernoulli(state: number, p: number): boolean
	return SeedStream.unitFloat(state) < p
end

function SeedStream.gaussian(stateA: number, stateB: number): number
	local u1 = (bit32.band(stateA, 0xFFFFFFFF) + 0.5) / TWO_POW_32
	local u2 = bit32.band(stateB, 0xFFFFFFFF) / TWO_POW_32
	return math.sqrt(-2 * math.log(u1)) * math.cos(TWO_PI * u2)
end

function SeedStream.exponential(state: number, rate: number): number
	local u = (bit32.band(state, 0xFFFFFFFF) + 0.5) / TWO_POW_32
	return -math.log(u) / rate
end

function SeedStream.unitVec3(stateA: number, stateB: number): (number, number, number)
	local z = SeedStream.signedFloat(stateA)
	local phi = TWO_PI * SeedStream.unitFloat(stateB)
	local r = math.sqrt(math.max(0, 1 - z * z))
	return r * math.cos(phi), r * math.sin(phi), z
end

return SeedStream
