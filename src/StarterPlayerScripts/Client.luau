--!strict
--[[
AUTHOR: CRIMOFD
REF: StarterPlayerScripts/InvariantNet (client bootstrap)

Client bootstrap: starts the InvariantNet client with cull, snap, blend, and extrapolation settings. All runtime logic lives in the Client ModuleScript child so gameplay code can require it.
]]

local Client = require(script.Client)

Client.start({
	cullRadius = 650,
	snapDistance = 24,
	blendTime = 0.12,
	maxExtrapolation = 0.75,
	stepEvent = "PreRender",
})
