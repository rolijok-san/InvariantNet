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

export type EquivalenceMap<TState> = (state: TState) -> Types.QuotientClassId
export type TransitionOp<TState, TDelta> = (state: TState, delta: TDelta) -> TState
export type MonoidCombine<TDelta> = (a: TDelta, b: TDelta) -> TDelta
export type StateComparator<TState> = (a: TState, b: TState) -> boolean

export type QuotientMonoid<TState, TDelta> = {
	identity: TDelta,
	classify: EquivalenceMap<TState>,
	combine: MonoidCombine<TDelta>,
	apply: TransitionOp<TState, TDelta>,
	equals: StateComparator<TState>?,
}

export type QuotientMonoidModule = {
	new: <TState, TDelta>(
		identity: TDelta,
		classify: EquivalenceMap<TState>,
		combine: MonoidCombine<TDelta>,
		apply: TransitionOp<TState, TDelta>,
		equals: StateComparator<TState>?
	) -> QuotientMonoid<TState, TDelta>,
	quotientClass: <TState, TDelta>(qm: QuotientMonoid<TState, TDelta>, state: TState) -> Types.QuotientClassId,
	equivalentStates: <TState, TDelta>(qm: QuotientMonoid<TState, TDelta>, a: TState, b: TState) -> boolean,
	commutesOnState: <TState, TDelta>(
		qm: QuotientMonoid<TState, TDelta>,
		state: TState,
		d1: TDelta,
		d2: TDelta
	) -> boolean,
	foldDeltas: <TState, TDelta>(qm: QuotientMonoid<TState, TDelta>, deltas: { TDelta }) -> TDelta,
	coalesceIfCommutative: <TState, TDelta>(
		qm: QuotientMonoid<TState, TDelta>,
		probeState: TState,
		deltas: { TDelta }
	) -> (TDelta, boolean),
	foldWithOutcome: <TState, TDelta>(
		qm: QuotientMonoid<TState, TDelta>,
		probeState: TState,
		deltas: { TDelta },
		requireCommutative: boolean
	) -> Types.FoldOutcome<TDelta>,
}

local QuotientMonoidImpl: QuotientMonoidModule = {} :: QuotientMonoidModule

function QuotientMonoidImpl.new<TState, TDelta>(
	identity: TDelta,
	classify: EquivalenceMap<TState>,
	combine: MonoidCombine<TDelta>,
	apply: TransitionOp<TState, TDelta>,
	equals: StateComparator<TState>?
): QuotientMonoid<TState, TDelta>
	assert(typeof(classify) == "function", "QuotientMonoid requires a classify function")
	assert(typeof(combine) == "function", "QuotientMonoid requires a combine function")
	assert(typeof(apply) == "function", "QuotientMonoid requires an apply function")

	return {
		identity = identity,
		classify = classify,
		combine = combine,
		apply = apply,
		equals = equals,
	}
end

function QuotientMonoidImpl.quotientClass<TState, TDelta>(
	qm: QuotientMonoid<TState, TDelta>,
	state: TState
): Types.QuotientClassId
	return qm.classify(state)
end

function QuotientMonoidImpl.equivalentStates<TState, TDelta>(
	qm: QuotientMonoid<TState, TDelta>,
	a: TState,
	b: TState
): boolean
	return qm.classify(a) == qm.classify(b)
end

function QuotientMonoidImpl.commutesOnState<TState, TDelta>(
	qm: QuotientMonoid<TState, TDelta>,
	state: TState,
	d1: TDelta,
	d2: TDelta
): boolean
	local ab = qm.apply(qm.apply(state, d1), d2)
	local ba = qm.apply(qm.apply(state, d2), d1)
	if qm.equals ~= nil then
		return qm.equals(ab, ba)
	end
	return qm.classify(ab) == qm.classify(ba)
end

function QuotientMonoidImpl.foldDeltas<TState, TDelta>(
	qm: QuotientMonoid<TState, TDelta>,
	deltas: { TDelta }
): TDelta
	local acc = qm.identity
	for i = 1, #deltas do
		acc = qm.combine(acc, deltas[i])
	end
	return acc
end

function QuotientMonoidImpl.coalesceIfCommutative<TState, TDelta>(
	qm: QuotientMonoid<TState, TDelta>,
	probeState: TState,
	deltas: { TDelta }
): (TDelta, boolean)
	local n = #deltas
	if n == 0 then
		return qm.identity, true
	end

	local acc = deltas[1]
	for i = 2, n do
		local nextDelta = deltas[i]
		if not QuotientMonoidImpl.commutesOnState(qm, probeState, acc, nextDelta) then
			return qm.identity, false
		end
		acc = qm.combine(acc, nextDelta)
	end

	return acc, true
end

function QuotientMonoidImpl.foldWithOutcome<TState, TDelta>(
	qm: QuotientMonoid<TState, TDelta>,
	probeState: TState,
	deltas: { TDelta },
	requireCommutative: boolean
): Types.FoldOutcome<TDelta>
	local n = #deltas
	if n == 0 then
		return {
			delta = qm.identity,
			foldedCount = 0,
			orderPreserved = true,
		}
	end

	if requireCommutative then
		local acc = deltas[1]
		for i = 2, n do
			local nextDelta = deltas[i]
			if not QuotientMonoidImpl.commutesOnState(qm, probeState, acc, nextDelta) then
				local ordered = QuotientMonoidImpl.foldDeltas(qm, deltas)
				return {
					delta = ordered,
					foldedCount = n,
					orderPreserved = true,
				}
			end
			acc = qm.combine(acc, nextDelta)
		end

		return {
			delta = acc,
			foldedCount = n,
			orderPreserved = false,
		}
	end

	return {
		delta = QuotientMonoidImpl.foldDeltas(qm, deltas),
		foldedCount = n,
		orderPreserved = true,
	}
end

return QuotientMonoidImpl