--!strict
--!native
--[[
AUTHOR: CRIMOFD
REF: ReplicatedStorage/InvariantNet v1.0.0 (root module)

Root entry point of InvariantNet, an invariant-gated state-equivalence and sparse transport architecture: state is filtered, folded, and projected before a single byte is allocated, then shipped as compact SoA batches over Reliable/Unreliable remotes with per-client rate budgets and strict bounds verification. Transport lineage: ByteNet Max (ffrostfall) and Packet (Suphi Kaner). Foundations: Shannon 1948, Kalman 1960, Mac Lane 1971, Noether 1918, Kolmogorov 1965, Cayley-Dickson 1919, Ford-Fulkerson 1956. MIT License, Copyright (c) 2026 CRIMOFD. Re-exports every submodule as the public API.
]]

local Types = require(script.Types)
local SmartHeader = require(script.SmartHeader)
local Packet = require(script.Packet)
local ChannelRouter = require(script.ChannelRouter)
local PartitionGraph = require(script.PartitionGraph)
local CutCuller = require(script.CutCuller)
local QuotientMonoid = require(script.QuotientMonoid)
local FrameBatcher = require(script.FrameBatcher)
local Predictor = require(script.Predictor)
local SeedStream = require(script.Predictor.SeedStream)
local TrajectoryFlow = require(script.Predictor.TrajectoryFlow)
local SubspaceProjector = require(script.Predictor.SubspaceProjector)

export type InvariantNetModule = {
	VERSION: string,
	Types: typeof(Types),
	SmartHeader: typeof(SmartHeader),
	Packet: typeof(Packet),
	ChannelRouter: typeof(ChannelRouter),
	PartitionGraph: typeof(PartitionGraph),
	CutCuller: typeof(CutCuller),
	QuotientMonoid: typeof(QuotientMonoid),
	FrameBatcher: typeof(FrameBatcher),
	Predictor: typeof(Predictor),
	SeedStream: typeof(SeedStream),
	TrajectoryFlow: typeof(TrajectoryFlow),
	SubspaceProjector: typeof(SubspaceProjector),
}

local InvariantNet: InvariantNetModule = {
	VERSION = "1.0.0",
	Types = Types,
	SmartHeader = SmartHeader,
	Packet = Packet,
	ChannelRouter = ChannelRouter,
	PartitionGraph = PartitionGraph,
	CutCuller = CutCuller,
	QuotientMonoid = QuotientMonoid,
	FrameBatcher = FrameBatcher,
	Predictor = Predictor,
	SeedStream = SeedStream,
	TrajectoryFlow = TrajectoryFlow,
	SubspaceProjector = SubspaceProjector,
}

return InvariantNet
