--!strict
--!native
--[[
AUTHOR: CRIMOFD
REF: ReplicatedStorage/InvariantNet/Predictor/SubspaceProjector

Observable-subspace projection for positions: per-axis allow/zero masks, optional quantization step, and residual metrics that split prediction error into an observable component (above tolerance, must emit) and a null component (hidden by the projection).
]]

local Types = require(script.Parent.Parent.Types)

export type MaskAxis = "X" | "Y" | "Z"

export type SubspaceConfig = {
	allowX: boolean,
	allowY: boolean,
	allowZ: boolean,
	toleranceSq: number,
	quantStep: number?,
}

export type SubspaceProjectorModule = {
	newConfig: (allowX: boolean, allowY: boolean, allowZ: boolean, tolerance: number, quantStep: number?) -> SubspaceConfig,
	projectVec3: (cfg: SubspaceConfig, x: number, y: number, z: number) -> Types.Vec3Tuple,
	projectInto: (cfg: SubspaceConfig, x: number, y: number, z: number, out: Types.Vec3Tuple) -> (),
	residualMetric: (
		cfg: SubspaceConfig,
		actualX: number,
		actualY: number,
		actualZ: number,
		predX: number,
		predY: number,
		predZ: number
	) -> Types.ProjectionMetric,
	shouldEmitResidual: (
		cfg: SubspaceConfig,
		actualX: number,
		actualY: number,
		actualZ: number,
		predX: number,
		predY: number,
		predZ: number
	) -> boolean,
}

local SubspaceProjector: SubspaceProjectorModule = {} :: SubspaceProjectorModule

local function quantizeAxis(val: number, step: number): number
	if step <= 0 then
		return val
	end
	return math.floor(val / step + 0.5) * step
end

function SubspaceProjector.newConfig(
	allowX: boolean,
	allowY: boolean,
	allowZ: boolean,
	tolerance: number,
	quantStep: number?
): SubspaceConfig
	assert(tolerance >= 0, "tolerance must be non-negative")
	return {
		allowX = allowX,
		allowY = allowY,
		allowZ = allowZ,
		toleranceSq = tolerance * tolerance,
		quantStep = quantStep,
	}
end

function SubspaceProjector.projectVec3(cfg: SubspaceConfig, x: number, y: number, z: number): Types.Vec3Tuple
	local step = cfg.quantStep or 0
	local px = if cfg.allowX then quantizeAxis(x, step) else 0
	local py = if cfg.allowY then quantizeAxis(y, step) else 0
	local pz = if cfg.allowZ then quantizeAxis(z, step) else 0
	return {
		x = px,
		y = py,
		z = pz,
	}
end

function SubspaceProjector.projectInto(
	cfg: SubspaceConfig,
	x: number,
	y: number,
	z: number,
	out: Types.Vec3Tuple
): ()
	local step = cfg.quantStep or 0
	out.x = if cfg.allowX then quantizeAxis(x, step) else 0
	out.y = if cfg.allowY then quantizeAxis(y, step) else 0
	out.z = if cfg.allowZ then quantizeAxis(z, step) else 0
end

function SubspaceProjector.residualMetric(
	cfg: SubspaceConfig,
	actualX: number,
	actualY: number,
	actualZ: number,
	predX: number,
	predY: number,
	predZ: number
): Types.ProjectionMetric
	local ax = if cfg.allowX then actualX else 0
	local ay = if cfg.allowY then actualY else 0
	local az = if cfg.allowZ then actualZ else 0

	local px = if cfg.allowX then predX else 0
	local py = if cfg.allowY then predY else 0
	local pz = if cfg.allowZ then predZ else 0

	local dx = ax - px
	local dy = ay - py
	local dz = az - pz
	local obsNormSq = dx * dx + dy * dy + dz * dz

	local fullDx = actualX - predX
	local fullDy = actualY - predY
	local fullDz = actualZ - predZ
	local fullNormSq = fullDx * fullDx + fullDy * fullDy + fullDz * fullDz
	local nullNormSq = math.max(0, fullNormSq - obsNormSq)

	return {
		observableNormSq = obsNormSq,
		nullNormSq = nullNormSq,
		shouldEmit = obsNormSq > cfg.toleranceSq,
	}
end

function SubspaceProjector.shouldEmitResidual(
	cfg: SubspaceConfig,
	actualX: number,
	actualY: number,
	actualZ: number,
	predX: number,
	predY: number,
	predZ: number
): boolean
	local ax = if cfg.allowX then actualX else 0
	local ay = if cfg.allowY then actualY else 0
	local az = if cfg.allowZ then actualZ else 0

	local px = if cfg.allowX then predX else 0
	local py = if cfg.allowY then predY else 0
	local pz = if cfg.allowZ then predZ else 0

	local dx = ax - px
	local dy = ay - py
	local dz = az - pz
	return (dx * dx + dy * dy + dz * dz) > cfg.toleranceSq
end

return SubspaceProjector