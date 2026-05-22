--[[
    NovaDec v3.1 — Runtime Closure Decompiler
    Does NOT use broken decompile() or raw bytecode opcodes
    Uses getscriptclosure + debug API to walk live closures
    + API decompile with smart code cleanup
    Works on Delta, Arceus X, Fluxus — any executor with debug lib
]]

pcall(function()
    if game:GetService("CoreGui"):FindFirstChild("NovaDecGUI") then
        game:GetService("CoreGui"):FindFirstChild("NovaDecGUI"):Destroy()
    end
end)

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

local C = {
    bg=Color3.fromRGB(13,13,18), bg2=Color3.fromRGB(20,20,28), bg3=Color3.fromRGB(26,26,36),
    srf=Color3.fromRGB(30,30,42), srfH=Color3.fromRGB(38,38,52),
    acc=Color3.fromRGB(99,102,241), accH=Color3.fromRGB(129,140,248), accD=Color3.fromRGB(67,56,202),
    grn=Color3.fromRGB(34,197,94), red=Color3.fromRGB(239,68,68), yel=Color3.fromRGB(245,158,11),
    t1=Color3.fromRGB(240,240,255), t2=Color3.fromRGB(148,148,180), t3=Color3.fromRGB(100,100,130),
    bdr=Color3.fromRGB(42,42,60),
}

local function corner(p,r) local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,r or 8); c.Parent=p end
local function stk(p,col,t) local s=Instance.new("UIStroke"); s.Color=col or C.bdr; s.Thickness=t or 1; s.ApplyStrokeMode=Enum.ApplyStrokeMode.Border; s.Parent=p; return s end
local function tw(o,p,d) TS:Create(o,TweenInfo.new(d or 0.3,Enum.EasingStyle.Quint,Enum.EasingDirection.Out),p):Play() end

local function makeDrag(handle,frame)
    local dragging,dragInput,dragStart,startPos
    handle.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
            dragging=true; dragStart=i.Position; startPos=frame.Position
            i.Changed:Connect(function() if i.UserInputState==Enum.UserInputState.End then dragging=false end end)
        end
    end)
    handle.InputChanged:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch then dragInput=i end end)
    UIS.InputChanged:Connect(function(i) if i==dragInput and dragging then local d=i.Position-dragStart; frame.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y) end end)
end

-- ═══════════════════════════════════════════════════════════
-- DECOMPILER ENGINE
-- ═══════════════════════════════════════════════════════════

local _getconstants = getconstants or debug.getconstants
local _getupvalues = getupvalues or debug.getupvalues
local _getprotos = getprotos or debug.getprotos
local _debuginfo = debug.info
local _getscriptclosure = getscriptclosure
local _getsenv = getsenv
local _request = request or http_request or (syn and syn.request)
local _getscriptbytecode = getscriptbytecode

