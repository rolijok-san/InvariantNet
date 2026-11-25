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
local SeedStreamImpl = require(script.SeedStream)

export type PredictorModule = {
	SeedStream: ModuleScript,
	TrajectoryFlow: ModuleScript,
	SubspaceProjector: ModuleScript,
	stepSeed: (seed: number, step: number) -> number,
	predictLinear: (
		x0: number,
		y0: number,
		z0: number,
		vx: number,
		vy: number,
		vz: number,
		dt: number
	) -> Types.Vec3Tuple,
	evaluateResidualSq: (
		actualX: number,
		actualY: number,
		actualZ: number,
		predX: number,
		predY: number,
		predZ: number,
		toleranceSq: number
	) -> Types.ProjectionMetric,
}

local Predictor: PredictorModule = {} :: PredictorModule
Predictor.SeedStream = script:WaitForChild("SeedStream") :: ModuleScript
Predictor.TrajectoryFlow = script:WaitForChild("TrajectoryFlow") :: ModuleScript
Predictor.SubspaceProjector = script:WaitForChild("SubspaceProjector") :: ModuleScript

function Predictor.stepSeed(seed: number, step: number): number
	local s = bit32.band(seed, 0xFFFFFFFF)
	local k = bit32.band(step, 0xFFFFFFFF)
	local h = bit32.bxor(s, bit32.lrotate(k, 17))
	h = SeedStreamImpl.mul32(h, 0x27D4EB2D)
	h = bit32.bxor(h, bit32.rshift(h, 15))
	return SeedStreamImpl.mul32(h, 0x85EBCA6B)
end

function Predictor.predictLinear(
	x0: number,
	y0: number,
	z0: number,
	vx: number,
	vy: number,
	vz: number,
	dt: number
): Types.Vec3Tuple
	return {
		x = x0 + vx * dt,
		y = y0 + vy * dt,
		z = z0 + vz * dt,
	}
end

function Predictor.evaluateResidualSq(
	actualX: number,
	actualY: number,
	actualZ: number,
	predX: number,
	predY: number,
	predZ: number,
	toleranceSq: number
): Types.ProjectionMetric
	local dx = actualX - predX
	local dy = actualY - predY
	local dz = actualZ - predZ
	local residualSq = dx * dx + dy * dy + dz * dz
	return {
		observableNormSq = residualSq,
		nullNormSq = math.max(0, toleranceSq - residualSq),
		shouldEmit = residualSq > toleranceSq,
	}
end

return Predictor