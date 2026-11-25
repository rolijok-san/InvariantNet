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

local Players = game:GetService("Players")

local Packet = require(script.Parent.Packet)

export type ChannelKind = "Reliable" | "Unreliable"

export type InboundBatch = {
	header: {
		version: number,
		epoch: number,
		subspaceId: number,
		reliable: boolean,
		digest: number,
		count: number,
	},
	count: number,
	entityIds: { number },
	quotientClasses: { number },
	xs: { number },
	ys: { number },
	zs: { number },
}

export type ChannelConfig = {
	reliableRemote: RemoteEvent,
	unreliableRemote: UnreliableRemoteEvent,
	maxInboundBytesPerWindow: number?,
	windowSeconds: number?,
	maxPacketBytes: number?,
	maxUnreliablePacketBytes: number?,
	onDroppedOutbound: ((player: Player?, channel: ChannelKind, byteLen: number, reason: string) -> ())?,
}

export type Router = {
	reliableRemote: RemoteEvent,
	unreliableRemote: UnreliableRemoteEvent,
	maxPacketBytes: number,
	maxUnreliablePacketBytes: number,
	windowSeconds: number,
	maxInboundBytesPerWindow: number,
	sendToPlayer: (self: Router, player: Player, channel: ChannelKind, pkt: buffer) -> boolean,
	sendToList: (self: Router, players: { Player }, channel: ChannelKind, pkt: buffer, exclude: Player?) -> number,
	broadcast: (self: Router, channel: ChannelKind, pkt: buffer, exclude: Player?) -> number,
	allowInbound: (self: Router, player: Player, pkt: buffer) -> (boolean, string?),
	decodeInbound: (self: Router, player: Player, pkt: buffer) -> (InboundBatch?, string?),
	getDroppedStats: (self: Router) -> (number, number),
	cleanupPlayer: (self: Router, player: Player) -> (),
	destroy: (self: Router) -> (),
}

local DEFAULT_MAX_PACKET_BYTES: number = Packet.HEADER_BYTES + 16_384 * Packet.RECORD_BYTES
local DEFAULT_MAX_UNRELIABLE_BYTES: number = 900
local DEFAULT_WINDOW_SECONDS: number = 1.0
local DEFAULT_MAX_INBOUND_BYTES: number = 65_536

local ChannelRouter = {}
ChannelRouter.__index = ChannelRouter

local function dispatchReliable(remote: RemoteEvent, player: Player, pkt: buffer): boolean
	if player.Parent == nil then
		return false
	end
	remote:FireClient(player, pkt)
	return true
end

local function dispatchUnreliable(remote: UnreliableRemoteEvent, player: Player, pkt: buffer): boolean
	if player.Parent == nil then
		return false
	end
	remote:FireClient(player, pkt)
	return true
end

