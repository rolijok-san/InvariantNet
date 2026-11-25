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

local Types = require(script.Parent.Parent.Types)

export type LinearFlow = {
	x0: number,
	y0: number,
	z0: number,
	vx: number,
	vy: number,
	vz: number,
}

export type BallisticFlow = {
	x0: number,
	y0: number,
	z0: number,
	vx: number,
	vy: number,
	vz: number,
	gx: number,
	gy: number,
	gz: number,
}

export type OrbitFlow = {
	cx: number,
	cy: number,
	cz: number,
	radius: number,
	omega: number,
	phase: number,
	yBobAmp: number,
	yBobFreq: number,
}

export type TrajectoryFlowModule = {
	sampleLinear: (flow: LinearFlow, dt: number) -> Types.Vec3Tuple,
	sampleBallistic: (flow: BallisticFlow, dt: number) -> Types.Vec3Tuple,
	sampleOrbit: (flow: OrbitFlow, dt: number) -> Types.Vec3Tuple,
	writeLinearInto: (flow: LinearFlow, dt: number, xs: { number }, ys: { number }, zs: { number }, index: number) -> (),
	writeBallisticInto: (
		flow: BallisticFlow,
		dt: number,
		xs: { number },
		ys: { number },
		zs: { number },
		index: number
	) -> (),
	writeOrbitInto: (flow: OrbitFlow, dt: number, xs: { number }, ys: { number }, zs: { number }, index: number) -> (),
}

local TrajectoryFlow: TrajectoryFlowModule = {} :: TrajectoryFlowModule

function TrajectoryFlow.sampleLinear(flow: LinearFlow, dt: number): Types.Vec3Tuple
	return {
		x = flow.x0 + flow.vx * dt,
		y = flow.y0 + flow.vy * dt,
		z = flow.z0 + flow.vz * dt,
	}
end

function TrajectoryFlow.sampleBallistic(flow: BallisticFlow, dt: number): Types.Vec3Tuple
	local halfDtSq = 0.5 * dt * dt
	return {
		x = flow.x0 + flow.vx * dt + flow.gx * halfDtSq,
		y = flow.y0 + flow.vy * dt + flow.gy * halfDtSq,
		z = flow.z0 + flow.vz * dt + flow.gz * halfDtSq,
	}
end

function TrajectoryFlow.sampleOrbit(flow: OrbitFlow, dt: number): Types.Vec3Tuple
	local angle = flow.phase + flow.omega * dt
	local bob = if flow.yBobAmp ~= 0 then flow.yBobAmp * math.sin(flow.yBobFreq * dt) else 0
	return {
		x = flow.cx + flow.radius * math.cos(angle),
		y = flow.cy + bob,
		z = flow.cz + flow.radius * math.sin(angle),
	}
end

function TrajectoryFlow.writeLinearInto(
	flow: LinearFlow,
	dt: number,
	xs: { number },
	ys: { number },
	zs: { number },
	index: number
): ()
	xs[index] = flow.x0 + flow.vx * dt
	ys[index] = flow.y0 + flow.vy * dt
	zs[index] = flow.z0 + flow.vz * dt
end

function TrajectoryFlow.writeBallisticInto(
	flow: BallisticFlow,
	dt: number,
	xs: { number },
	ys: { number },
	zs: { number },
	index: number
): ()
	local halfDtSq = 0.5 * dt * dt
	xs[index] = flow.x0 + flow.vx * dt + flow.gx * halfDtSq
	ys[index] = flow.y0 + flow.vy * dt + flow.gy * halfDtSq
	zs[index] = flow.z0 + flow.vz * dt + flow.gz * halfDtSq
end

function TrajectoryFlow.writeOrbitInto(
	flow: OrbitFlow,
	dt: number,
	xs: { number },
	ys: { number },
	zs: { number },
	index: number
): ()
	local angle = flow.phase + flow.omega * dt
	local bob = if flow.yBobAmp ~= 0 then flow.yBobAmp * math.sin(flow.yBobFreq * dt) else 0
	xs[index] = flow.cx + flow.radius * math.cos(angle)
	ys[index] = flow.cy + bob
	zs[index] = flow.cz + flow.radius * math.sin(angle)
end

return (TrajectoryFlow :: any) :: TrajectoryFlowModule