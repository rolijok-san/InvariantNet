# InvariantNet

Welcome back to **Season 2 of CRIMOFD aka rolijok-san's adventure!** After diving deep into 32D Cayley-Dickson trigintaduonions, zero-divisors, box-kites, and geodesic springs in *LuaTrigintaduonions*, Season 2 brings that same `--!strict`, `--!native` engineering energy straight into high-throughput Roblox networking.

**InvariantNet** is a `--!strict`, `--!native` Luau networking framework for Roblox built around **quotient monoid delta folding**, **subspace residual filtering**, **spatial/zone culling**, and **packed `buffer` batches**. Instead of blasting redundant state updates over remotes every frame, `InvariantNet` folds incremental deltas, checks predicted state residuals against a tolerance threshold, projects only meaningful deviations onto a target subspace, and ships compact `buffer` payloads over reliable or unreliable channels under strict size and rate budgets.

It is designed for real-time multiplayer simulations, high-entity worlds, and custom replication pipelines where bandwidth discipline, predictable frame cost, and drift recovery matter. Because it targets Luau with Roblox APIs (`buffer`, `bit32`, `RunService`, `Players`, `RemoteEvent`, `UnreliableRemoteEvent`), porting it to plain Lua requires stripping Luau type syntax (`--!strict`, `export type`, type casts) and `--!native`, and replacing Roblox/Luau primitives.

## Modules

* `src/shared/InvariantNet/init.luau`: Shared entry point re-exporting core modules, predictor utilities, and public types.
* `src/shared/InvariantNet/Types.luau`: Shared type definitions for entities, zones, quotient classes, channels, headers, and batches.
* `src/shared/InvariantNet/QuotientMonoid.luau`: Algebraic delta folding over equivalence/quotient classes, including commutativity/ordering checks and state application.
* `src/shared/InvariantNet/SmartHeader.luau`: Compact batch/frame header utilities and rolling digest calculation for tracking state integrity across updates.
* `src/shared/InvariantNet/Packet.luau`: Binary `buffer` encoder and decoder for packing entity batches (IDs, zones, quotient classes, and coordinates) with headers and digests.
* `src/shared/InvariantNet/FrameBatcher.luau`: Structure-of-Arrays (SoA) batch accumulator that collects entity updates across frames without heavy per-entity table churn.
* `src/shared/InvariantNet/PartitionGraph.luau`: Entity-to-zone partition tracking for spatial/logical grouping and cleanup.
* `src/shared/InvariantNet/CutCuller.luau`: Zone and spatial/cut filtering to cull irrelevant updates before sending to a player.
* `src/shared/InvariantNet/ChannelRouter.luau`: Routes packed `buffer` traffic over `RemoteEvent` (Reliable) and `UnreliableRemoteEvent` (Unreliable) channels with packet size limits, inbound rate windows, and player cleanup.
* `src/shared/InvariantNet/Predictor/init.luau`: Predictor namespace/entry point for trajectory and state prediction helpers.
* `src/shared/InvariantNet/Predictor/SubspaceProjector.luau`: Residual threshold checking and subspace projection/quantization so small or predictable deltas don't waste bandwidth.
* `src/shared/InvariantNet/Predictor/TrajectoryFlow.luau`: Trajectory flow and motion prediction helpers for estimating future entity states.
* `src/shared/InvariantNet/Predictor/SeedStream.luau`: Deterministic seed stream utilities for reproducible prediction and simulation steps.
* `src/ServerScriptService/InvariantNet.server.luau`: Authoritative server orchestrator managing delta queues, monoid folding, residual filtering, batch flushing, and inbound packet validation.
* `src/StarterPlayer/StarterPlayerScripts/InvariantNet/Client.client.luau` & `Client.luau`: Client entry point and module for receiving, decoding, and applying incoming `buffer` batches and handling sync/recovery.

## Architecture Highlights

* **Quotient Monoid Delta Folding (`QuotientMonoid`):** Queues incremental deltas (`dx`, `dy`, `dz`, zone/class transitions, and ordering flags) and folds them into a single net update per commit cycle, respecting non-commutative transitions when required.
* **Subspace Residual Filtering (`SubspaceProjector` & `Predictor`):** Compares actual state against predicted state and skips emission when the residual stays within tolerance, projecting emitted states onto the active subspace.
* **SoA Batching & Binary `buffer` Packets (`FrameBatcher`, `SmartHeader`, `Packet`):** Aggregates updates in flat arrays and serializes them into compact `buffer` frames with epoch, subspace, channel, and rolling digest metadata.
* **Channel Routing & Guardrails (`ChannelRouter`):** Separates reliable and unreliable traffic, rejects non-`buffer` or malformed payloads, enforces per-window inbound byte caps, and cleans up per-player state on `PlayerRemoving`.

## Important Information

* **Non-commutative deltas:** When deltas are marked non-commutative or commutative folding is enforced, fold order matters—test custom monoids carefully so out-of-order assumptions don't corrupt state.
* **Sourcemap & LSP resolution:** When developing in VS Code outside Roblox Studio sync tools, keep `sourcemap.json` aligned with your on-disk folders (`init.luau` files, `.server.luau` / `.client.luau` / `.luau` extensions, and service casing) so the Luau language server resolves every `require` cleanly.
* **Mutable / reused scratch structures:** Batchers, scratch arrays, and cached/reused state can be cleared or overwritten between frames or flushes—copy or clone values if you need an immutable snapshot.

## Validating Further

* **Network & bandwidth validation:** Benchmark `buffer` sizes, frame flush costs, and residual skip ratios across stationary, linear-motion, and high-jitter entities under simulated packet loss and latency.
* **Resync & security validation:** Test `ChannelRouter` inbound byte-window throttling, non-`buffer` rejection callbacks, player disconnect cleanup (`PlayerRemoving`), and epoch/digest mismatch recovery between server and client.

## Usage

Place your files under `ReplicatedStorage`, `ServerScriptService`, and `StarterPlayerScripts` (via your `sourcemap.json` setup in VS Code or directly in Roblox Studio), and drive updates on the server:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InvariantNetRoot = ReplicatedStorage:WaitForChild("InvariantNet")
local QuotientMonoid = require(InvariantNetRoot.QuotientMonoid)
local SubspaceProjector = require(InvariantNetRoot.Predictor.SubspaceProjector)
local Packet = require(InvariantNetRoot.Packet)

local subspaceCfg = SubspaceProjector.newConfig(true, true, true, 0.05, nil)

local shouldSend = SubspaceProjector.shouldEmitResidual(
	subspaceCfg,
	12.0, 4.0, -8.5,
	11.98, 4.0, -8.5
)
print("Emit update:", shouldSend)

local pkt = Packet.encodeBatch(
	1,
	0,
	"Unreliable",
	0,
	1,
	{ 101 },
	{ 1 },
	{ 12.0 },
	{ 4.0 },
	{ -8.5 }
)
print("Encoded buffer bytes:", buffer.len(pkt))