function ChannelRouter.new(config: ChannelConfig): Router
	local windowSec: number = config.windowSeconds or DEFAULT_WINDOW_SECONDS
	assert(windowSec > 0, "windowSeconds must be positive")

	local maxPktBytes: number = config.maxPacketBytes or DEFAULT_MAX_PACKET_BYTES
	assert(maxPktBytes >= Packet.HEADER_BYTES, "maxPacketBytes smaller than header")

	local maxUnreliableBytes: number = config.maxUnreliablePacketBytes or DEFAULT_MAX_UNRELIABLE_BYTES
	assert(maxUnreliableBytes >= Packet.HEADER_BYTES and maxUnreliableBytes <= maxPktBytes, "invalid maxUnreliablePacketBytes")

	local maxInbound: number = config.maxInboundBytesPerWindow or DEFAULT_MAX_INBOUND_BYTES
	assert(maxInbound > 0, "maxInboundBytesPerWindow must be positive")

	local reliableRemote = config.reliableRemote
	local unreliableRemote = config.unreliableRemote

	local byteAcc: { [Player]: number } = {}
	local windowStart: { [Player]: number } = {}
	local onDropped = config.onDroppedOutbound
	local droppedPackets = 0
	local droppedBytes = 0
	local destroyed = false

	local function recordDrop(player: Player?, channel: ChannelKind, byteLen: number, reason: string): ()
		droppedPackets += 1
		droppedBytes += byteLen
		if onDropped ~= nil then
			onDropped(player, channel, byteLen, reason)
		end
	end

	local function checkOutbound(player: Player?, channel: ChannelKind, pkt: buffer): boolean
		if destroyed then
			return false
		end
		local size = buffer.len(pkt)
		local capBytes = if channel == "Unreliable" then maxUnreliableBytes else maxPktBytes
		if size > capBytes then
			recordDrop(
				player,
				channel,
				size,
				if channel == "Unreliable" then "unreliable packet exceeds budget" else "packet exceeds maxPacketBytes"
			)
			return false
		end
		return true
	end

	local function sendSingle(player: Player, channel: ChannelKind, pkt: buffer): boolean
		if channel == "Reliable" then
			return dispatchReliable(reliableRemote, player, pkt)
		end
		return dispatchUnreliable(unreliableRemote, player, pkt)
	end

	local self: Router = setmetatable({
		reliableRemote = reliableRemote,
		unreliableRemote = unreliableRemote,
		maxPacketBytes = maxPktBytes,
		maxUnreliablePacketBytes = maxUnreliableBytes,
		windowSeconds = windowSec,
		maxInboundBytesPerWindow = maxInbound,
	}, ChannelRouter) :: any

	function self:sendToPlayer(player: Player, channel: ChannelKind, pkt: buffer): boolean
		if not checkOutbound(player, channel, pkt) then
			return false
		end
		return sendSingle(player, channel, pkt)
	end

	function self:sendToList(players: { Player }, channel: ChannelKind, pkt: buffer, exclude: Player?): number
		if not checkOutbound(nil, channel, pkt) then
			return 0
		end
		local sent = 0
		for i = 1, #players do
			local plr = players[i]
			if plr ~= exclude and sendSingle(plr, channel, pkt) then
				sent += 1
			end
		end
		return sent
	end

	function self:broadcast(channel: ChannelKind, pkt: buffer, exclude: Player?): number
		if not checkOutbound(nil, channel, pkt) then
			return 0
		end
		local all = Players:GetPlayers()
		local sent = 0
		for i = 1, #all do
			local plr = all[i]
			if plr ~= exclude and sendSingle(plr, channel, pkt) then
				sent += 1
			end
		end
		return sent
	end

	function self:allowInbound(player: Player, pkt: buffer): (boolean, string?)
		if destroyed then
			return false, "router destroyed"
		end
		if typeof(pkt) ~= "buffer" then
			return false, "expected buffer"
		end

		local size = buffer.len(pkt)
		if size < Packet.HEADER_BYTES or size > self.maxPacketBytes then
			return false, "invalid packet byte length"
		end

		local now = os.clock()
		local start = windowStart[player]
		if start == nil or (now - start) >= self.windowSeconds then
			windowStart[player] = now
			byteAcc[player] = size
			return true, nil
		end

		local nextTotal = (byteAcc[player] or 0) + size
		if nextTotal > self.maxInboundBytesPerWindow then
			return false, "inbound rate limit exceeded"
		end

		byteAcc[player] = nextTotal
		return true, nil
	end

	function self:decodeInbound(player: Player, pkt: buffer): (InboundBatch?, string?)
		local ok, reason = self:allowInbound(player, pkt)
		if not ok then
			return nil, reason
		end
		return Packet.decodeBatch(pkt, self.maxPacketBytes)
	end

	function self:getDroppedStats(): (number, number)
		return droppedPackets, droppedBytes
	end

	function self:cleanupPlayer(player: Player): ()
		byteAcc[player] = nil
		windowStart[player] = nil
	end

	function self:destroy(): ()
		if destroyed then
			return
		end
		destroyed = true
		table.clear(byteAcc)
		table.clear(windowStart)
	end

	return self
end

return ChannelRouter