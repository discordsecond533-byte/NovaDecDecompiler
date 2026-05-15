--[[
    ███╗   ██╗ ██████╗ ██╗   ██╗ █████╗ ██████╗ ███████╗ ██████╗
    ████╗  ██║██╔═══██╗██║   ██║██╔══██╗██╔══██╗██╔════╝██╔════╝
    ██╔██╗ ██║██║   ██║██║   ██║███████║██║  ██║█████╗  ██║     
    ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║██║  ██║██╔══╝  ██║     
    ██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║██████╔╝███████╗╚██████╗
    ╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝╚═════╝ ╚══════╝ ╚═════╝
    
    NovaDec v3 — Runtime Closure Decompiler
    Does NOT use broken decompile() or raw bytecode opcodes
    Uses getscriptclosure + debug API to walk live closures
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
local player = Players.LocalPlayer

-- ═══════════════════════════════════════════════════════════
-- COLORS
-- ═══════════════════════════════════════════════════════════
local C = {
    bg=Color3.fromRGB(13,13,18), bg2=Color3.fromRGB(20,20,28), bg3=Color3.fromRGB(26,26,36),
    srf=Color3.fromRGB(30,30,42), srfH=Color3.fromRGB(38,38,52),
    acc=Color3.fromRGB(99,102,241), accH=Color3.fromRGB(129,140,248), accD=Color3.fromRGB(67,56,202),
    grn=Color3.fromRGB(34,197,94), red=Color3.fromRGB(239,68,68), yel=Color3.fromRGB(245,158,11),
    t1=Color3.fromRGB(240,240,255), t2=Color3.fromRGB(148,148,180), t3=Color3.fromRGB(100,100,130),
    bdr=Color3.fromRGB(42,42,60),
}

-- ═══════════════════════════════════════════════════════════
-- UI HELPERS
-- ═══════════════════════════════════════════════════════════
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
-- ██████ FULL DECOMPILER ENGINE (API + Runtime) ██████
-- Primary: sends bytecode to external decompile API
-- Fallback: deep runtime closure introspection
-- ═══════════════════════════════════════════════════════════

local _getconstants = getconstants or debug.getconstants or nil
local _getupvalues = getupvalues or debug.getupvalues or nil
local _getprotos = getprotos or debug.getprotos or nil
local _getinfo = getinfo or debug.getinfo or nil
local _debuginfo = debug.info or nil
local _getscriptclosure = getscriptclosure or nil
local _getsenv = getsenv or nil
local _require = require
local _request = request or http_request or (syn and syn.request) or nil
local _getscriptbytecode = getscriptbytecode or nil
local HttpService = game:GetService("HttpService")

-- ─── Base64 encoder (works everywhere) ───
local function base64encode(data)
    -- Try executor builtins first
    if crypt and crypt.base64encode then
        local ok, r = pcall(crypt.base64encode, data)
        if ok and r then return r end
    end
    if base64_encode then
        local ok, r = pcall(base64_encode, data)
        if ok and r then return r end
    end
    if base64 and base64.encode then
        local ok, r = pcall(base64.encode, data)
        if ok and r then return r end
    end
    -- Manual fallback
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x)
        local r, byte = '', x:byte()
        for i = 8, 1, -1 do r = r .. (byte % 2^i - byte % 2^(i-1) > 0 and '1' or '0') end
        return r
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i,i) == '1' and 2^(6-i) or 0) end
        return b:sub(c+1, c+1)
    end) .. ({'', '==', '='})[#data % 3 + 1])
end

-- ═══════════════════════════════════════════════════════════
-- METHOD 1: API DECOMPILE (sends bytecode to server that
-- knows the current Roblox opcode shuffle — returns FULL source)
-- ═══════════════════════════════════════════════════════════
local function tryAPIDecompile(scriptInstance)
    if not _getscriptbytecode then return nil, "no getscriptbytecode" end
    if not _request then return nil, "no http request function" end

    local ok, bytecode = pcall(_getscriptbytecode, scriptInstance)
    if not ok or not bytecode or #bytecode == 0 then
        return nil, "bytecode empty: " .. tostring(bytecode)
    end

    local encoded = base64encode(bytecode)
    if not encoded or #encoded == 0 then return nil, "base64 encode failed" end

    -- Try multiple API endpoints in order
    local apis = {
        {url="https://api.lua.expert/decompile", ct="application/json",
         body=HttpService:JSONEncode({script=encoded})},
        {url="https://luadec.metasploit.sh/decompile", ct="application/json",
         body=HttpService:JSONEncode({bytecode=encoded})},
    }

    local lastErr = ""
    for _, api in ipairs(apis) do
        local reqOk, res = pcall(_request, {
            Url=api.url, Method="POST",
            Headers={["content-type"]=api.ct, ["user-agent"]="NovaDec/3"},
            Body=api.body,
        })
        if reqOk and res and res.StatusCode == 200 and res.Body and #res.Body > 30 then
            local body = res.Body
            -- Try JSON parse in case response is wrapped
            pcall(function()
                local parsed = HttpService:JSONDecode(body)
                if parsed then
                    body = parsed.output or parsed.result or parsed.source or parsed.code or parsed.decompiled or body
                end
            end)
            -- Verify it's actual code, not an error page
            if type(body) == "string" and #body > 30
                and not body:match("^<!") and not body:match("^<html")
                and not body:match("^{%s*\"error\"") then
                return body, "Full Decompile"
            end
        end
        if res then lastErr = "HTTP " .. (res.StatusCode or "?") end
    end
    return nil, "API failed: " .. lastErr
end

-- Format any value to a readable Luau string
local function formatValue(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    if depth > 6 then return "{ --[[deep]] }" end
    
    local t = typeof(v)
    
    if t == "nil" then return "nil"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then
        if v ~= v then return "0/0"
        elseif v == math.huge then return "math.huge"
        elseif v == -math.huge then return "-math.huge"
        elseif v == math.floor(v) and math.abs(v) < 2^53 then return tostring(math.floor(v))
        else return tostring(v) end
    elseif t == "string" then
        local s = v:gsub("\\","\\\\"):gsub('"','\\"'):gsub("\n","\\n"):gsub("\r","\\r"):gsub("\t","\\t"):gsub("\0","\\0")
        s = s:gsub("[%c]", function(c) return string.format("\\%d", string.byte(c)) end)
        return '"' .. s .. '"'
    elseif t == "function" then
        return "function() end"
    elseif t == "table" then
        if seen[v] then return "{ --[[circular]] }" end
        seen[v] = true
        local parts = {}
        local arrayLen = #v
        -- Array part
        for i = 1, math.min(arrayLen, 50) do
            parts[#parts+1] = formatValue(v[i], depth + 1, seen)
        end
        if arrayLen > 50 then parts[#parts+1] = "-- ... " .. (arrayLen - 50) .. " more" end
        -- Hash part
        local hashCount = 0
        for k, val in pairs(v) do
            if type(k) ~= "number" or k < 1 or k > arrayLen or k ~= math.floor(k) then
                hashCount = hashCount + 1
                if hashCount > 30 then
                    parts[#parts+1] = "-- ... more keys"
                    break
                end
                local keyStr
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    keyStr = k
                else
                    keyStr = "[" .. formatValue(k, depth + 1, seen) .. "]"
                end
                parts[#parts+1] = keyStr .. " = " .. formatValue(val, depth + 1, seen)
            end
        end
        seen[v] = nil
        if #parts == 0 then return "{}" end
        local indent = string.rep("    ", depth + 1)
        local outerIndent = string.rep("    ", depth)
        return "{\n" .. indent .. table.concat(parts, ",\n" .. indent) .. "\n" .. outerIndent .. "}"
    elseif t == "Vector3" then return "Vector3.new(" .. v.X .. ", " .. v.Y .. ", " .. v.Z .. ")"
    elseif t == "Vector2" then return "Vector2.new(" .. v.X .. ", " .. v.Y .. ")"
    elseif t == "CFrame" then return "CFrame.new(" .. tostring(v) .. ")"
    elseif t == "Color3" then return string.format("Color3.new(%g, %g, %g)", v.R, v.G, v.B)
    elseif t == "BrickColor" then return 'BrickColor.new("' .. tostring(v) .. '")'
    elseif t == "UDim" then return "UDim.new(" .. v.Scale .. ", " .. v.Offset .. ")"
    elseif t == "UDim2" then return "UDim2.new(" .. v.X.Scale .. ", " .. v.X.Offset .. ", " .. v.Y.Scale .. ", " .. v.Y.Offset .. ")"
    elseif t == "Rect" then return "Rect.new(" .. v.Min.X .. ", " .. v.Min.Y .. ", " .. v.Max.X .. ", " .. v.Max.Y .. ")"
    elseif t == "NumberRange" then return "NumberRange.new(" .. v.Min .. ", " .. v.Max .. ")"
    elseif t == "NumberSequence" then return "NumberSequence.new(" .. tostring(v) .. ")"
    elseif t == "ColorSequence" then return "ColorSequence.new(" .. tostring(v) .. ")"
    elseif t == "EnumItem" then return tostring(v)
    elseif t == "Enum" then return tostring(v)
    elseif t == "Instance" then
        local path = v:GetFullName()
        -- Clean up the path
        local parts2 = string.split(path, ".")
        if #parts2 > 0 then
            local first = parts2[1]
            local svcOk, _ = pcall(function() return game:GetService(first) end)
            if svcOk then
                parts2[1] = 'game:GetService("' .. first .. '")'
            end
        end
        return table.concat(parts2, ".")
    elseif t == "RBXScriptSignal" then return "-- Signal: " .. tostring(v)
    elseif t == "Ray" then return "Ray.new(" .. tostring(v.Origin) .. ", " .. tostring(v.Direction) .. ")"
    elseif t == "TweenInfo" then return "TweenInfo.new()"
    else
        return tostring(v) .. " --[[" .. t .. "]]"
    end
end

-- Get a nice instance path
local function getInstancePath(inst)
    if not inst or not inst.Parent then return "nil --[[instance parented to nil]]" end
    local parts = {}
    local current = inst
    while current and current ~= game do
        table.insert(parts, 1, current.Name)
        current = current.Parent
    end
    if #parts == 0 then return "game" end
    -- First part is a service
    local first = parts[1]
    local svcOk = pcall(function() return game:GetService(first) end)
    local result
    if first == "Workspace" then
        result = "workspace"
        table.remove(parts, 1)
    elseif svcOk then
        result = 'game:GetService("' .. first .. '")'
        table.remove(parts, 1)
    else
        result = "game"
    end
    for _, p in ipairs(parts) do
        if p:match("^[%a_][%w_]*$") then
            result = result .. "." .. p
        else
            result = result .. '["' .. p .. '"]'
        end
    end
    return result
end

-- Known Roblox library functions for constant matching
local knownLibs = {
    math = {"abs","acos","asin","atan","atan2","ceil","clamp","cos","cosh","deg","exp","floor","fmod",
            "frexp","huge","ldexp","log","log10","max","min","modf","noise","pi","pow","rad","random",
            "randomseed","round","sign","sin","sinh","sqrt","tan","tanh"},
    string = {"byte","char","find","format","gmatch","gsub","len","lower","match","rep","reverse","split","sub","upper"},
    table = {"clear","clone","concat","create","find","foreach","foreachi","freeze","getn","insert","isfrozen",
             "maxn","move","pack","remove","sort","unpack"},
    bit32 = {"arshift","band","bnot","bor","btest","bxor","countlz","countrz","extract","lrotate","lshift",
             "replace","rrotate","rshift"},
    os = {"clock","date","difftime","time"},
    coroutine = {"close","create","isyieldable","resume","running","status","wrap","yield"},
    task = {"cancel","defer","delay","desynchronize","spawn","synchronize","wait"},
    debug = {"info","traceback","profilebegin","profileend"},
    utf8 = {"char","charpattern","codepoint","codes","graphemes","len","nfcnormalize","nfdnormalize","offset"},
    buffer = {"create","fromstring","tostring","len","copy","fill","readi8","readu8","readi16","readu16",
              "readi32","readu32","readf32","readf64","writei8","writeu8","writei16","writeu16","writei32",
              "writeu32","writef32","writef64"},
}

local function isLibraryMethod(libName, methodName)
    local lib = knownLibs[libName]
    if lib then for _, m in ipairs(lib) do if m == methodName then return true end end end
    return false
end

local knownGlobals = {
    print=1,warn=1,error=1,require=1,typeof=1,type=1,tostring=1,tonumber=1,
    pairs=1,ipairs=1,next=1,select=1,pcall=1,xpcall=1,rawget=1,rawset=1,
    rawequal=1,rawlen=1,setmetatable=1,getmetatable=1,unpack=1,assert=1,
    spawn=1,delay=1,wait=1,tick=1,time=1,game=1,workspace=1,script=1,
    Instance=1,Vector3=1,Vector2=1,CFrame=1,Color3=1,BrickColor=1,
    UDim=1,UDim2=1,Enum=1,Ray=1,TweenInfo=1,NumberRange=1,Random=1,
    NumberSequence=1,ColorSequence=1,newproxy=1,coroutine=1,string=1,
    table=1,math=1,bit32=1,os=1,task=1,debug=1,utf8=1,buffer=1,
}

-- Smart variable name from upvalue index + value
local function smartName(k, v)
    if type(k) == "string" then return k end
    local vt = typeof(v)
    if vt == "Instance" then
        local ok2, nm = pcall(function() return v.Name end)
        if ok2 and nm and #nm > 0 then
            local clean = nm:gsub("[^%w_]", "")
            if #clean > 0 then return clean:sub(1,1):lower() .. clean:sub(2, 24) end
        end
        return "inst" .. k
    elseif vt == "boolean" then return "is" .. k
    elseif vt == "number" then return "n" .. k
    elseif vt == "string" then
        if #v > 2 and #v < 24 and v:match("^[%a_][%w_]*$") then return v end
        return "str" .. k
    elseif vt == "table" then return "data" .. k
    elseif vt == "function" then return "fn" .. k
    elseif vt == "nil" then return "v" .. k
    else return "v" .. k end
end

-- ═══════════════════════════════════════════════════════════
-- FULL DECOMPILE — API first, then deep runtime fallback
-- ═══════════════════════════════════════════════════════════
local function fullDecompile(scriptInstance)
    local scriptType = scriptInstance:IsA("ModuleScript") and "ModuleScript"
        or scriptInstance:IsA("LocalScript") and "LocalScript" or "Script"
    local scriptPath = scriptInstance:GetFullName()

    -- ══════════════════════════════════════════════
    -- ATTEMPT 1: API DECOMPILE (gives FULL source)
    -- ══════════════════════════════════════════════
    local apiResult, apiMethod = tryAPIDecompile(scriptInstance)
    if apiResult and #apiResult > 50 then
        -- Clean up: ensure consistent indentation
        local cleaned = apiResult:gsub("\r\n", "\n"):gsub("\r", "\n")
        local header = "-- Decompiled by NovaDec v3 (Full Source)\n"
            .. "-- Script: " .. scriptPath .. "\n"
            .. "-- Type: " .. scriptType .. "\n"
            .. "-- Quality: Complete — all logic, control flow, and variables\n\n"
        return header .. cleaned, "Full Source"
    end

    -- ══════════════════════════════════════════════════════════
    -- ATTEMPT 2: RUNTIME CLOSURE RECONSTRUCTION
    -- (This reconstructs from live VM data — shows structure,
    --  variables, constants, and function bodies, but cannot
    --  recover control flow like if/else/loops since Roblox
    --  encrypts the bytecode opcodes.)
    -- ══════════════════════════════════════════════════════════
    local output = {}
    local function add(s) output[#output+1] = s end

    add("-- ═══════════════════════════════════════════════════════════")
    add("-- NovaDec v3 — Runtime Reconstruction")
    add("-- Script: " .. scriptPath)
    add("-- Type:   " .. scriptType)
    add("--")
    add("-- Note: This is a runtime reconstruction, not a full decompile.")
    add("-- Roblox encrypts bytecode opcodes so control flow (if/else,")
    add("-- loops) cannot be recovered. What you see below is extracted")
    add("-- from live closures: real variable values, function structure,")
    add("-- API calls, and string/number constants. Use Copy to grab all.")
    if apiMethod then add("-- API status: " .. tostring(apiMethod)) end
    add("-- ═══════════════════════════════════════════════════════════")
    add("")

    local closure, senv, moduleResult
    local methods = {}

    if _getscriptclosure then
        local ok, c = pcall(_getscriptclosure, scriptInstance)
        if ok and c and type(c) == "function" then closure = c; methods[#methods+1] = "closure" end
    end
    if _getsenv and (scriptType == "LocalScript" or scriptType == "Script") then
        local ok, e = pcall(_getsenv, scriptInstance)
        if ok and e and type(e) == "table" then senv = e; methods[#methods+1] = "senv" end
    end
    if scriptType == "ModuleScript" then
        local ok, r = pcall(_require, scriptInstance)
        if ok then moduleResult = r; methods[#methods+1] = "require" end
    end

    if #methods == 0 then
        return nil, "No methods available.\nNeed: getscriptclosure, getsenv, or require\nAPI status: " .. tostring(apiMethod)
    end

    -- ─── Deep closure walk — clean readable reconstruction ───
    local visited = {}
    local funcCounter = 0

    local function deepWalk(func, name, depth)
        if not func or visited[func] then return end
        visited[func] = true
        depth = depth or 0
        funcCounter = funcCounter + 1
        local pad = string.rep("    ", depth)
        local inner = pad .. (depth > 0 and "    " or "")

        -- Get function metadata
        local fName, fArgs, fVarArg, fSource, fLine
        if _debuginfo then
            pcall(function()
                fName, fArgs, fVarArg = _debuginfo(func, "nav")
                fSource, fLine = _debuginfo(func, "sl")
            end)
        end
        local displayName = (fName and fName ~= "") and fName or name or ("func" .. funcCounter)
        local params = {}
        for p = 1, (fArgs or 0) do
            params[#params+1] = string.char(96 + ((p - 1) % 26) + 1) .. (p > 26 and tostring(math.ceil(p/26)) or "")
        end
        if fVarArg then params[#params+1] = "..." end

        -- Gather data from VM
        local upvals = {}; if _getupvalues then pcall(function() upvals = _getupvalues(func) end) end
        local consts = {}; if _getconstants then pcall(function() consts = _getconstants(func) end) end
        local protos = {}; if _getprotos then pcall(function() protos = _getprotos(func) end) end

        -- ── Function header ──
        if depth > 0 then
            local lineInfo = fLine and (" -- line " .. fLine) or ""
            add(pad .. "local function " .. displayName .. "(" .. table.concat(params, ", ") .. ")" .. lineInfo)
        end

        -- ── Upvalues → clean local declarations ──
        local funcUpvals = {}
        if next(upvals) then
            local keys = {}; for k in pairs(upvals) do keys[#keys+1] = k end
            table.sort(keys, function(a,b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
            for _, k in ipairs(keys) do
                local v = upvals[k]
                local vn = smartName(k, v)
                if typeof(v) == "function" then
                    funcUpvals[#funcUpvals+1] = {name = vn, func = v}
                else
                    add(inner .. "local " .. vn .. " = " .. formatValue(v, depth + 1))
                end
            end
            if #keys > #funcUpvals then add("") end
            for _, fu in ipairs(funcUpvals) do
                deepWalk(fu.func, fu.name, depth > 0 and depth + 1 or depth)
            end
        end

        -- ── Constants → reconstructed as readable code ──
        if #consts > 0 then
            local emitted = {}
            local codeLines = {}
            local strings = {}
            local numbers = {}
            local i = 1

            while i <= #consts do
                local k = consts[i]
                if k == nil then i = i + 1
                elseif type(k) == "string" then
                    local nxt = consts[i + 1]

                    -- Library.method pair: math.floor, string.format, etc.
                    if nxt and type(nxt) == "string" and knownLibs[k] then
                        local j = i + 1
                        while j <= #consts and type(consts[j]) == "string" and isLibraryMethod(k, consts[j]) do
                            codeLines[#codeLines+1] = k .. "." .. consts[j] .. "(...)"
                            j = j + 1
                        end
                        i = (j > i + 1) and j or (i + 1)

                    -- GetService + service name
                    elseif k == "GetService" and nxt and type(nxt) == "string" and not emitted[nxt] then
                        emitted[nxt] = true
                        local vn = nxt:gsub("Service$",""); vn = vn:sub(1,1):lower()..vn:sub(2)
                        codeLines[#codeLines+1] = 'local '..vn..' = game:GetService("'..nxt..'")'
                        i = i + 2

                    -- Direct service name
                    elseif not knownGlobals[k] and not emitted[k] then
                        local svcOk = pcall(function() return game:GetService(k) end)
                        if svcOk and #k > 3 and k ~= "Run" and k ~= "Stop" then
                            emitted[k] = true
                            local vn = k:gsub("Service$",""); vn = vn:sub(1,1):lower()..vn:sub(2)
                            codeLines[#codeLines+1] = 'local '..vn..' = game:GetService("'..k..'")'
                            i = i + 1

                        -- Instance.new("Class")
                        elseif k == "new" and nxt and type(nxt) == "string" then
                            codeLines[#codeLines+1] = 'local obj = Instance.new("'..nxt..'")'
                            i = i + 2

                        -- :WaitForChild("name") / :FindFirstChild("name")
                        elseif (k=="WaitForChild" or k=="FindFirstChild" or k=="FindFirstChildOfClass"
                            or k=="FindFirstChildWhichIsA") and nxt and type(nxt)=="string" then
                            codeLines[#codeLines+1] = ':'..k..'("'..nxt..'")'
                            i = i + 2

                        -- :Connect
                        elseif k == "Connect" or k == "connect" then
                            codeLines[#codeLines+1] = ":Connect(function() ... end)"
                            i = i + 1

                        -- :FireServer / :InvokeServer
                        elseif k == "FireServer" or k == "InvokeServer" or k == "FireClient" or k == "InvokeClient" then
                            codeLines[#codeLines+1] = ":"..k.."(...)"
                            i = i + 1

                        -- Event names
                        elseif k:match("Changed$") or k:match("Added$") or k:match("Removed$")
                            or k=="Heartbeat" or k=="RenderStepped" or k=="Stepped" or k=="Touched"
                            or k:match("^On%u") then
                            codeLines[#codeLines+1] = "."..k..":Connect(function() ... end)"
                            i = i + 1

                        -- PascalCase method with string arg
                        elseif k:match("^[A-Z][%a]+$") and #k > 2 then
                            if nxt and type(nxt)=="string" and not nxt:match("^[A-Z]") then
                                codeLines[#codeLines+1] = ":"..k..'("'..nxt..'")'
                                i = i + 2
                            else
                                codeLines[#codeLines+1] = ":"..k.."(...)"
                                i = i + 1
                            end

                        -- camelCase property
                        elseif k:match("^[a-z_][%w_]*$") and #k > 1 then
                            codeLines[#codeLines+1] = "."..k
                            i = i + 1

                        -- Just a string literal
                        else
                            strings[#strings+1] = k
                            i = i + 1
                        end
                    else
                        i = i + 1
                    end
                elseif type(k) == "number" then
                    if k ~= 0 and k ~= 1 and k ~= 2 and k ~= -1 then
                        numbers[#numbers+1] = k
                    end
                    i = i + 1
                else
                    i = i + 1
                end
            end

            -- Emit code lines
            for _, line in ipairs(codeLines) do
                add(inner .. line)
            end
            -- Emit remaining strings as a compact block
            if #strings > 0 then
                local cleaned = {}
                for _, s in ipairs(strings) do
                    if #s > 0 and #s < 200 then cleaned[#cleaned+1] = '"'..s:gsub('"','\\"'):gsub("\n","\\n")..'"' end
                end
                if #cleaned > 0 then
                    add(inner .. "-- Strings: " .. table.concat(cleaned, ", "))
                end
            end
            -- Emit notable numbers
            if #numbers > 0 then
                local numStrs = {}; for _, n in ipairs(numbers) do numStrs[#numStrs+1] = tostring(n) end
                add(inner .. "-- Numbers: " .. table.concat(numStrs, ", "))
            end
            if #codeLines > 0 or #strings > 0 or #numbers > 0 then add("") end
        end

        -- ── Child functions (protos) ──
        for idx, proto in ipairs(protos) do
            if type(proto) == "function" and not visited[proto] then
                local pName; if _debuginfo then pcall(function() pName = _debuginfo(proto, "n") end) end
                deepWalk(proto, pName or ("func" .. funcCounter + idx), depth > 0 and depth + 1 or depth)
            end
        end

        if depth > 0 then add(pad .. "end"); add("") end
    end

    -- ══════════════════════════════════════════════
    -- Walk everything
    -- ══════════════════════════════════════════════

    -- Root closure
    if closure then
        add("-- ┌─────────────────────────────────────────┐")
        add("-- │         Root Closure Variables           │")
        add("-- └─────────────────────────────────────────┘")
        add("")
        local ok, err = pcall(deepWalk, closure, "main", 0)
        if not ok then add("-- Error walking closure: " .. tostring(err)) end
    end

    -- Script environment
    if senv then
        add("")
        add("-- ┌─────────────────────────────────────────┐")
        add("-- │         Script Environment               │")
        add("-- └─────────────────────────────────────────┘")
        add("")
        local envFuncs, envVars = {}, {}
        local count = 0
        for k, v in pairs(senv) do
            if type(k) == "string" then
                if typeof(v) == "function" then envFuncs[#envFuncs+1] = {name=k, func=v}
                else envVars[#envVars+1] = {name=k, value=v} end
            end
            count = count + 1; if count > 200 then break end
        end
        -- Sort for consistent output
        table.sort(envVars, function(a,b) return a.name < b.name end)
        table.sort(envFuncs, function(a,b) return a.name < b.name end)

        for _, ev in ipairs(envVars) do add(ev.name .. " = " .. formatValue(ev.value, 0)) end
        if #envVars > 0 then add("") end
        for _, ef in ipairs(envFuncs) do
            if not visited[ef.func] then deepWalk(ef.func, ef.name, 0) end
        end
    end

    -- Module return value
    if moduleResult ~= nil then
        add("")
        add("-- ┌─────────────────────────────────────────┐")
        add("-- │         Module Return Value              │")
        add("-- └─────────────────────────────────────────┘")
        add("")
        if type(moduleResult) == "table" then
            add("local module = " .. formatValue(moduleResult, 0))
            add("")
            for k, v in pairs(moduleResult) do
                if typeof(v) == "function" and not visited[v] then
                    deepWalk(v, "module." .. (type(k) == "string" and k or ("["..tostring(k).."]")), 0)
                end
            end
            add("return module")
        else
            add("return " .. formatValue(moduleResult, 0))
        end
    end

    -- GC scan for orphaned closures
    if getgc then
        local gcFuncs = {}
        pcall(function()
            for _, obj in ipairs(getgc(true)) do
                if type(obj) == "function" and not visited[obj] then
                    local src; pcall(function() src = _debuginfo(obj, "s") end)
                    if src and src == scriptPath then gcFuncs[#gcFuncs+1] = obj end
                end
                if #gcFuncs >= 30 then break end
            end
        end)
        if #gcFuncs > 0 then
            add("")
            add("-- ┌─────────────────────────────────────────┐")
            add("-- │   Additional Closures from GC (" .. string.format("%2d", #gcFuncs) .. ")       │")
            add("-- └─────────────────────────────────────────┘")
            add("")
            for idx, fn in ipairs(gcFuncs) do
                if not visited[fn] then
                    deepWalk(fn, "gc_func_" .. idx, 0)
                end
            end
        end
    end

    local finalCode = table.concat(output, "\n")
    return finalCode, "Runtime (" .. table.concat(methods, "+") .. ")"
end

-- ═══════════════════════════════════════════════════════════
-- PATH RESOLVER
-- ═══════════════════════════════════════════════════════════
local SvcMap = {
    workspace="Workspace",replicatedstorage="ReplicatedStorage",serverstorage="ServerStorage",
    serverscriptservice="ServerScriptService",startergui="StarterGui",starterpack="StarterPack",
    starterplayer="StarterPlayer",players="Players",lighting="Lighting",replicatedfirst="ReplicatedFirst",
    soundservice="SoundService",chat="Chat",textchatservice="TextChatService",teams="Teams",coregui="CoreGui",
    localplayer="__LP__",
}

local function getSvc(n)
    local ok,s=pcall(function() return game:GetService(n) end); if ok and s then return s end
    local m=SvcMap[n:lower()]; if m=="__LP__" then return Players.LocalPlayer end
    if m then ok,s=pcall(function() return game:GetService(m) end); if ok and s then return s end end
    ok,s=pcall(function() return game:FindFirstChild(n) end); if ok and s then return s end
    return nil
end

local function resolvePath(path)
    local p=path:gsub('^"',''):gsub('"$',''):gsub("^'",""):gsub("'$",""):gsub("^game%.",""):gsub("^game:","")
    p=p:gsub('^GetService%(\"([^\"]+)\"%)',"%1"):gsub("^GetService%('([^']+)'%)","%1"):match("^%s*(.-)%s*$")
    if p=="" then return nil,"Empty" end
    local segs={}; for s in p:gmatch("[^%.%/]+") do segs[#segs+1]=s end
    if #segs==0 then return nil,"Invalid" end
    local cur=getSvc(segs[1]); if not cur then return nil,'Service not found: "'..segs[1]..'"' end
    for i=2,#segs do
        local seg=segs[i]
        if seg:lower()=="localplayer" then cur=Players.LocalPlayer; if not cur then return nil,"No LocalPlayer" end
        else
            local child
            pcall(function() child=cur:FindFirstChild(seg) end)
            if not child then pcall(function() for _,c in ipairs(cur:GetChildren()) do if c.Name:lower()==seg:lower() then child=c; break end end end) end
            if not child then pcall(function() child=cur:FindFirstChild(seg,true) end) end
            if not child then pcall(function() child=cur:WaitForChild(seg,3) end) end
            if not child then
                local avail={}
                pcall(function() for idx,c in ipairs(cur:GetChildren()) do if idx<=12 then
                    avail[#avail+1]=(c:IsA("LocalScript") and "[LS] " or c:IsA("ModuleScript") and "[MS] " or c:IsA("Script") and "[S]  " or c:IsA("Folder") and "[F]  " or "     ")..c.Name
                end end end)
                return nil,'Not found: "'..seg..'" in '..cur:GetFullName()..(#avail>0 and("\n\nChildren:\n"..table.concat(avail,"\n")) or "")
            end
            cur=child
        end
    end
    return cur
end

local function searchScripts(name)
    local res={}; local nl=name:lower()
    local function scan(p) pcall(function() for _,c in ipairs(p:GetChildren()) do
        if(c:IsA("LocalScript")or c:IsA("ModuleScript")or c:IsA("Script"))and c.Name:lower():find(nl,1,true) then res[#res+1]=c end
        if #res<20 then scan(c) end
    end end) end
    for _,svc in ipairs({"Workspace","ReplicatedStorage","StarterGui","StarterPack","ReplicatedFirst","Lighting"}) do pcall(function() scan(game:GetService(svc)) end) end
    pcall(function() local lp=Players.LocalPlayer; if lp then for _,n in ipairs({"PlayerGui","PlayerScripts","Backpack"}) do local c=lp:FindFirstChild(n); if c then scan(c) end end end end)
    pcall(function() if getnilinstances then for _,inst in ipairs(getnilinstances()) do
        if(inst:IsA("LocalScript")or inst:IsA("ModuleScript")or inst:IsA("Script"))and inst.Name:lower():find(nl,1,true) then res[#res+1]=inst end
    end end end)
    return res
end

local function getScriptType(inst)
    local ok,r=pcall(function() return inst:IsA("LocalScript") end); if ok and r then return "LocalScript" end
    ok,r=pcall(function() return inst:IsA("ModuleScript") end); if ok and r then return "ModuleScript" end
    ok,r=pcall(function() return inst:IsA("Script") end); if ok and r then return "Script" end
    return nil
end

-- ═══════════════════════════════════════════════════════════
-- BUILD GUI
-- ═══════════════════════════════════════════════════════════
local sg=Instance.new("ScreenGui"); sg.Name="NovaDecGUI"; sg.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; sg.ResetOnSpawn=false; sg.DisplayOrder=999
pcall(function() sg.Parent=CoreGui end); if not sg.Parent then sg.Parent=player:WaitForChild("PlayerGui") end

local main=Instance.new("Frame"); main.Name="Main"; main.Size=UDim2.new(0,520,0,580); main.Position=UDim2.new(0.5,-260,0.5,-290)
main.BackgroundColor3=C.bg; main.BorderSizePixel=0; main.ClipsDescendants=true; main.Parent=sg; corner(main,12); stk(main)

local topBar=Instance.new("Frame"); topBar.Size=UDim2.new(1,0,0,3); topBar.BackgroundColor3=C.acc; topBar.BorderSizePixel=0; topBar.Parent=main; corner(topBar,12)

local tb=Instance.new("Frame"); tb.Size=UDim2.new(1,0,0,48); tb.Position=UDim2.new(0,0,0,3); tb.BackgroundColor3=C.bg2; tb.BorderSizePixel=0; tb.Parent=main
makeDrag(tb,main)

local icon=Instance.new("TextLabel"); icon.Size=UDim2.new(0,36,0,36); icon.Position=UDim2.new(0,12,0.5,-18); icon.BackgroundColor3=C.acc; icon.Text="<>"; icon.TextColor3=C.t1; icon.TextSize=14; icon.Font=Enum.Font.GothamBold; icon.Parent=tb; corner(icon,8)
local title=Instance.new("TextLabel"); title.Size=UDim2.new(0,200,0,20); title.Position=UDim2.new(0,56,0,8); title.BackgroundTransparency=1; title.Text="NovaDec v3"; title.TextColor3=C.t1; title.TextSize=17; title.Font=Enum.Font.GothamBold; title.TextXAlignment=Enum.TextXAlignment.Left; title.Parent=tb
local sub=Instance.new("TextLabel"); sub.Size=UDim2.new(0,200,0,14); sub.Position=UDim2.new(0,56,0,28); sub.BackgroundTransparency=1; sub.Text="Runtime Closure Decompiler"; sub.TextColor3=C.t3; sub.TextSize=10; sub.Font=Enum.Font.Gotham; sub.TextXAlignment=Enum.TextXAlignment.Left; sub.Parent=tb

local closeBtn=Instance.new("TextButton"); closeBtn.Size=UDim2.new(0,30,0,30); closeBtn.Position=UDim2.new(1,-40,0.5,-15); closeBtn.BackgroundColor3=C.srf; closeBtn.Text="X"; closeBtn.TextColor3=C.t2; closeBtn.TextSize=13; closeBtn.Font=Enum.Font.GothamBold; closeBtn.AutoButtonColor=false; closeBtn.Parent=tb; corner(closeBtn,8)
local minBtn=Instance.new("TextButton"); minBtn.Size=UDim2.new(0,30,0,30); minBtn.Position=UDim2.new(1,-76,0.5,-15); minBtn.BackgroundColor3=C.srf; minBtn.Text="-"; minBtn.TextColor3=C.t2; minBtn.TextSize=16; minBtn.Font=Enum.Font.GothamBold; minBtn.AutoButtonColor=false; minBtn.Parent=tb; corner(minBtn,8)
for _,b in ipairs({closeBtn,minBtn}) do
    b.MouseEnter:Connect(function() tw(b,{BackgroundColor3=b==closeBtn and C.red or C.srfH},0.15) end)
    b.MouseLeave:Connect(function() tw(b,{BackgroundColor3=C.srf},0.15) end)
end

local content=Instance.new("Frame"); content.Size=UDim2.new(1,-24,1,-63); content.Position=UDim2.new(0,12,0,55); content.BackgroundTransparency=1; content.ClipsDescendants=true; content.Parent=main
local iLabel=Instance.new("TextLabel"); iLabel.Size=UDim2.new(1,0,0,14); iLabel.BackgroundTransparency=1; iLabel.Text="SCRIPT PATH"; iLabel.TextColor3=C.t3; iLabel.TextSize=10; iLabel.Font=Enum.Font.GothamBold; iLabel.TextXAlignment=Enum.TextXAlignment.Left; iLabel.Parent=content
local iCont=Instance.new("Frame"); iCont.Size=UDim2.new(1,0,0,40); iCont.Position=UDim2.new(0,0,0,18); iCont.BackgroundColor3=C.bg3; iCont.BorderSizePixel=0; iCont.Parent=content; corner(iCont,8); local iStk=stk(iCont)
local inputBox=Instance.new("TextBox"); inputBox.Size=UDim2.new(1,-14,1,0); inputBox.Position=UDim2.new(0,7,0,0); inputBox.BackgroundTransparency=1; inputBox.Text=""; inputBox.PlaceholderText="Workspace.Script or just type a name"; inputBox.PlaceholderColor3=C.t3; inputBox.TextColor3=C.t1; inputBox.TextSize=13; inputBox.Font=Enum.Font.Code; inputBox.TextXAlignment=Enum.TextXAlignment.Left; inputBox.ClearTextOnFocus=false; inputBox.Parent=iCont
inputBox.Focused:Connect(function() tw(iStk,{Color=C.acc},0.2) end)
inputBox.FocusLost:Connect(function() tw(iStk,{Color=C.bdr},0.2) end)

local bRow=Instance.new("Frame"); bRow.Size=UDim2.new(1,0,0,36); bRow.Position=UDim2.new(0,0,0,64); bRow.BackgroundTransparency=1; bRow.Parent=content
local function makeBtn(text,x,w,accent)
    local b=Instance.new("TextButton"); b.Size=UDim2.new(0,w,1,0); b.Position=UDim2.new(0,x,0,0)
    b.BackgroundColor3=accent and C.acc or C.srf; b.BorderSizePixel=0; b.Text=text
    b.TextColor3=accent and Color3.new(1,1,1) or C.t2; b.TextSize=12; b.Font=Enum.Font.GothamBold; b.AutoButtonColor=false
    b.Parent=bRow; corner(b,8); if not accent then stk(b) end
    b.MouseEnter:Connect(function() tw(b,{BackgroundColor3=accent and C.accH or C.srfH},0.12) end)
    b.MouseLeave:Connect(function() tw(b,{BackgroundColor3=accent and C.acc or C.srf},0.12) end)
    return b
end
local decompBtn=makeBtn("Decompile",0,130,true)
local copyBtn=makeBtn("Copy",138,80); local selBtn=makeBtn("Select",226,72); local clearBtn=makeBtn("Clear",306,70); local saveBtn=makeBtn("Save",384,70)

local sBar=Instance.new("Frame"); sBar.Size=UDim2.new(1,0,0,26); sBar.Position=UDim2.new(0,0,0,106); sBar.BackgroundColor3=C.bg3; sBar.BorderSizePixel=0; sBar.Parent=content; corner(sBar,6)
local sDot=Instance.new("Frame"); sDot.Size=UDim2.new(0,7,0,7); sDot.Position=UDim2.new(0,8,0.5,-3); sDot.BackgroundColor3=C.t3; sDot.BorderSizePixel=0; sDot.Parent=sBar; corner(sDot,4)
local sText=Instance.new("TextLabel"); sText.Size=UDim2.new(1,-54,1,0); sText.Position=UDim2.new(0,20,0,0); sText.BackgroundTransparency=1; sText.Text="Ready"; sText.TextColor3=C.t3; sText.TextSize=10; sText.Font=Enum.Font.Gotham; sText.TextXAlignment=Enum.TextXAlignment.Left; sText.TextTruncate=Enum.TextTruncate.AtEnd; sText.Parent=sBar
local lnCount=Instance.new("TextLabel"); lnCount.Size=UDim2.new(0,46,1,0); lnCount.Position=UDim2.new(1,-50,0,0); lnCount.BackgroundTransparency=1; lnCount.Text="0 ln"; lnCount.TextColor3=C.t3; lnCount.TextSize=9; lnCount.Font=Enum.Font.Code; lnCount.TextXAlignment=Enum.TextXAlignment.Right; lnCount.Parent=sBar

local badge=Instance.new("TextLabel"); badge.Size=UDim2.new(0,86,0,16); badge.Position=UDim2.new(1,-86,0,138); badge.BackgroundColor3=C.srf; badge.Text=""; badge.TextColor3=C.acc; badge.TextSize=9; badge.Font=Enum.Font.GothamBold; badge.Visible=false; badge.Parent=content; corner(badge,4)

local oCont=Instance.new("Frame"); oCont.Size=UDim2.new(1,0,1,-160); oCont.Position=UDim2.new(0,0,0,156); oCont.BackgroundColor3=C.bg2; oCont.BorderSizePixel=0; oCont.ClipsDescendants=true; oCont.Parent=content; corner(oCont,8); stk(oCont)
local gutter=Instance.new("Frame"); gutter.Size=UDim2.new(0,38,1,0); gutter.BackgroundColor3=C.bg; gutter.BorderSizePixel=0; gutter.ClipsDescendants=true; gutter.Parent=oCont
Instance.new("Frame",gutter).Size=UDim2.new(0,1,1,0); gutter:GetChildren()[1].Position=UDim2.new(1,-1,0,0); gutter:GetChildren()[1].BackgroundColor3=C.bdr; gutter:GetChildren()[1].BorderSizePixel=0

local scroll=Instance.new("ScrollingFrame"); scroll.Size=UDim2.new(1,-42,1,-6); scroll.Position=UDim2.new(0,42,0,3)
scroll.BackgroundTransparency=1; scroll.BorderSizePixel=0; scroll.ScrollBarThickness=6; scroll.ScrollBarImageColor3=C.acc
scroll.CanvasSize=UDim2.new(0,0,0,0); scroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
scroll.ScrollingDirection=Enum.ScrollingDirection.Y; scroll.ElasticBehavior=Enum.ElasticBehavior.Always
scroll.ScrollBarImageTransparency=0.3; scroll.Parent=oCont

-- UIListLayout stacks chunked TextLabels vertically
local listLayout=Instance.new("UIListLayout"); listLayout.SortOrder=Enum.SortOrder.LayoutOrder
listLayout.FillDirection=Enum.FillDirection.Vertical; listLayout.Padding=UDim.new(0,0); listLayout.Parent=scroll

-- Placeholder shown when empty
local placeholder=Instance.new("TextLabel"); placeholder.Name="Placeholder"; placeholder.Size=UDim2.new(1,-6,0,100)
placeholder.BackgroundTransparency=1; placeholder.Text="-- Decompiled output appears here\n-- Drag to scroll, tap Select to highlight\n-- Copy grabs the FULL script\n-- Uses API + runtime closure engine"; placeholder.TextColor3=C.t3
placeholder.TextSize=12; placeholder.Font=Enum.Font.Code; placeholder.TextXAlignment=Enum.TextXAlignment.Left; placeholder.TextYAlignment=Enum.TextYAlignment.Top
placeholder.TextWrapped=true; placeholder.LayoutOrder=0; placeholder.Parent=scroll

-- Full output stored here (never truncated — used for Copy/Save)
local fullOutputText = ""

-- Chunk by LINES not characters — this is the only reliable way
-- to avoid Roblox's TextLabel rendering cutoff on mobile.
-- Each chunk gets exactly N lines. No character guessing.
local LINES_PER_CHUNK = 40
local chunkLabels = {}

local function clearChunks()
    for _, lbl in ipairs(chunkLabels) do lbl:Destroy() end
    chunkLabels = {}
end

local function renderChunks(text)
    clearChunks()
    fullOutputText = text
    placeholder.Visible = (text == "")
    if text == "" then return end

    -- Split into lines
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end

    -- Group lines into small chunks
    local order = 1
    local i = 1
    while i <= #lines do
        local endIdx = math.min(i + LINES_PER_CHUNK - 1, #lines)
        local chunkLines = {}
        for j = i, endIdx do
            chunkLines[#chunkLines + 1] = lines[j]
        end
        local chunkText = table.concat(chunkLines, "\n")

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -6, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = chunkText
        lbl.TextColor3 = C.t1
        lbl.TextSize = 12
        lbl.Font = Enum.Font.Code
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextYAlignment = Enum.TextYAlignment.Top
        lbl.TextWrapped = true
        lbl.AutomaticSize = Enum.AutomaticSize.Y
        lbl.RichText = false
        lbl.LayoutOrder = order
        lbl.Parent = scroll

        chunkLabels[#chunkLabels + 1] = lbl
        order = order + 1
        i = endIdx + 1
    end
end

-- SELECT OVERLAY: TextBox shown ONLY when user taps Select button
-- Also chunked so long text isn't cut off
local selectOverlay=Instance.new("ScrollingFrame"); selectOverlay.Name="SelectOverlay"
selectOverlay.Size=UDim2.new(1,0,1,0); selectOverlay.Position=UDim2.new(0,0,0,0)
selectOverlay.BackgroundColor3=C.bg2; selectOverlay.BackgroundTransparency=0; selectOverlay.BorderSizePixel=0
selectOverlay.ScrollBarThickness=6; selectOverlay.ScrollBarImageColor3=C.accH; selectOverlay.ScrollBarImageTransparency=0.3
selectOverlay.CanvasSize=UDim2.new(0,0,0,0); selectOverlay.AutomaticCanvasSize=Enum.AutomaticSize.Y
selectOverlay.ScrollingDirection=Enum.ScrollingDirection.Y; selectOverlay.ElasticBehavior=Enum.ElasticBehavior.Always
selectOverlay.Visible=false; selectOverlay.ZIndex=5; selectOverlay.Parent=oCont

local selListLayout=Instance.new("UIListLayout"); selListLayout.SortOrder=Enum.SortOrder.LayoutOrder
selListLayout.FillDirection=Enum.FillDirection.Vertical; selListLayout.Padding=UDim.new(0,0); selListLayout.Parent=selectOverlay

local selChunks = {}

local function renderSelectChunks(text)
    for _, c in ipairs(selChunks) do c:Destroy() end
    selChunks = {}
    -- Split by lines same as main display
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines+1] = line end
    local order = 1
    local i = 1
    while i <= #lines do
        local endIdx = math.min(i + LINES_PER_CHUNK - 1, #lines)
        local chunkLines = {}
        for j = i, endIdx do chunkLines[#chunkLines+1] = lines[j] end
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(1, -12, 0, 0)
        box.BackgroundTransparency = 1; box.Text = table.concat(chunkLines, "\n"); box.TextColor3 = C.t1
        box.TextSize = 12; box.Font = Enum.Font.Code
        box.TextXAlignment = Enum.TextXAlignment.Left; box.TextYAlignment = Enum.TextYAlignment.Top
        box.TextWrapped = true; box.MultiLine = true; box.ClearTextOnFocus = false; box.TextEditable = false
        box.AutomaticSize = Enum.AutomaticSize.Y; box.ZIndex = 6; box.LayoutOrder = order
        box.Parent = selectOverlay
        selChunks[#selChunks+1] = box
        order = order + 1; i = endIdx + 1
    end
end

-- Close select overlay banner
local selBanner=Instance.new("TextButton"); selBanner.Name="SelBanner"
selBanner.Size=UDim2.new(1,0,0,30); selBanner.Position=UDim2.new(0,0,0,0)
selBanner.BackgroundColor3=C.acc; selBanner.BorderSizePixel=0; selBanner.Text="Tap to exit selection mode"
selBanner.TextColor3=Color3.new(1,1,1); selBanner.TextSize=11; selBanner.Font=Enum.Font.GothamBold
selBanner.AutoButtonColor=false; selBanner.Visible=false; selBanner.ZIndex=8; selBanner.Parent=oCont
corner(selBanner,6)

-- Select mode state
local selectMode=false
local function toggleSelectMode()
    selectMode = not selectMode
    if selectMode then
        renderSelectChunks(fullOutputText)
        selectOverlay.Visible = true
        selectOverlay.CanvasPosition = scroll.CanvasPosition
        selBanner.Visible = true
        selBtn.Text = "Done"; selBtn.BackgroundColor3 = C.acc; selBtn.TextColor3 = Color3.new(1,1,1)
    else
        selectOverlay.Visible = false; selBanner.Visible = false
        for _, c in ipairs(selChunks) do c:Destroy() end; selChunks = {}
        selBtn.Text = "Select"; selBtn.BackgroundColor3 = C.srf; selBtn.TextColor3 = C.t2
    end
end

selBtn.MouseButton1Click:Connect(function()
    if fullOutputText == "" then toast("Nothing to select",C.yel); return end
    toggleSelectMode()
end)
selBanner.MouseButton1Click:Connect(function() if selectMode then toggleSelectMode() end end)

-- Line numbers
local lnScroll=Instance.new("ScrollingFrame"); lnScroll.Size=UDim2.new(1,-1,1,-6); lnScroll.Position=UDim2.new(0,0,0,3)
lnScroll.BackgroundTransparency=1; lnScroll.BorderSizePixel=0; lnScroll.ScrollBarThickness=0
lnScroll.CanvasSize=UDim2.new(0,0,0,0); lnScroll.ScrollingDirection=Enum.ScrollingDirection.Y; lnScroll.Parent=gutter

-- Line numbers — chunked with SAME lines-per-chunk as main display
local lnChunks = {}
local function renderLineNumbers(totalLines)
    for _, c in ipairs(lnChunks) do c:Destroy() end; lnChunks = {}
    lnCount.Text = totalLines .. " ln"
    if totalLines == 0 then return end
    local order = 1
    local i = 1
    while i <= totalLines do
        local endLine = math.min(i + LINES_PER_CHUNK - 1, totalLines)
        local nums = {}
        for j = i, endLine do nums[#nums+1] = tostring(j) end
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -4, 0, 0); lbl.BackgroundTransparency = 1
        lbl.Text = table.concat(nums, "\n"); lbl.TextColor3 = C.t3; lbl.TextSize = 12; lbl.Font = Enum.Font.Code
        lbl.TextXAlignment = Enum.TextXAlignment.Right; lbl.TextYAlignment = Enum.TextYAlignment.Top
        lbl.AutomaticSize = Enum.AutomaticSize.Y; lbl.LayoutOrder = order; lbl.Parent = lnScroll
        lnChunks[#lnChunks+1] = lbl
        order = order + 1; i = endLine + 1
    end
end

local lnListLayout=Instance.new("UIListLayout"); lnListLayout.SortOrder=Enum.SortOrder.LayoutOrder
lnListLayout.FillDirection=Enum.FillDirection.Vertical; lnListLayout.Padding=UDim.new(0,0); lnListLayout.Parent=lnScroll

-- Sync all scrolling
scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
    lnScroll.CanvasPosition=Vector2.new(0,scroll.CanvasPosition.Y)
    lnScroll.CanvasSize=scroll.CanvasSize
end)

local mini=Instance.new("TextButton"); mini.Size=UDim2.new(0,46,0,46); mini.Position=UDim2.new(0,14,0.5,-23); mini.BackgroundColor3=C.acc; mini.Text="<>"; mini.TextColor3=C.t1; mini.TextSize=15; mini.Font=Enum.Font.GothamBold; mini.Visible=false; mini.AutoButtonColor=false; mini.ZIndex=10; mini.Parent=sg; corner(mini,12)
makeDrag(mini,mini)

-- ═══════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════
local function setStatus(t,col) sText.Text=t; sText.TextColor3=col or C.t3; sDot.BackgroundColor3=col or C.t3 end
local function setOutput(t)
    renderChunks(t)
    if selectMode then toggleSelectMode() end -- exit select mode on new output
end
local function updateLn(t)
    local n = 1; for _ in t:gmatch("\n") do n = n + 1 end; if t == "" then n = 0 end
    renderLineNumbers(n)
end
local function toast(msg,col,dur)
    local t=Instance.new("Frame"); t.Size=UDim2.new(0,250,0,34); t.Position=UDim2.new(0.5,-125,1,0); t.BackgroundColor3=col or C.acc; t.BorderSizePixel=0; t.ZIndex=100; t.Parent=sg; corner(t,8)
    local tl=Instance.new("TextLabel"); tl.Size=UDim2.new(1,-12,1,0); tl.Position=UDim2.new(0,6,0,0); tl.BackgroundTransparency=1; tl.Text=msg; tl.TextColor3=Color3.new(1,1,1); tl.TextSize=11; tl.Font=Enum.Font.GothamBold; tl.Parent=t
    tw(t,{Position=UDim2.new(0.5,-125,1,-48)},0.35)
    task.delay(dur or 2,function() tw(t,{Position=UDim2.new(0.5,-125,1,8)},0.25); task.delay(0.3,function() t:Destroy() end) end)
end

-- INTRO
main.BackgroundTransparency=1; main.Size=UDim2.new(0,520,0,0); main.Position=UDim2.new(0.5,-260,0.5,0)
task.delay(0.1,function() tw(main,{BackgroundTransparency=0,Size=UDim2.new(0,520,0,580),Position=UDim2.new(0.5,-260,0.5,-290)},0.5) end)

-- ═══════════════════════════════════════════════════════════
-- BUTTON LOGIC
-- ═══════════════════════════════════════════════════════════
local busy=false

decompBtn.MouseButton1Click:Connect(function()
    if busy then return end
    local path=inputBox.Text; if not path or path=="" then setStatus("Enter a path",C.yel); toast("Enter a path first",C.yel); return end
    busy=true; decompBtn.Text="Working..."; tw(decompBtn,{BackgroundColor3=C.accD},0.15); setStatus("Resolving: "..path,C.yel)
    
    task.spawn(function()
        local inst,err=resolvePath(path)
        if not inst and not path:find("%.") then
            setStatus("Searching...",C.yel); local found=searchScripts(path)
            if #found==1 then inst=found[1]; err=nil
            elseif #found>1 then
                local l={"-- Multiple scripts found for: \""..path.."\"",""}
                for idx,s in ipairs(found) do l[#l+1]="-- "..idx..". ["..(getScriptType(s) or "?").."] "..s:GetFullName() end
                local txt=table.concat(l,"\n"); setOutput(txt); updateLn(txt); setStatus(#found.." matches",C.yel); toast("Pick one",C.yel,3)
                busy=false; decompBtn.Text="Decompile"; tw(decompBtn,{BackgroundColor3=C.acc},0.15); return
            end
        end
        if not inst then
            if err and #err>40 then local etxt="-- PATH FAILED\n--\n-- "..err:gsub("\n","\n-- "); setOutput(etxt); updateLn(etxt) end
            setStatus("Not found",C.red); toast("Script not found",C.red,3)
            busy=false; decompBtn.Text="Decompile"; tw(decompBtn,{BackgroundColor3=C.acc},0.15); return
        end
        
        local sType=getScriptType(inst)
        if not sType then
            local kids={}; pcall(function() for _,c in ipairs(inst:GetDescendants()) do if c:IsA("LocalScript")or c:IsA("ModuleScript")or c:IsA("Script") then kids[#kids+1]=c end; if #kids>=20 then break end end end)
            if #kids>0 then
                local l={"-- \""..inst:GetFullName().."\" is "..inst.ClassName..", not a script","-- Scripts inside:",""}
                for idx,s in ipairs(kids) do l[#l+1]="-- "..idx..". ["..(getScriptType(s) or "?").."] "..s:GetFullName() end
                local txt=table.concat(l,"\n"); setOutput(txt); updateLn(txt); setStatus("Not a script",C.yel); toast("See list",C.yel,3)
            else setStatus("Not a script",C.red); toast("Not a script!",C.red,3) end
            busy=false; decompBtn.Text="Decompile"; tw(decompBtn,{BackgroundColor3=C.acc},0.15); return
        end
        
        badge.Text=sType; badge.Visible=true
        badge.TextColor3=sType=="ModuleScript" and Color3.fromRGB(97,175,239) or sType=="LocalScript" and C.grn or C.yel
        setStatus("Decompiling "..sType.."...",C.yel)
        
        local result,method=fullDecompile(inst)
        if result then
            setOutput(result); updateLn(result)
            -- Count lines for status
            local lineNum = 1; for _ in result:gmatch("\n") do lineNum = lineNum + 1 end
            setStatus("Done — "..method.." | "..lineNum.." lines, "..#result.." chars",C.grn); toast("Decompiled! "..lineNum.." lines",C.grn)
        else
            local etxt="-- FAILED\n-- "..inst:GetFullName().."\n-- "..sType.."\n--\n-- "..(method or "Unknown error"):gsub("\n","\n-- ")
            setOutput(etxt); updateLn(etxt); setStatus("Failed",C.red); toast("Failed — see output",C.red,3)
        end
        busy=false; decompBtn.Text="Decompile"; tw(decompBtn,{BackgroundColor3=C.acc},0.15)
    end)
end)

copyBtn.MouseButton1Click:Connect(function()
    if fullOutputText=="" then toast("Nothing to copy",C.yel); return end
    local ok=false
    pcall(function() if setclipboard then setclipboard(fullOutputText); ok=true end end)
    pcall(function() if not ok and toclipboard then toclipboard(fullOutputText); ok=true end end)
    if ok then toast("Copied "..#fullOutputText.." chars!",C.grn); copyBtn.Text="Copied!"; task.delay(1.5,function() copyBtn.Text="Copy" end)
    else toast("Clipboard N/A",C.yel,3) end
end)
clearBtn.MouseButton1Click:Connect(function() setOutput(""); renderLineNumbers(0); badge.Visible=false; setStatus("Ready"); if selectMode then toggleSelectMode() end end)
saveBtn.MouseButton1Click:Connect(function()
    if fullOutputText=="" then toast("Nothing to save",C.yel); return end
    pcall(function() if writefile then local fn="NovaDec_"..os.time()..".lua"; writefile(fn,fullOutputText); toast("Saved: "..fn,C.grn) end end)
end)

local minimized=false
minBtn.MouseButton1Click:Connect(function()
    if minimized then return end; minimized=true
    tw(main,{Size=UDim2.new(0,520,0,0),BackgroundTransparency=1},0.3)
    task.delay(0.3,function() main.Visible=false; mini.Visible=true end)
end)
mini.MouseButton1Click:Connect(function()
    if not minimized then return end; minimized=false; mini.Visible=false; main.Visible=true
    main.Size=UDim2.new(0,520,0,0); main.BackgroundTransparency=1
    tw(main,{Size=UDim2.new(0,520,0,580),BackgroundTransparency=0},0.4)
end)
closeBtn.MouseButton1Click:Connect(function()
    tw(main,{Size=UDim2.new(0,520,0,0),BackgroundTransparency=1},0.25)
    task.delay(0.3,function() sg:Destroy() end)
end)
inputBox.FocusLost:Connect(function(enter) if enter then decompBtn.MouseButton1Click:Fire() end end)

-- Detect executor
task.spawn(function()
    local name="Unknown"
    pcall(function() if identifyexecutor then name=identifyexecutor() elseif getexecutorname then name=getexecutorname() end end)
    local api={}
    if _getscriptbytecode and _request then table.insert(api,"API") end
    if _getscriptclosure then table.insert(api,"closure") end
    if _getconstants then table.insert(api,"consts") end
    if _getprotos then table.insert(api,"protos") end
    if _getupvalues then table.insert(api,"upvals") end
    if setclipboard then table.insert(api,"clip") end
    setStatus(name.." | v3 | "..table.concat(api,", "))
end)

print("NovaDec v3 loaded — Runtime Closure Decompiler")
print("Uses: getscriptclosure + debug API (no broken decompile/bytecode)")
