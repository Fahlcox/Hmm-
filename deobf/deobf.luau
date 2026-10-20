--[[
	Luarmor V4 loader runner / deobfuscator harness (Lune)

	Usage:
		lune run deobf.luau <loader.lua> [outdir]

	It:
	  * provides a pure-Luau `buffer` implementation (Lune's buffer lib is incomplete)
	  * stubs Roblox / executor globals
	  * runs the Luarmor VM loader
	  * shadows every buffer write so the decrypted Luau bytecode can be recovered
	  * dumps recovered buffers to <outdir>
--]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local luau = require("@lune/luau")

local path = process.args[1] or "/tmp/paste.txt"
local outDir = process.args[2] or "/tmp/luarmor_out"
pcall(function()
	fs.createDir(outDir)
end)

local src = fs.readFile(path)

--------------------------------------------------------------------- buffer
local Buffer = {}
Buffer.__index = Buffer

local function newBuffer(size)
	return setmetatable({ data = {}, size = size or 0 }, Buffer)
end

function Buffer:readu8(pos)
	return self.data[pos + 1] or 0
end

function Buffer:readu16(pos)
	local a, b = self:readu8(pos), self:readu8(pos + 1)
	return a + b * 256
end

function Buffer:readi16(pos)
	local v = self:readu16(pos)
	if v >= 32768 then
		return v - 65536
	end
	return v
end

function Buffer:readu32(pos)
	local a, b, c, d = self:readu8(pos), self:readu8(pos + 1), self:readu8(pos + 2), self:readu8(pos + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end

function Buffer:readf32(pos)
	local bytes = {}
	for i = 0, 3 do
		bytes[i + 1] = string.char(self:readu8(pos + i))
	end
	return string.unpack("<f", table.concat(bytes))
end

function Buffer:writeu8(pos, value)
	self.data[pos + 1] = value % 256
	if pos + 1 > self.size then
		self.size = pos + 1
	end
end

function Buffer:writeu16(pos, value)
	self:writeu8(pos, value % 256)
	self:writeu8(pos + 1, math.floor(value / 256) % 256)
end

function Buffer:writei16(pos, value)
	if value < 0 then
		value = value + 65536
	end
	self:writeu16(pos, value)
end

function Buffer:writeu32(pos, value)
	self:writeu8(pos, value % 256)
	self:writeu8(pos + 1, math.floor(value / 256) % 256)
	self:writeu8(pos + 2, math.floor(value / 65536) % 256)
	self:writeu8(pos + 3, math.floor(value / 16777216) % 256)
end

function Buffer:copy(target, targetPos, source, sourcePos, size)
	for i = 0, size - 1 do
		target:writeu8(targetPos + i, source:readu8(sourcePos + i))
	end
end

function Buffer:tostring()
	local parts = {}
	for i = 1, self.size do
		parts[i] = string.char(self.data[i] or 0)
	end
	return table.concat(parts)
end

local createdBuffers = {}

local bufferLib = {
	create = function(size)
		local b = newBuffer(size)
		createdBuffers[#createdBuffers + 1] = b
		return b
	end,
	fromstring = function(s)
		local b = newBuffer(#s)
		for i = 1, #s do
			b.data[i] = string.byte(s, i)
		end
		createdBuffers[#createdBuffers + 1] = b
		return b
	end,
	len = function(b)
		return b.size
	end,
}
bufferLib.readu8 = function(b, pos)
	return b:readu8(pos)
end
bufferLib.readu16 = function(b, pos)
	return b:readu16(pos)
end
bufferLib.readi16 = function(b, pos)
	return b:readi16(pos)
end
bufferLib.readu32 = function(b, pos)
	return b:readu32(pos)
end
bufferLib.readf32 = function(b, pos)
	return b:readf32(pos)
end
bufferLib.writeu8 = function(b, pos, v)
	return b:writeu8(pos, v)
end
bufferLib.writeu16 = function(b, pos, v)
	return b:writeu16(pos, v)
end
bufferLib.writei16 = function(b, pos, v)
	return b:writei16(pos, v)
end
bufferLib.writeu32 = function(b, pos, v)
	return b:writeu32(pos, v)
end
bufferLib.copy = function(target, targetPos, source, sourcePos, size)
	return target:copy(target, targetPos, source, sourcePos, size)
end
bufferLib.fill = function(b, offset, count, value)
	for i = 0, count - 1 do
		b:writeu8(offset + i, value or 0)
	end
end
bufferLib.tostring = function(b)
	return b:tostring()
end

----------------------------------------------------------------- environment
local apiLog = {}
local function makeStub(name)
	return setmetatable({}, {
		__index = function(_, k)
			apiLog[#apiLog + 1] = string.format("%s.%s", name, tostring(k))
			return function(...)
				local args = {}
				for i = 1, select("#", ...) do
					local a = select(i, ...)
					args[i] = type(a) == "string" and string.format("%q", a:sub(1, 200)) or tostring(a)
				end
				apiLog[#apiLog + 1] = string.format("%s.%s(%s)", name, tostring(k), table.concat(args, ","))
				return makeStub(name .. "." .. tostring(k))
			end
		end,
		__call = function()
			return makeStub(name)
		end,
		__tostring = function()
			return name
		end,
	})
end

local env = {
	__buf = bufferLib,
	_bsdata0 = setmetatable({ [11] = "\0", [12] = "\0" }, {
		__index = function()
			return "\0"
		end,
	}),
}

local roboxGlobals = {
	Vector2 = true, Vector3 = true, Color3 = true, CFrame = true, UDim = true,
	UDim2 = true, UDim3 = true, Rect = true, Region3 = true, Ray = true,
	Random = true, Instance = true, NumberRange = true, NumberSequence = true,
	PhysicalProperties = true, Workspace = true, Lighting = true,
	ReplicatedStorage = true, ServerScriptService = true, Players = true,
	SoundService = true, StarterGui = true, StarterPlayer = true, Teams = true,
	TextService = true, TweenService = true, UserInputService = true,
	RunService = true, HttpService = true, MarketplaceService = true,
	InsertService = true, ContentProvider = true, CollectionService = true,
	Debris = true, PathfindingService = true, PhysicsService = true,
	Settings = true, GuiService = true, Enum = true, DateTime = true,
	Region3int16 = true, RaycastParams = true, OverlapParams = true,
}
for name in roboxGlobals do
	env[name] = makeStub(name)
end

env.task = {
	wait = function()
		local t = os.clock()
		while os.clock() - t < 0.05 do
		end
		return 0
	end,
	delay = function()
		return 0
	end,
	spawn = function(fn, ...)
		return fn(...)
	end,
	cancel = function() end,
	defer = function() end,
	desynchronize = function() end,
}
env.game = makeStub("game")
env.workspace = makeStub("workspace")
env.warn = function(...)
	print("[warn]", ...)
end
env.tick = function()
	return os.clock()
end
env.wait = function()
	return 0
end
env.spawn = function(fn, ...)
	return fn(...)
end
env.delay = function()
	return 0
end
env.identifyexecutor = function()
	return "Lune"
end
env.getexecutorname = function()
	return "Lune"
end
env.checkexecutor = function()
	return true
end
env.newproxy = function()
	return makeStub("newproxy")
end
env.setfenv = function() end
env.getfenv = function()
	return env
end
env.getgenv = function()
	return env
end
env._G = env
env.new = makeStub("new")
env.Path2DControlPoint = makeStub("Path2DControlPoint")
env.debug = {
	traceback = function()
		return ""
	end,
	info = function()
		return { name = "lune" }
	end,
	getinfo = function()
		return { name = "lune" }
	end,
	sethook = function() end,
}
env.getfenv = function()
	return env
end
env.loadstring = function(s)
	print("[capture] loadstring, len", #tostring(s))
	pcall(function()
		fs.writeFile(outDir .. "/loadstring_capture.txt", tostring(s))
	end)
	return function()
		return true
	end
end
env.load = env.loadstring

---------------------------------------------------------- patch + run loader
-- expose the VM table so we can wrap it
local useNative = process.args[3] == "--native"
local patched = useNative and src or src:gsub("buffer%.", "__buf.")
local s1, e1 = patched:find("return setmetatable({", 1, true)
assert(s1, "could not find VM table")
patched = patched:sub(1, s1 - 1) .. "local __T=setmetatable({" .. patched:sub(e1 + 1)
local s2 = patched:find("}):t_()(", 1, true)
assert(s2, "could not find VM entrypoint")
local rest = patched:sub(s2 + #"}):t_()(")
patched = patched:sub(1, s2 - 1) .. "});__WRAP__(__T);return __T:t_()(" .. rest

local writes = {} -- buffer id -> { [pos] = byte }
local captured = {} -- decoded string constants
local bufferNames = {}
local nameOf = {}
for key, lib in {
	buffer = bufferLib,
} do
	for fn, val in lib do
		nameOf[val] = key .. "." .. fn
	end
end
for _, fn in { "sub", "byte", "format", "gmatch", "gsub", "rep", "find", "upper", "lower" } do
	nameOf[string[fn]] = "string." .. fn
end
for _, fn in { "move", "insert", "concat", "create", "unpack" } do
	nameOf[table[fn]] = "table." .. fn
end
for _, fn in { "band", "bor", "bxor", "bnot", "lshift", "rshift", "extract" } do
	nameOf[bit32[fn]] = "bit32." .. fn
end
nameOf[coroutine.yield] = "coroutine.yield"
nameOf[coroutine.status] = "coroutine.status"
nameOf[coroutine.create] = "coroutine.create"

local trace = process.args[3] == "--trace"
local log = {}

env.__WRAP__ = function(T)
	for k, v in T do
		if type(v) == "function" then
			local label = nameOf[v] or tostring(k)
			T[k] = function(...)
				if #apiLog > 0 then
	pcall(function()
		fs.writeFile(outDir .. "/api_calls.txt", table.concat(apiLog, "\n"))
	end)
	print("api calls logged:", #apiLog)
end

if #captured > 0 then
	pcall(function()
		fs.writeFile(outDir .. "/strings.txt", table.concat(captured, "\n"))
	end)
	print("captured strings:", #captured)
end

if trace then
					local parts = {}
					for i = 1, select("#", ...) do
						local a = select(i, ...)
						parts[i] = type(a) == "string" and string.format("%q", a:sub(1, 60)) or tostring(a)
					end
					log[#log + 1] = string.format("%s(%s)", label, table.concat(parts, ","))
					if #log > 200 then
						table.remove(log, 1)
					end
				end

				if k == 31 or k == 37 or k == 65 or k == 106 then
					-- buffer writeu32 / writeu16 / writei16 / writeu8
					local buf, pos, val = ...
					local id = tostring(buf)
					local map = writes[id]
					if not map then
						map = {}
						writes[id] = map
						bufferNames[id] = label
					end
					local width = (k == 31 and 4) or (k == 106 and 1) or 2
					for i = 0, width - 1 do
						map[pos + i] = val % 256
						val = math.floor(val / 256)
					end
				elseif k == 112 then
					-- buffer.create
					local id = tostring(select(1, ...))
					bufferNames[id] = "create:" .. tostring(select(1, ...))
				end

				local okc, res
				if label:sub(1, 7) == "buffer." then
					okc, res = pcall(table.pack, v, ...)
					if not okc then
						error(string.format("VMFUNC %s: %s", label, tostring(res)), 0)
					end
				else
					res = table.pack(v(...))
				end
				if k == 53 then
					-- buffer.tostring: decoded string constant
					local str = res[1]
					if type(str) == "string" and #str > 0 then
						captured[#captured + 1] = str
					end
				end
				return table.unpack(res, 1, res.n)
			end
		end
	end
end

print("patched has __buf.create:", patched:find("__buf%.create") ~= nil, "buffer. left:", select(2, patched:gsub("buffer%.", "")))
print("createdBuffers before:", #createdBuffers)
local f, err = luau.load(patched, { debugName = "luarmor", environment = env })
if not f then
	error("load failed: " .. tostring(err))
end

local ok, res = xpcall(f, function(e)
	local tail = {}
	for i = math.max(1, #log - 25), #log do
		tail[#tail + 1] = log[i]
	end
	return tostring(e) .. "\n" .. debug.traceback() .. "\n--- tail ---\n" .. table.concat(tail, "\n")
end)
print("run ok:", ok, tostring(res))

------------------------------------------------------------------- dump data
local index = 0
for _, buf in createdBuffers do
	index += 1
	local data = buf:tostring()
	if #data > 16 then
		local outPath = string.format("%s/live_%02d.bin", outDir, index)
		pcall(function()
			fs.writeFile(outPath, data)
		end)
		print("live buffer", index, "size", #data)
	end
end

for id, map in writes do
	local maxPos = 0
	for pos in map do
		if pos > maxPos then
			maxPos = pos
		end
	end
	if maxPos < 16 then
		continue
	end
	index += 1
	local bytes = {}
	for i = 0, maxPos do
		bytes[i + 1] = string.char(map[i] or 0)
	end
	local data = table.concat(bytes)
	local outPath = string.format("%s/buf_%02d_%s.bin", outDir, index, bufferNames[id] or "buf")
	pcall(function()
		fs.writeFile(outPath, data)
	end)
	print("dumped", outPath, "size", maxPos + 1)
end

if #apiLog > 0 then
	pcall(function()
		fs.writeFile(outDir .. "/api_calls.txt", table.concat(apiLog, "\n"))
	end)
	print("api calls logged:", #apiLog)
end

if #captured > 0 then
	pcall(function()
		fs.writeFile(outDir .. "/strings.txt", table.concat(captured, "\n"))
	end)
	print("captured strings:", #captured)
end

if trace then
	pcall(function()
		fs.writeFile(outDir .. "/trace.txt", table.concat(log, "\n"))
	end)
end