-- Base64
local function b64(data)
    if crypt and crypt.base64encode then
        local ok, r = pcall(crypt.base64encode, data)
        if ok and r then return r end
    end
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local result = {}
    local pad = (3 - #data % 3) % 3
    data = data .. string.rep("\0", pad)
    for i = 1, #data, 3 do
        local b1, b2, b3 = data:byte(i, i + 2)
        local n = b1 * 65536 + b2 * 256 + b3
        result[#result+1] = chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result+1] = chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        result[#result+1] = chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
        result[#result+1] = chars:sub(n % 64 + 1, n % 64 + 1)
    end
    for i = 1, pad do result[#result - i + 1] = "=" end
    return table.concat(result)
end

-- Format value
local function fmtVal(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    if depth > 4 then return "{...}" end
    local t = typeof(v)
    if v == nil then return "nil"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then
        if v ~= v then return "0/0" end
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        if v == math.floor(v) and math.abs(v) < 2^53 then return tostring(math.floor(v)) end
        return tostring(v)
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "function" then
        return "function() end"
    elseif t == "table" then
        if seen[v] then return "{--[[circular]]}" end
        seen[v] = true
        local parts = {}
        for i = 1, math.min(#v, 20) do parts[#parts+1] = fmtVal(v[i], depth+1, seen) end
        local hc = 0
        for k, val in pairs(v) do
            if type(k) ~= "number" or k < 1 or k > #v then
                hc = hc + 1
                if hc > 15 then parts[#parts+1] = "-- ..."; break end
                local ks = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("["..fmtVal(k, depth+1, seen).."]")
                parts[#parts+1] = ks .. " = " .. fmtVal(val, depth+1, seen)
            end
        end
        seen[v] = nil
        if #parts == 0 then return "{}" end
        local ind = string.rep("    ", depth+1)
        return "{\n" .. ind .. table.concat(parts, ",\n"..ind) .. "\n" .. string.rep("    ", depth) .. "}"
    elseif t == "Vector3" then return "Vector3.new("..v.X..", "..v.Y..", "..v.Z..")"
    elseif t == "Vector2" then return "Vector2.new("..v.X..", "..v.Y..")"
    elseif t == "CFrame" then return "CFrame.new("..tostring(v)..")"
    elseif t == "Color3" then return string.format("Color3.new(%g,%g,%g)", v.R, v.G, v.B)
    elseif t == "UDim2" then return "UDim2.new("..v.X.Scale..","..v.X.Offset..","..v.Y.Scale..","..v.Y.Offset..")"
    elseif t == "EnumItem" then return tostring(v)
    elseif t == "Instance" then
        local ok2, fp = pcall(function() return v:GetFullName() end)
        return ok2 and fp or tostring(v)
    else return tostring(v) end
end

-- API decompile
local function tryAPI(inst)
    if not _getscriptbytecode or not _request then return nil end
    local ok, bc = pcall(_getscriptbytecode, inst)
    if not ok or not bc or #bc == 0 then return nil end
    local enc = b64(bc)
    if not enc then return nil end
    local rok, res = pcall(_request, {
        Url = "https://api.lua.expert/decompile",
        Method = "POST",
        Headers = {["content-type"] = "application/json"},
        Body = HttpService:JSONEncode({script = enc})
    })
    if rok and res and res.StatusCode == 200 and res.Body and #res.Body > 30 then
        local body = res.Body
        pcall(function()
            local p = HttpService:JSONDecode(body)
            if p then body = p.output or p.result or p.source or body end
        end)
        if type(body) == "string" and #body > 30 and not body:match("^<!") then
            return body
        end
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════
-- CODE CLEANUP — makes API output much more readable
-- ═══════════════════════════════════════════════════════════
local function cleanupCode(code, scriptName)
    local result = code

    -- Derive module name from script name
    local modName = scriptName:match("[^%.]+$") or scriptName
    modName = modName:gsub("[^%w_]", "")
    if modName == "" then modName = "Module" end

    -- Find the main table variable: local X = {} then X.__index = X
    local mainVar = result:match("local (%w+) = {}\r?\n%w+%.__index")
    
    -- Rename short generic main var to module name
    if mainVar and #mainVar <= 3 and mainVar ~= modName then
        result = result:gsub("([^%w_])" .. mainVar .. "([^%w_])", "%1" .. modName .. "%2")
        result = result:gsub("^" .. mainVar .. "([^%w_])", modName .. "%1")
        -- Need two passes for adjacent replacements
        result = result:gsub("([^%w_])" .. mainVar .. "([^%w_])", "%1" .. modName .. "%2")
    end

    -- Rename p1 to self in method bodies
    -- First convert .method(p1, ...) to :method(...)
    result = result:gsub("function (%w+)%.(%w+)%(p1,?%s*", function(tbl, method)
        return "function " .. tbl .. ":" .. method .. "("
    end)
    -- Fix :method() with no other params
    result = result:gsub(":(%w+)%(%)%s*$", ":%1()")
    
    -- Replace p1 with self throughout
    result = result:gsub("([^%w_])p1([^%w_])", "%1self%2")
    result = result:gsub("([^%w_])p1([^%w_])", "%1self%2") -- second pass
    result = result:gsub("([^%w_])p1$", "%1self")

    -- v2 = setmetatable({}, X) → self = setmetatable
    local setmetaVar = result:match("local (%w+) = setmetatable%({}, %w+%)")
    if setmetaVar and #setmetaVar <= 3 then
        result = result:gsub("local " .. setmetaVar .. " = setmetatable", "local self = setmetatable")
        result = result:gsub("([^%w_])" .. setmetaVar .. "([^%w_])", "%1self%2")
        result = result:gsub("([^%w_])" .. setmetaVar .. "([^%w_])", "%1self%2")
        result = result:gsub("([^%w_])" .. setmetaVar .. "$", "%1self")
    end

    -- p2 used as key in _connections[p2] → "key"
    if result:find("_connections%[p2%]") or result:find("_%w+%[p2%]") then
        result = result:gsub("([^%w_])p2([^%w_])", "%1key%2")
        result = result:gsub("([^%w_])p2([^%w_])", "%1key%2")
    end

    -- p3 with :Disconnect() → "connection"
    if result:find("p3:Disconnect") then
        result = result:gsub("([^%w_])p3([^%w_])", "%1connection%2")
        result = result:gsub("([^%w_])p3([^%w_])", "%1connection%2")
    -- p3 as cleanup/unbind function being called: p3() → "cleanupFn"
    elseif result:find("p3%(") then
        result = result:gsub("([^%w_])p3([^%w_])", "%1cleanupFn%2")
        result = result:gsub("([^%w_])p3([^%w_])", "%1cleanupFn%2")
    end

    -- Remove all "local vN = nil" lines (nil is default, just noise)
    result = result:gsub("\n[^\n]*local %w+ = nil[^\n]*", "")
    -- Remove standalone "vN = nil" assignments
    result = result:gsub("\n(%s+)%w+ = nil%s*\n", "\n%1\n")

    -- Remove decompiler comment noise: --[[ ... ]]
    result = result:gsub("%s*%-%-+%[%[.-%]%]", "")
    -- Remove URL comments
    result = result:gsub("\n%s*%-%-+ https?://[^\n]*", "")

    -- Fix colon methods that still have self as first param
    result = result:gsub("(function %w+:%w+%()self,?%s*", "%1")

    -- game.Workspace → workspace
    result = result:gsub("game%.Workspace", "workspace")
    result = result:gsub('game:GetService%("Workspace"%)', "workspace")

    -- Collapse 3+ blank lines to 2
    result = result:gsub("\n\n\n+", "\n\n")

    -- Trim leading/trailing whitespace
    result = result:match("^%s*(.-)%s*$")

    return result
end

-- ═══════════════════════════════════════════════════════════
-- RUNTIME CLOSURE WALKER (fallback when API unavailable)
-- ═══════════════════════════════════════════════════════════
local function closureWalk(inst)
    local sType = inst:IsA("ModuleScript") and "ModuleScript" or inst:IsA("LocalScript") and "LocalScript" or "Script"
    local out = {}
    local function add(s) out[#out+1] = s end
    add("-- NovaDec v3.1 Runtime Reconstruction")
    add("-- Script: " .. inst:GetFullName())
    add("-- Type: " .. sType)
    add("")

    local closure
    if _getscriptclosure then pcall(function() closure = _getscriptclosure(inst) end) end
    local senv
    if _getsenv and sType ~= "ModuleScript" then pcall(function() senv = _getsenv(inst) end) end
    local modResult
    if sType == "ModuleScript" then pcall(function() modResult = require(inst) end) end

    if not closure and not senv and modResult == nil then return nil end

    local visited = {}
    local fc = 0

    local function walk(func, name, depth)
        if not func or visited[func] then return end
        visited[func] = true
        fc = fc + 1
        depth = depth or 0
        local pad = string.rep("    ", depth)
        local inner = pad .. (depth > 0 and "    " or "")

        local fN, fA, fV
        if _debuginfo then pcall(function() fN, fA, fV = _debuginfo(func, "nav") end) end
        local dn = (fN and fN ~= "") and fN or name or ("func" .. fc)
        local params = {}
        for p = 1, (fA or 0) do params[#params+1] = string.char(96 + ((p-1)%26) + 1) end
        if fV then params[#params+1] = "..." end

        local upv = {}
        if _getupvalues then pcall(function() upv = _getupvalues(func) end) end
        local con = {}
        if _getconstants then pcall(function() con = _getconstants(func) end) end
        local pro = {}
        if _getprotos then pcall(function() pro = _getprotos(func) end) end

        if depth > 0 then
            add(pad .. "local function " .. dn .. "(" .. table.concat(params, ", ") .. ")")
        end

        -- Upvalues (skip nil, smart names)
        local fups = {}
        local hasUpvals = false
        if next(upv) then
            local ks = {}
            for k in pairs(upv) do ks[#ks+1] = k end
            table.sort(ks, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
            for _, k in ipairs(ks) do
                local v = upv[k]
                if v == nil then
                    -- skip nil entirely
                elseif typeof(v) == "function" then
                    fups[#fups+1] = {n = type(k) == "string" and k or ("fn_" .. k), f = v}
                else
                    hasUpvals = true
                    local vn
                    if type(k) == "string" then
                        vn = k
                    else
                        local vt = typeof(v)
                        if vt == "Instance" then
                            local ok3, nm = pcall(function() return v.Name end)
                            vn = ok3 and nm:gsub("[^%w_]", "") or ("inst" .. k)
                            if vn == "" then vn = "inst" .. k end
                            vn = vn:sub(1,1):lower() .. vn:sub(2)
                        elseif vt == "boolean" then vn = v and ("enabled" .. k) or ("disabled" .. k)
                        elseif vt == "number" then vn = (v == math.floor(v)) and ("count" .. k) or ("value" .. k)
                        elseif vt == "string" then
                            if #v > 2 and #v < 20 and v:match("^[%a_][%w_]*$") then vn = v
                            else vn = "text" .. k end
                        elseif vt == "table" then vn = "data" .. k
                        else vn = vt:sub(1,1):lower() .. vt:sub(2):gsub("[^%w]", "") .. k end
                    end
                    add(inner .. "local " .. vn .. " = " .. fmtVal(v, depth+1))
                end
            end
            if hasUpvals then add("") end
            for _, fu in ipairs(fups) do walk(fu.f, fu.n, depth > 0 and depth+1 or depth) end
        end

        -- Constants (clean reconstruction)
        if #con > 0 then
            local codeLines = {}
            local stringLits = {}
            local emittedSvc = {}
            local i = 1
            while i <= #con do
                local k = con[i]
                if k == nil then i = i + 1
                elseif type(k) == "string" then
                    local nxt = con[i+1]
                    if k == "GetService" and nxt and type(nxt) == "string" and not emittedSvc[nxt] then
                        emittedSvc[nxt] = true
                        local vn = nxt:gsub("Service$", "")
                        vn = vn:sub(1,1):lower() .. vn:sub(2)
                        codeLines[#codeLines+1] = "local " .. vn .. ' = game:GetService("' .. nxt .. '")'
                        i = i + 2
                    elseif (k == "FindFirstChild" or k == "WaitForChild" or k == "FindFirstChildOfClass") and nxt and type(nxt) == "string" then
                        codeLines[#codeLines+1] = ":" .. k .. '("' .. nxt .. '")'
                        i = i + 2
                    elseif k == "Connect" or k == "connect" then
                        codeLines[#codeLines+1] = ":Connect(function() ... end)"
                        i = i + 1
                    elseif k == "FireServer" or k == "InvokeServer" then
                        codeLines[#codeLines+1] = ":" .. k .. "(...)"
                        i = i + 1
                    elseif k == "new" and nxt and type(nxt) == "string" then
                        codeLines[#codeLines+1] = 'Instance.new("' .. nxt .. '")'
                        i = i + 2
                    elseif k:match("^[A-Z][%a]+$") and #k > 2 then
                        if nxt and type(nxt) == "string" and not nxt:match("^[A-Z]") then
                            codeLines[#codeLines+1] = ":" .. k .. '("' .. nxt .. '")'
                            i = i + 2
                        else
                            codeLines[#codeLines+1] = ":" .. k .. "(...)"
                            i = i + 1
                        end
                    elseif k:match("Changed$") or k:match("Added$") or k == "Heartbeat" or k == "Touched" or k:match("^On%u") then
                        codeLines[#codeLines+1] = "." .. k .. ":Connect(function() ... end)"
                        i = i + 1
                    elseif k:match("^[a-z_][%w_]*$") and #k > 1 then
                        codeLines[#codeLines+1] = "." .. k
                        i = i + 1
                    else
                        if #k > 0 and #k < 80 then stringLits[#stringLits+1] = string.format("%q", k) end
                        i = i + 1
                    end
                elseif type(k) == "number" then
                    if k ~= 0 and k ~= 1 and k ~= 2 and k ~= -1 and k ~= 0.5 then
                        codeLines[#codeLines+1] = "-- " .. tostring(k)
                    end
                    i = i + 1
                else i = i + 1 end
            end
            for _, l in ipairs(codeLines) do add(inner .. l) end
            if #stringLits > 0 then
                add(inner .. "-- Strings: " .. table.concat(stringLits, ", "))
            end
            if #codeLines > 0 or #stringLits > 0 then add("") end
        end

        -- Child protos
        for idx, proto in ipairs(pro) do
            if type(proto) == "function" and not visited[proto] then
                local pN
                if _debuginfo then pcall(function() pN = _debuginfo(proto, "n") end) end
                walk(proto, pN or ("func" .. fc + idx), depth > 0 and depth+1 or depth)
            end
        end

        if depth > 0 then add(pad .. "end"); add("") end
    end

    if closure then
        add("-- Root Closure")
        add("")
        pcall(walk, closure, "main", 0)
    end

    if senv then
        add("")
        add("-- Script Environment")
        add("")
        local envVars = {}
        local envFuncs = {}
        for k, v in pairs(senv) do
            if type(k) == "string" and v ~= nil then
                if typeof(v) == "function" then
                    envFuncs[#envFuncs+1] = {k = k, v = v}
                else
                    envVars[#envVars+1] = {k = k, v = v}
                end
            end
        end
        table.sort(envVars, function(a, b) return a.k < b.k end)
        table.sort(envFuncs, function(a, b) return a.k < b.k end)
        for _, ev in ipairs(envVars) do add(ev.k .. " = " .. fmtVal(ev.v, 0)) end
        if #envVars > 0 then add("") end
        for _, ef in ipairs(envFuncs) do
            if not visited[ef.v] then walk(ef.v, ef.k, 0) end
        end
    end

    if modResult ~= nil then
        add("")
        add("-- Module Return Value")
        add("return " .. fmtVal(modResult, 0))
    end

    return table.concat(out, "\n")
end

-- Full decompile
local function fullDecompile(inst)
    local sType = inst:IsA("ModuleScript") and "ModuleScript" or inst:IsA("LocalScript") and "LocalScript" or "Script"
    local scriptName = inst.Name
    local api = tryAPI(inst)
    if api and #api > 50 then
        local cleaned = cleanupCode(api, scriptName)
        return "-- NovaDec v3.1 (Full Source)\n-- Script: " .. inst:GetFullName() .. "\n-- Type: " .. sType .. "\n\n" .. cleaned, "Full Source"
    end
    local rt = closureWalk(inst)
    if rt then return rt, "Runtime" end
    return nil, "All methods failed"
end

-- ═══════════════════════════════════════════════════════════
-- PATH RESOLVER
-- ═══════════════════════════════════════════════════════════
local SvcMap = {
    workspace="Workspace", replicatedstorage="ReplicatedStorage", serverstorage="ServerStorage",
    serverscriptservice="ServerScriptService", startergui="StarterGui", starterpack="StarterPack",
    starterplayer="StarterPlayer", players="Players", lighting="Lighting", replicatedfirst="ReplicatedFirst",
    soundservice="SoundService", chat="Chat", textchatservice="TextChatService", teams="Teams",
    coregui="CoreGui", runservice="RunService", tweenservice="TweenService",
    userinputservice="UserInputService", httpservice="HttpService",
    -- Shortcuts
    localplayer="__LP__",
    starterplayerscripts="__SPS__",
    startercharacterscripts="__SCS__",
    playergui="__PG__",
    playerscripts="__PS__",
    backpack="__BP__",
    character="__CHAR__",
}

local function getSvc(n)
    -- Try direct GetService first (handles exact names like "Players")
    local ok, s = pcall(function() return game:GetService(n) end)
    if ok and s then return s end

    local m = SvcMap[n:lower()]
    if not m then return nil end

    -- Special shortcuts
    if m == "__LP__" then return Players.LocalPlayer end
    if m == "__SPS__" then
        local sp = game:GetService("StarterPlayer")
        return sp and sp:FindFirstChild("StarterPlayerScripts")
    end
    if m == "__SCS__" then
        local sp = game:GetService("StarterPlayer")
        return sp and sp:FindFirstChild("StarterCharacterScripts")
    end
    if m == "__PG__" then
        local lp = Players.LocalPlayer
        if not lp then return nil end
        return lp:FindFirstChild("PlayerGui") or lp:WaitForChild("PlayerGui", 3)
    end
    if m == "__PS__" then
        local lp = Players.LocalPlayer
        if not lp then return nil end
        return lp:FindFirstChild("PlayerScripts") or lp:WaitForChild("PlayerScripts", 3)
    end
    if m == "__BP__" then
        local lp = Players.LocalPlayer
        if not lp then return nil end
        return lp:FindFirstChild("Backpack") or lp:WaitForChild("Backpack", 3)
    end
    if m == "__CHAR__" then
        local lp = Players.LocalPlayer
        if not lp then return nil end
        local char = lp.Character
        if not char then
            char = lp:FindFirstChild("Character") or lp:WaitForChild("Character", 3)
        end
        return char
    end

    ok, s = pcall(function() return game:GetService(m) end)
    if ok and s then return s end
    return nil
end

local function findSingleDescendantScript(root)
    if not root or type(root) ~= "userdata" or not root.GetDescendants then return nil end
    local found = nil
    pcall(function()
        for _, child in ipairs(root:GetDescendants()) do
            if child:IsA("LocalScript") or child:IsA("ModuleScript") or child:IsA("Script") then
                if not found then
                    found = child
                else
                    found = nil
                    return
                end
            end
        end
    end)
    return found
end

local function resolvePath(path)
    -- Clean up the path
    local p = path
    -- Remove wrapping quotes
    p = p:gsub('^"', ''):gsub('"$', ''):gsub("^'", ""):gsub("'$", "")
    -- Remove game. or game: prefix
    p = p:gsub("^game%.", ""):gsub("^game:", "")
    -- Handle game:GetService("X") or game:GetService("X"). syntax
    p = p:gsub("^GetService%(%s*\"([^\"]+)\"%s*%)", "%1")
    p = p:gsub("^GetService%(%s*'([^']+)'%s*%)", "%1")
    -- Convert bracket notation into dot notation for quoted child names
    p = p:gsub('%[%s*"(.-)"%s*%]', '.%1')
    p = p:gsub("%[%s*'(.-)'%s*%]", '.%1')
    p = p:gsub('%[%s*(%d+)%s*%]', '.%1')
    -- Normalize alternative path separators
    p = p:gsub("%s*%-%>%s*", ".")
    p = p:gsub("[/\\]", ".")
    p = p:gsub("%s*%.%s*", ".")
    -- Trim
    p = p:match("^%s*(.-)%s*$")
    if p == "" then return nil end

    local segs = {}
    for s in p:gmatch("[^%.]+") do segs[#segs+1] = s end
    if #segs == 0 then return nil end

    -- Resolve first segment as service/shortcut
    local cur = getSvc(segs[1])
    if not cur then return nil end

    for i = 2, #segs do
        local seg = segs[i]
        local segLower = seg:lower()

        -- Handle special keywords in the middle of a path
        if segLower == "localplayer" then
            cur = Players.LocalPlayer
            if not cur then return nil end
        elseif segLower == "playergui" and (type(cur) == "userdata" and cur:IsA("Player")) then
            cur = cur:FindFirstChild("PlayerGui") or cur:WaitForChild("PlayerGui", 3)
            if not cur then return nil end
        elseif segLower == "playerscripts" and (type(cur) == "userdata" and cur:IsA("Player")) then
            cur = cur:FindFirstChild("PlayerScripts") or cur:WaitForChild("PlayerScripts", 3)
            if not cur then return nil end
        elseif segLower == "backpack" and (type(cur) == "userdata" and cur:IsA("Player")) then
            cur = cur:FindFirstChild("Backpack") or cur:WaitForChild("Backpack", 3)
            if not cur then return nil end
        elseif segLower == "character" and (type(cur) == "userdata" and cur:IsA("Player")) then
            local lp = cur
            local char = lp.Character
            if not char then
                char = lp:FindFirstChild("Character") or lp:WaitForChild("Character", 3)
            end
            cur = char
            if not cur then return nil end
        elseif segLower == "starterplayerscripts" then
            local sp = game:GetService("StarterPlayer")
            cur = sp and sp:FindFirstChild("StarterPlayerScripts")
            if not cur then return nil end
        elseif segLower == "startercharacterscripts" then
            local sp = game:GetService("StarterPlayer")
            cur = sp and sp:FindFirstChild("StarterCharacterScripts")
            if not cur then return nil end
        else
            -- Standard child lookup
            local ch
            -- Exact match
            pcall(function() ch = cur:FindFirstChild(seg) end)
            -- Case-insensitive
            if not ch then
                pcall(function()
                    for _, c in ipairs(cur:GetChildren()) do
                        if c.Name:lower() == segLower then ch = c; break end
                    end
                end)
            end
            -- Recursive search
            if not ch then pcall(function() ch = cur:FindFirstChild(seg, true) end) end
            -- WaitForChild
            if not ch then pcall(function() ch = cur:WaitForChild(seg, 2) end) end
            if not ch then return nil end
            cur = ch
        end
    end

    if cur and type(cur) == "userdata" and cur.GetDescendants and not (cur:IsA("LocalScript") or cur:IsA("ModuleScript") or cur:IsA("Script")) then
        local autoScript = findSingleDescendantScript(cur)
        if autoScript then
            cur = autoScript
        end
    end

    return cur
end

local function searchScripts(name)
    local res = {}
    local nl = name:lower()
    local function scan(p)
        pcall(function()
            for _, c in ipairs(p:GetChildren()) do
                if (c:IsA("LocalScript") or c:IsA("ModuleScript") or c:IsA("Script")) and c.Name:lower():find(nl, 1, true) then
                    res[#res+1] = c
                end
                if #res < 20 then scan(c) end
            end
        end)
    end
    for _, svc in ipairs({"Workspace","ReplicatedStorage","StarterGui","StarterPack","ReplicatedFirst","Lighting"}) do
        pcall(function() scan(game:GetService(svc)) end)
    end
    pcall(function()
        local lp = Players.LocalPlayer
        if lp then
            for _, n in ipairs({"PlayerGui","PlayerScripts","Backpack"}) do
                local c = lp:FindFirstChild(n)
                if c then scan(c) end
            end
            local char = lp.Character
            if not char then
                char = lp:FindFirstChild("Character") or lp:WaitForChild("Character", 3)
            end
            if char then
                scan(char)
            end
        end
    end)
    return res
end

local function getScriptType(i)
    if pcall(function() return i:IsA("LocalScript") end) and i:IsA("LocalScript") then return "LocalScript" end
    if pcall(function() return i:IsA("ModuleScript") end) and i:IsA("ModuleScript") then return "ModuleScript" end
    if pcall(function() return i:IsA("Script") end) and i:IsA("Script") then return "Script" end
    return nil
end

-- ═══════════════════════════════════════════════════════════
-- GUI
-- ═══════════════════════════════════════════════════════════
local sg = Instance.new("ScreenGui")
sg.Name = "NovaDecGUI"; sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; sg.ResetOnSpawn = false; sg.DisplayOrder = 999
pcall(function() sg.Parent = CoreGui end)
if not sg.Parent then sg.Parent = player:WaitForChild("PlayerGui") end

local main = Instance.new("Frame")
main.Name = "Main"; main.Size = UDim2.new(0, 520, 0.85, 0); main.Position = UDim2.new(0.5, -260, 0.07, 0)
main.BackgroundColor3 = C.bg; main.BorderSizePixel = 0; main.ClipsDescendants = true; main.Parent = sg
corner(main, 12); stk(main)

local topAcc = Instance.new("Frame"); topAcc.Size = UDim2.new(1, 0, 0, 3); topAcc.BackgroundColor3 = C.acc; topAcc.BorderSizePixel = 0; topAcc.Parent = main

local tb = Instance.new("Frame"); tb.Size = UDim2.new(1, 0, 0, 44); tb.Position = UDim2.new(0, 0, 0, 3); tb.BackgroundColor3 = C.bg2; tb.BorderSizePixel = 0; tb.Parent = main
makeDrag(tb, main)

local icon = Instance.new("TextLabel"); icon.Size = UDim2.new(0, 32, 0, 32); icon.Position = UDim2.new(0, 10, 0.5, -16); icon.BackgroundColor3 = C.acc; icon.Text = "<>"; icon.TextColor3 = C.t1; icon.TextSize = 12; icon.Font = Enum.Font.GothamBold; icon.Parent = tb; corner(icon, 8)
local title = Instance.new("TextLabel"); title.Size = UDim2.new(0, 200, 0, 20); title.Position = UDim2.new(0, 48, 0, 6); title.BackgroundTransparency = 1; title.Text = "NovaDec v3.1"; title.TextColor3 = C.t1; title.TextSize = 15; title.Font = Enum.Font.GothamBold; title.TextXAlignment = Enum.TextXAlignment.Left; title.Parent = tb
local sub = Instance.new("TextLabel"); sub.Size = UDim2.new(0, 200, 0, 12); sub.Position = UDim2.new(0, 48, 0, 26); sub.BackgroundTransparency = 1; sub.Text = "Script Decompiler"; sub.TextColor3 = C.t3; sub.TextSize = 9; sub.Font = Enum.Font.Gotham; sub.TextXAlignment = Enum.TextXAlignment.Left; sub.Parent = tb

local closeBtn = Instance.new("TextButton"); closeBtn.Size = UDim2.new(0, 28, 0, 28); closeBtn.Position = UDim2.new(1, -36, 0.5, -14); closeBtn.BackgroundColor3 = C.srf; closeBtn.Text = "X"; closeBtn.TextColor3 = C.t2; closeBtn.TextSize = 12; closeBtn.Font = Enum.Font.GothamBold; closeBtn.AutoButtonColor = false; closeBtn.Parent = tb; corner(closeBtn, 6)
local minBtn = Instance.new("TextButton"); minBtn.Size = UDim2.new(0, 28, 0, 28); minBtn.Position = UDim2.new(1, -68, 0.5, -14); minBtn.BackgroundColor3 = C.srf; minBtn.Text = "-"; minBtn.TextColor3 = C.t2; minBtn.TextSize = 14; minBtn.Font = Enum.Font.GothamBold; minBtn.AutoButtonColor = false; minBtn.Parent = tb; corner(minBtn, 6)
for _, b in ipairs({closeBtn, minBtn}) do
    b.MouseEnter:Connect(function() tw(b, {BackgroundColor3 = b == closeBtn and C.red or C.srfH}, 0.12) end)
    b.MouseLeave:Connect(function() tw(b, {BackgroundColor3 = C.srf}, 0.12) end)
end

-- Tabs system
local TAB = { DECOMPILER = 1, AI = 2 }
local activeTab = TAB.DECOMPILER
local aiApiKey = ""

-- Content
local content = Instance.new("Frame"); content.Size = UDim2.new(1, -16, 1, -55); content.Position = UDim2.new(0, 8, 0, 50); content.BackgroundTransparency = 1; content.ClipsDescendants = true; content.Parent = main
local iCont = Instance.new("Frame"); iCont.Size = UDim2.new(1, 0, 0, 34); iCont.BackgroundColor3 = C.bg3; iCont.BorderSizePixel = 0; iCont.Parent = content; corner(iCont, 8); local iStk = stk(iCont)
local inputBox = Instance.new("TextBox"); inputBox.Size = UDim2.new(1, -12, 1, 0); inputBox.Position = UDim2.new(0, 6, 0, 0); inputBox.BackgroundTransparency = 1; inputBox.Text = ""; inputBox.PlaceholderText = "Script path or name..."; inputBox.PlaceholderColor3 = C.t3; inputBox.TextColor3 = C.t1; inputBox.TextSize = 12; inputBox.Font = Enum.Font.Code; inputBox.TextXAlignment = Enum.TextXAlignment.Left; inputBox.ClearTextOnFocus = false; inputBox.Parent = iCont
inputBox.Focused:Connect(function() tw(iStk, {Color = C.acc}, 0.2) end)
inputBox.FocusLost:Connect(function() tw(iStk, {Color = C.bdr}, 0.2) end)

-- Buttons
local bRow = Instance.new("Frame"); bRow.Size = UDim2.new(1, 0, 0, 30); bRow.Position = UDim2.new(0, 0, 0, 38); bRow.BackgroundTransparency = 1; bRow.Parent = content
local function mkBtn(text, x, w, accent)
    local b = Instance.new("TextButton"); b.Size = UDim2.new(0, w, 1, 0); b.Position = UDim2.new(0, x, 0, 0)
    b.BackgroundColor3 = accent and C.acc or C.srf; b.BorderSizePixel = 0; b.Text = text
    b.TextColor3 = accent and Color3.new(1,1,1) or C.t2; b.TextSize = 11; b.Font = Enum.Font.GothamBold; b.AutoButtonColor = false
    b.Parent = bRow; corner(b, 6); if not accent then stk(b) end
    b.MouseEnter:Connect(function() tw(b, {BackgroundColor3 = accent and C.accH or C.srfH}, 0.1) end)
    b.MouseLeave:Connect(function() tw(b, {BackgroundColor3 = accent and C.acc or C.srf}, 0.1) end)
    return b
end
local decompBtn = mkBtn("Decompile", 0, 90, true)
local askAiBtn = mkBtn("Ask AI", 95, 55, false)
local copyBtn = mkBtn("Copy", 155, 65)
local selBtn = mkBtn("Select", 225, 60)
local clearBtn = mkBtn("Clear", 290, 55)
local saveBtn = mkBtn("Save", 350, 55)

-- Status
local dStatus = Instance.new("TextLabel"); dStatus.Size = UDim2.new(1, 0, 0, 16); dStatus.Position = UDim2.new(0, 0, 0, 72); dStatus.BackgroundTransparency = 1; dStatus.Text = "Ready"; dStatus.TextColor3 = C.t3; dStatus.TextSize = 10; dStatus.Font = Enum.Font.Gotham; dStatus.TextXAlignment = Enum.TextXAlignment.Left; dStatus.TextTruncate = Enum.TextTruncate.AtEnd; dStatus.Parent = content

-- Output
local dOut = Instance.new("Frame"); dOut.Size = UDim2.new(1, 0, 1, -92); dOut.Position = UDim2.new(0, 0, 0, 90); dOut.BackgroundColor3 = C.bg2; dOut.BorderSizePixel = 0; dOut.ClipsDescendants = true; dOut.Parent = content; corner(dOut, 8); stk(dOut)
local dScroll = Instance.new("ScrollingFrame"); dScroll.Size = UDim2.new(1, -4, 1, -4); dScroll.Position = UDim2.new(0, 2, 0, 2); dScroll.BackgroundTransparency = 1; dScroll.BorderSizePixel = 0; dScroll.ScrollBarThickness = 5; dScroll.ScrollBarImageColor3 = C.acc; dScroll.CanvasSize = UDim2.new(0,0,0,0); dScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; dScroll.ScrollingDirection = Enum.ScrollingDirection.Y; dScroll.ElasticBehavior = Enum.ElasticBehavior.Always; dScroll.Parent = dOut
Instance.new("UIListLayout", dScroll).SortOrder = Enum.SortOrder.LayoutOrder

-- Chunked output
local fullOutputText = ""
local LINES_PER_CHUNK = 40
local chunkLabels = {}

local function setOutput(text)
    for _, l in ipairs(chunkLabels) do l:Destroy() end
    chunkLabels = {}
    fullOutputText = text
    if text == "" then return end
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines+1] = line end
    local order = 1
    local i = 1
    while i <= #lines do
        local ei = math.min(i + LINES_PER_CHUNK - 1, #lines)
        local cl = {}
        for j = i, ei do cl[#cl+1] = lines[j] end
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -4, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = table.concat(cl, "\n")
        lbl.TextColor3 = C.t1; lbl.TextSize = 12; lbl.Font = Enum.Font.Code
        lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.TextYAlignment = Enum.TextYAlignment.Top
        lbl.TextWrapped = true; lbl.AutomaticSize = Enum.AutomaticSize.Y; lbl.LayoutOrder = order
        lbl.Parent = dScroll
        chunkLabels[#chunkLabels+1] = lbl
        order = order + 1; i = ei + 1
    end
end

-- Select overlay
local selOverlay = Instance.new("ScrollingFrame"); selOverlay.Size = UDim2.new(1,0,1,0); selOverlay.BackgroundColor3 = C.bg2; selOverlay.BorderSizePixel = 0; selOverlay.ScrollBarThickness = 5; selOverlay.ScrollBarImageColor3 = C.accH; selOverlay.CanvasSize = UDim2.new(0,0,0,0); selOverlay.AutomaticCanvasSize = Enum.AutomaticSize.Y; selOverlay.ScrollingDirection = Enum.ScrollingDirection.Y; selOverlay.Visible = false; selOverlay.ZIndex = 5; selOverlay.Parent = dOut
Instance.new("UIListLayout", selOverlay).SortOrder = Enum.SortOrder.LayoutOrder
local selBanner = Instance.new("TextButton"); selBanner.Size = UDim2.new(1,0,0,26); selBanner.BackgroundColor3 = C.acc; selBanner.BorderSizePixel = 0; selBanner.Text = "Tap to exit selection"; selBanner.TextColor3 = Color3.new(1,1,1); selBanner.TextSize = 10; selBanner.Font = Enum.Font.GothamBold; selBanner.Visible = false; selBanner.ZIndex = 8; selBanner.Parent = dOut; corner(selBanner, 6)
local selMode = false
local selChunks = {}
local function toggleSel()
    selMode = not selMode
    if selMode then
        for _, c in ipairs(selChunks) do c:Destroy() end; selChunks = {}
        local lines = {}; for line in (fullOutputText .. "\n"):gmatch("(.-)\n") do lines[#lines+1] = line end
        local order = 1; local i = 1
        while i <= #lines do
            local ei = math.min(i + LINES_PER_CHUNK - 1, #lines)
            local cl = {}; for j = i, ei do cl[#cl+1] = lines[j] end
            local box = Instance.new("TextBox"); box.Size = UDim2.new(1,-8,0,0); box.BackgroundTransparency = 1
            box.Text = table.concat(cl, "\n"); box.TextColor3 = C.t1; box.TextSize = 12; box.Font = Enum.Font.Code
            box.TextXAlignment = Enum.TextXAlignment.Left; box.TextYAlignment = Enum.TextYAlignment.Top
            box.TextWrapped = true; box.MultiLine = true; box.ClearTextOnFocus = false; box.TextEditable = false
            box.AutomaticSize = Enum.AutomaticSize.Y; box.ZIndex = 6; box.LayoutOrder = order; box.Parent = selOverlay
            selChunks[#selChunks+1] = box; order = order + 1; i = ei + 1
        end
        selOverlay.Visible = true; selBanner.Visible = true; selBtn.Text = "Done"
    else
        selOverlay.Visible = false; selBanner.Visible = false
        for _, c in ipairs(selChunks) do c:Destroy() end; selChunks = {}; selBtn.Text = "Select"
    end
end
selBtn.MouseButton1Click:Connect(function() if fullOutputText == "" then return end; toggleSel() end)
selBanner.MouseButton1Click:Connect(function() if selMode then toggleSel() end end)

-- Toast
local function toast(msg, col, dur)
    local t = Instance.new("Frame"); t.Size = UDim2.new(0, 220, 0, 28); t.Position = UDim2.new(0.5, -110, 1, 0)
    t.BackgroundColor3 = col or C.acc; t.BorderSizePixel = 0; t.ZIndex = 100; t.Parent = sg; corner(t, 6)
    local tl = Instance.new("TextLabel"); tl.Size = UDim2.new(1,-8,1,0); tl.Position = UDim2.new(0,4,0,0); tl.BackgroundTransparency = 1
    tl.Text = msg; tl.TextColor3 = Color3.new(1,1,1); tl.TextSize = 10; tl.Font = Enum.Font.GothamBold; tl.Parent = t
    tw(t, {Position = UDim2.new(0.5, -110, 1, -38)}, 0.3)
    task.delay(dur or 2, function() tw(t, {Position = UDim2.new(0.5, -110, 1, 6)}, 0.2); task.delay(0.25, function() t:Destroy() end) end)
end

-- ═══════════════════════════════════════════════════════════
-- AI MODAL WINDOW
-- ═══════════════════════════════════════════════════════════
local aiApiKey = ""
local aiWindow = Instance.new("Frame"); aiWindow.Name = "AIChat"; aiWindow.Size = UDim2.new(0, 550, 0.7, 0); aiWindow.Position = UDim2.new(0.5, -275, 0.15, 0)
aiWindow.BackgroundColor3 = C.bg; aiWindow.BorderSizePixel = 0; aiWindow.ClipsDescendants = true; aiWindow.Visible = false; aiWindow.ZIndex = 50; aiWindow.Parent = sg
corner(aiWindow, 12); stk(aiWindow)

local aiHeader = Instance.new("Frame"); aiHeader.Size = UDim2.new(1, 0, 0, 44); aiHeader.BackgroundColor3 = C.bg2; aiHeader.BorderSizePixel = 0; aiHeader.Parent = aiWindow
makeDrag(aiHeader, aiWindow)
local aiTitle = Instance.new("TextLabel"); aiTitle.Size = UDim2.new(1, -70, 1, 0); aiTitle.Position = UDim2.new(0, 10, 0, 0); aiTitle.BackgroundTransparency = 1; aiTitle.Text = "Gemini AI Assistant"; aiTitle.TextColor3 = C.t1; aiTitle.TextSize = 13; aiTitle.Font = Enum.Font.GothamBold; aiTitle.TextXAlignment = Enum.TextXAlignment.Left; aiTitle.Parent = aiHeader
local aiCloseBtn = Instance.new("TextButton"); aiCloseBtn.Size = UDim2.new(0, 28, 0, 28); aiCloseBtn.Position = UDim2.new(1, -36, 0.5, -14); aiCloseBtn.BackgroundColor3 = C.srf; aiCloseBtn.Text = "X"; aiCloseBtn.TextColor3 = C.t2; aiCloseBtn.TextSize = 12; aiCloseBtn.Font = Enum.Font.GothamBold; aiCloseBtn.AutoButtonColor = false; aiCloseBtn.Parent = aiHeader; corner(aiCloseBtn, 6)
aiCloseBtn.MouseEnter:Connect(function() tw(aiCloseBtn, {BackgroundColor3 = C.red}, 0.12) end)
aiCloseBtn.MouseLeave:Connect(function() tw(aiCloseBtn, {BackgroundColor3 = C.srf}, 0.12) end)
aiCloseBtn.MouseButton1Click:Connect(function() tw(aiWindow, {BackgroundTransparency = 1}, 0.2); task.delay(0.25, function() aiWindow.Visible = false end) end)

local apiKeyCont = Instance.new("Frame"); apiKeyCont.Size = UDim2.new(1, -16, 0, 30); apiKeyCont.Position = UDim2.new(0, 8, 0, 50); apiKeyCont.BackgroundColor3 = C.bg3; apiKeyCont.BorderSizePixel = 0; apiKeyCont.Parent = aiWindow; corner(apiKeyCont, 6); stk(apiKeyCont)
local apiKeyBox = Instance.new("TextBox"); apiKeyBox.Size = UDim2.new(1, -12, 1, 0); apiKeyBox.Position = UDim2.new(0, 6, 0, 0); apiKeyBox.BackgroundTransparency = 1; apiKeyBox.Text = ""; apiKeyBox.PlaceholderText = "Google Gemini API Key"; apiKeyBox.PlaceholderColor3 = C.t3; apiKeyBox.TextColor3 = C.t1; apiKeyBox.TextSize = 10; apiKeyBox.Font = Enum.Font.Code; apiKeyBox.TextXAlignment = Enum.TextXAlignment.Left; apiKeyBox.ClearTextOnFocus = false; apiKeyBox.Parent = apiKeyCont
apiKeyBox.FocusLost:Connect(function() aiApiKey = apiKeyBox.Text end)

local chatScroll = Instance.new("ScrollingFrame"); chatScroll.Size = UDim2.new(1, -16, 1, -150); chatScroll.Position = UDim2.new(0, 8, 0, 85); chatScroll.BackgroundColor3 = C.bg2; chatScroll.BorderSizePixel = 0; chatScroll.ClipsDescendants = true; chatScroll.ScrollBarThickness = 5; chatScroll.ScrollBarImageColor3 = C.acc; chatScroll.CanvasSize = UDim2.new(0,0,0,0); chatScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; chatScroll.ScrollingDirection = Enum.ScrollingDirection.Y; chatScroll.Parent = aiWindow; corner(chatScroll, 6); stk(chatScroll)
Instance.new("UIListLayout", chatScroll).SortOrder = Enum.SortOrder.LayoutOrder
local chatMessages = {}

local function addMessage(text, isUser, isCode)
    local msg = Instance.new("Frame"); msg.Size = UDim2.new(1, -8, 0, 0); msg.BackgroundColor3 = isUser and C.acc or C.bg3; msg.BorderSizePixel = 0; msg.LayoutOrder = #chatMessages + 1; msg.Parent = chatScroll; corner(msg, 6)
    if isCode then
        local hdr = Instance.new("Frame"); hdr.Size = UDim2.new(1, 0, 0, 22); hdr.BackgroundColor3 = C.bg; hdr.BorderSizePixel = 0; hdr.Parent = msg; corner(hdr, 4)
        local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, -28, 1, 0); lbl.Position = UDim2.new(0, 4, 0, 0); lbl.BackgroundTransparency = 1; lbl.Text = "Code"; lbl.TextColor3 = C.t2; lbl.TextSize = 9; lbl.Font = Enum.Font.GothamBold; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = hdr
        local cpyBtn = Instance.new("TextButton"); cpyBtn.Size = UDim2.new(0, 24, 0, 18); cpyBtn.Position = UDim2.new(1, -26, 0.5, -9); cpyBtn.BackgroundColor3 = C.srf; cpyBtn.BorderSizePixel = 0; cpyBtn.Text = "📋"; cpyBtn.TextSize = 10; cpyBtn.Font = Enum.Font.GothamBold; cpyBtn.AutoButtonColor = false; cpyBtn.Parent = hdr; corner(cpyBtn, 3); stk(cpyBtn)
        cpyBtn.MouseButton1Click:Connect(function() if setclipboard then setclipboard(text); toast("Copied!", C.grn, 1.5) end end)
        cpyBtn.MouseEnter:Connect(function() tw(cpyBtn, {BackgroundColor3 = C.srfH}, 0.08) end)
        cpyBtn.MouseLeave:Connect(function() tw(cpyBtn, {BackgroundColor3 = C.srf}, 0.08) end)
        local codeBox = Instance.new("TextLabel"); codeBox.Size = UDim2.new(1, -10, 0, 0); codeBox.Position = UDim2.new(0, 5, 0, 26); codeBox.BackgroundTransparency = 1; codeBox.Text = text; codeBox.TextColor3 = C.grn; codeBox.TextSize = 9; codeBox.Font = Enum.Font.Code; codeBox.TextXAlignment = Enum.TextXAlignment.Left; codeBox.TextYAlignment = Enum.TextYAlignment.Top; codeBox.TextWrapped = true; codeBox.AutomaticSize = Enum.AutomaticSize.Y; codeBox.Parent = msg
        msg.Size = UDim2.new(1, -8, 0, 48 + codeBox.AbsoluteSize.Y)
    else
        local textLabel = Instance.new("TextLabel"); textLabel.Size = UDim2.new(1, -10, 0, 0); textLabel.Position = UDim2.new(0, 5, 0, 5); textLabel.BackgroundTransparency = 1; textLabel.Text = text; textLabel.TextColor3 = isUser and Color3.new(1,1,1) or C.t1; textLabel.TextSize = 10; textLabel.Font = Enum.Font.Gotham; textLabel.TextXAlignment = Enum.TextXAlignment.Left; textLabel.TextYAlignment = Enum.TextYAlignment.Top; textLabel.TextWrapped = true; textLabel.AutomaticSize = Enum.AutomaticSize.Y; textLabel.Parent = msg
        msg.Size = UDim2.new(1, -8, 0, textLabel.AbsoluteSize.Y + 10)
    end
    chatMessages[#chatMessages+1] = msg
    task.wait(0.02); chatScroll.CanvasPosition = Vector2.new(0, chatScroll.CanvasSize.Y)
end

local inputCont = Instance.new("Frame"); inputCont.Size = UDim2.new(1, -16, 0, 58); inputCont.Position = UDim2.new(0, 8, 1, -66); inputCont.BackgroundColor3 = C.bg3; inputCont.BorderSizePixel = 0; inputCont.Parent = aiWindow; corner(inputCont, 6); stk(inputCont)
local questInput = Instance.new("TextBox"); questInput.Size = UDim2.new(1, -44, 0, 50); questInput.Position = UDim2.new(0, 4, 0, 4); questInput.BackgroundColor3 = C.bg2; questInput.BorderSizePixel = 0; questInput.Text = ""; questInput.PlaceholderText = "Ask about the code..."; questInput.PlaceholderColor3 = C.t3; questInput.TextColor3 = C.t1; questInput.TextSize = 9; questInput.Font = Enum.Font.Gotham; questInput.TextXAlignment = Enum.TextXAlignment.Left; questInput.TextYAlignment = Enum.TextYAlignment.Top; questInput.TextWrapped = true; questInput.MultiLine = true; questInput.ClearTextOnFocus = false; questInput.Parent = inputCont; corner(questInput, 4)
local sendBtn = Instance.new("TextButton"); sendBtn.Size = UDim2.new(0, 36, 0, 50); sendBtn.Position = UDim2.new(1, -40, 0, 4); sendBtn.BackgroundColor3 = C.acc; sendBtn.BorderSizePixel = 0; sendBtn.Text = "→"; sendBtn.TextColor3 = Color3.new(1,1,1); sendBtn.TextSize = 16; sendBtn.Font = Enum.Font.GothamBold; sendBtn.AutoButtonColor = false; sendBtn.Parent = inputCont; corner(sendBtn, 4)
sendBtn.MouseEnter:Connect(function() tw(sendBtn, {BackgroundColor3 = C.accH}, 0.08) end)
sendBtn.MouseLeave:Connect(function() tw(sendBtn, {BackgroundColor3 = C.acc}, 0.08) end)

local aiSending = false
local function callGemini(userMsg)
    if aiSending or aiApiKey == "" then if aiApiKey == "" then toast("Enter API key first!", C.red, 2) end; return end
    aiSending = true; sendBtn.Text = "..."; sendBtn.Disabled = true
    addMessage(userMsg, true, false)
    questInput.Text = ""
    task.spawn(function()
        local fullPrompt = "Code:\n\n" .. (fullOutputText or "") .. "\n\nQuestion: " .. userMsg
        local payload = {contents = {{parts = {{text = fullPrompt}}}}}
        local ok, res = pcall(function()
            return _request({
                Url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=" .. aiApiKey,
                Method = "POST",
                Headers = {["content-type"] = "application/json"},
                Body = HttpService:JSONEncode(payload)
            })
        end)
        local response = "Error connecting"
        if ok and res and res.StatusCode == 200 then
            local dec = pcall(function() return HttpService:JSONDecode(res.Body) end)
            if dec then
                local decoded = HttpService:JSONDecode(res.Body)
                if decoded.candidates and decoded.candidates[1] and decoded.candidates[1].content and decoded.candidates[1].content.parts and decoded.candidates[1].content.parts[1] then
                    response = decoded.candidates[1].content.parts[1].text or "No response"
                end
            end
        else
            response = "Error: " .. (res and tostring(res.StatusCode) or "No connection")
        end
        if response:find("```") then
            local codeMatch = response:match("```[^```]*?([^```]+)```")
            if codeMatch then
                addMessage("Code:", false, false)
                addMessage(codeMatch, false, true)
                local remaining = response:gsub("```[^```]*?```", ""):gsub("^%s+", ""):gsub("%s+$", "")
                if remaining ~= "" then addMessage(remaining, false, false) end
            else
                addMessage(response, false, false)
            end
        else
            addMessage(response, false, false)
        end
        aiSending = false; sendBtn.Text = "→"; sendBtn.Disabled = false
    end)
end

sendBtn.MouseButton1Click:Connect(function()
    local msg = questInput.Text:gsub("^%s+", ""):gsub("%s+$", "")
    if msg ~= "" then callGemini(msg) end
end)

askAiBtn.MouseButton1Click:Connect(function()
    if fullOutputText == "" then
        toast("Decompile a script first!", C.yel)
        return
    end
    aiWindow.BackgroundTransparency = 1
    aiWindow.Visible = true
    tw(aiWindow, {BackgroundTransparency = 0}, 0.25)
    questInput:CaptureFocus()
    if #chatMessages == 0 then
        addMessage("Decompiled code loaded. Ask me anything!", false, false)
    end
end)

-- Decompile logic
local busy = false
decompBtn.MouseButton1Click:Connect(function()
    if busy then return end
    local path = inputBox.Text
    if not path or path == "" then toast("Enter path first", C.yel); return end
    busy = true; decompBtn.Text = "..."; dStatus.Text = "Working..."; dStatus.TextColor3 = C.yel
    task.spawn(function()
        local inst = resolvePath(path)
        if not inst and not path:find("%.") then
            local f = searchScripts(path)
            if #f == 1 then inst = f[1]
            elseif #f > 1 then
                local l = {"-- Multiple found:"}
                for i, s in ipairs(f) do l[#l+1] = "-- " .. i .. ". " .. s:GetFullName() end
                setOutput(table.concat(l, "\n")); dStatus.Text = #f .. " matches"
                busy = false; decompBtn.Text = "Decompile"; return
            end
        end
        if not inst then
            dStatus.Text = "Not found"; dStatus.TextColor3 = C.red; toast("Not found", C.red)
            busy = false; decompBtn.Text = "Decompile"; return
        end
        local sType = getScriptType(inst)
        if not sType then
            dStatus.Text = "Not a script"; dStatus.TextColor3 = C.red
            busy = false; decompBtn.Text = "Decompile"; return
        end
        dStatus.Text = "Decompiling " .. sType .. "..."
        local result, method = fullDecompile(inst)
        if result then
            setOutput(result)
            local ln = 1; for _ in result:gmatch("\n") do ln = ln + 1 end
            dStatus.Text = method .. " | " .. ln .. " lines, " .. #result .. " chars"
            dStatus.TextColor3 = C.grn; toast("Done! " .. ln .. " lines", C.grn)
        else
            setOutput("-- Failed: " .. (method or "")); dStatus.Text = "Failed"; dStatus.TextColor3 = C.red
        end
        busy = false; decompBtn.Text = "Decompile"
    end)
end)

copyBtn.MouseButton1Click:Connect(function()
    if fullOutputText == "" then return end
    pcall(function() if setclipboard then setclipboard(fullOutputText); toast("Copied " .. #fullOutputText .. " chars", C.grn) end end)
end)
clearBtn.MouseButton1Click:Connect(function() setOutput(""); inputBox.Text = ""; dStatus.Text = "Ready"; dStatus.TextColor3 = C.t3; if selMode then toggleSel() end end)
saveBtn.MouseButton1Click:Connect(function()
    if fullOutputText == "" then return end
    pcall(function() if writefile then local fn = "NovaDec_" .. os.time() .. ".lua"; writefile(fn, fullOutputText); toast("Saved: " .. fn, C.grn) end end)
end)
inputBox.FocusLost:Connect(function(enter) if enter then decompBtn.MouseButton1Click:Fire() end end)

-- Minimize / Close
local mini = Instance.new("TextButton"); mini.Size = UDim2.new(0, 42, 0, 42); mini.Position = UDim2.new(0, 10, 0.5, -21); mini.BackgroundColor3 = C.acc; mini.Text = "<>"; mini.TextColor3 = C.t1; mini.TextSize = 14; mini.Font = Enum.Font.GothamBold; mini.Visible = false; mini.AutoButtonColor = false; mini.ZIndex = 10; mini.Parent = sg; corner(mini, 12); makeDrag(mini, mini)
local minimized = false
minBtn.MouseButton1Click:Connect(function()
    if minimized then return end; minimized = true
    tw(main, {Size = UDim2.new(0, 520, 0, 0), BackgroundTransparency = 1}, 0.25)
    task.delay(0.25, function() main.Visible = false; mini.Visible = true end)
end)
mini.MouseButton1Click:Connect(function()
    if not minimized then return end; minimized = false; mini.Visible = false; main.Visible = true
    main.Size = UDim2.new(0, 520, 0, 0); main.BackgroundTransparency = 1
    tw(main, {Size = UDim2.new(0, 520, 0.85, 0), BackgroundTransparency = 0}, 0.35)
end)
closeBtn.MouseButton1Click:Connect(function()
    tw(main, {Size = UDim2.new(0, 520, 0, 0), BackgroundTransparency = 1}, 0.2)
    task.delay(0.25, function() sg:Destroy() end)
end)

-- Intro
main.BackgroundTransparency = 1; main.Size = UDim2.new(0, 520, 0, 0)
task.delay(0.1, function() tw(main, {BackgroundTransparency = 0, Size = UDim2.new(0, 520, 0.85, 0)}, 0.4) end)

-- Detect executor
task.spawn(function()
    local name = "Unknown"
    pcall(function() if identifyexecutor then name = identifyexecutor() end end)
    local caps = {}
    if _getscriptbytecode and _request then caps[#caps+1] = "API" end
    if _getscriptclosure then caps[#caps+1] = "closure" end
    if setclipboard then caps[#caps+1] = "clipboard" end
    dStatus.Text = name .. " | " .. table.concat(caps, ", ")
    dStatus.TextColor3 = C.t3
end)

print("NovaDec v3.1 loaded")
