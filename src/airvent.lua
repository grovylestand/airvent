local airvent = {}
local setmetatable = setmetatable
local getmetatable = getmetatable
local pairs = pairs
local ipairs = ipairs
local type = type
local pcall = pcall
local error = error
local assert = assert
local tonumber = tonumber
local tostring = tostring
local print = print
local table = table
local math = math
local string = string
local coroutine = coroutine
local os = os
local _G = _G

local exprCache = {}

local LUA_KEYWORDS = {
    ["and"] = true, ["or"] = true, ["not"] = true,
    ["true"] = true, ["false"] = true, ["nil"] = true
}

local SAFE_FUNCS = {
    ["math.floor"] = math.floor,
    ["math.ceil"] = math.ceil,
    ["math.abs"] = math.abs,
    ["math.min"] = math.min,
    ["math.max"] = math.max,
    ["math.sqrt"] = math.sqrt,
    ["string.len"] = string.len,
    ["string.sub"] = string.sub,
    ["string.find"] = string.find,
    ["string.lower"] = string.lower,
    ["string.upper"] = string.upper,
    ["tonumber"] = tonumber,
    ["tostring"] = tostring,
    ["type"] = type
}

local RESERVED_NAMES = {
    trigger = true, check = true, destroy = true,
    pause = true, resume = true, remove = true, reset = true,
    watch = true, set = true, update = true, waitFor = true,
    inspect = true, history = true
}

local function extractDependencies(expr)
    local stripped = expr:gsub("%b''", " "):gsub('%b""', " ")
    local deps = {}
    local seen = {}

    for ident in stripped:gmatch("[%a_][%w_%.]*") do
        if not LUA_KEYWORDS[ident] and not SAFE_FUNCS[ident] and not seen[ident] then
            seen[ident] = true
            table.insert(deps, ident)
        end
    end
    return deps
end

local function resolveFromCaller(path, callerEnv, callerLocals)
    local segments = {}
    for seg in path:gmatch("[^%.]+") do
        table.insert(segments, seg)
    end

    local rootName = segments[1]
    local curr
    if callerLocals and callerLocals[rootName] ~= nil then
        curr = callerLocals[rootName]
    elseif callerEnv and callerEnv[rootName] ~= nil then
        curr = callerEnv[rootName]
    else
        curr = _G[rootName]
    end

    for i = 2, #segments do
        if type(curr) ~= "table" then return nil end
        curr = curr[segments[i]]
    end

    return curr
end


local function captureCallerLocals(stackLevel)
    local locals = {}
    if not debug or not debug.getlocal then
        return locals
    end

    local i = 1
    while true do
        local name, value = debug.getlocal(stackLevel, i)
        if not name then break end
        if name:sub(1, 1) ~= "(" then
            locals[name] = value
        end
        i = i + 1
    end

    local info = debug.getinfo and debug.getinfo(stackLevel, "f")
    if info and info.func and debug.getupvalue then
        local u = 1
        while true do
            local name, value = debug.getupvalue(info.func, u)
            if not name then break end
            if locals[name] == nil then
                locals[name] = value
            end
            u = u + 1
        end
    end

    return locals
end

local function captureCallerEnv(stackLevel)
    if debug and debug.getinfo and debug.getupvalue then
        local info = debug.getinfo(stackLevel, "f")
        if info and info.func then
            local u = 1
            while true do
                local name, value = debug.getupvalue(info.func, u)
                if not name then break end
                if name == "_ENV" and type(value) == "table" then
                    return value
                end
                u = u + 1
            end
        end
    end

    return _G
end

local function tokenize(expr)
    local tokens = {}
    local i = 1
    local len = #expr

    while i <= len do
        local c = expr:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == "'" or c == '"' then
            local quote = c
            local j = i + 1
            while j <= len and expr:sub(j, j) ~= quote do
                if expr:sub(j, j) == "\\" then j = j + 1 end
                j = j + 1
            end
            if j > len then error("[airvent] Unterminated string in expression: " .. expr, 3) end
            table.insert(tokens, { type = "STRING", value = expr:sub(i + 1, j - 1) })
            i = j + 1
        elseif c:match("%d") or (c == "." and expr:sub(i + 1, i + 1):match("%d")) then
            local numStr = expr:match("^%d*%.?%d+", i)
            table.insert(tokens, { type = "NUMBER", value = tonumber(numStr) })
            i = i + #numStr
        elseif expr:sub(i, i + 1) == "==" or expr:sub(i, i + 1) == "~=" or expr:sub(i, i + 1) == "!="
            or expr:sub(i, i + 1) == "<=" or expr:sub(i, i + 1) == ">=" or expr:sub(i, i + 1) == ".." then
            local op = expr:sub(i, i + 1)
            if op == "!=" then op = "~=" end
            table.insert(tokens, { type = "OP", value = op })
            i = i + 2
        elseif c:match("[<>%+%-*/%%%(%)#,%.]") then
            table.insert(tokens, { type = "OP", value = c })
            i = i + 1
        elseif c:match("[%a_]") then
            local ident = expr:match("^[%a_][%w_%.]*", i)
            if ident == "and" or ident == "or" or ident == "not" then
                table.insert(tokens, { type = "OP", value = ident })
            elseif ident == "true" then
                table.insert(tokens, { type = "BOOL", value = true })
            elseif ident == "false" then
                table.insert(tokens, { type = "BOOL", value = false })
            elseif ident == "nil" then
                table.insert(tokens, { type = "NIL", value = nil })
            else
                table.insert(tokens, { type = "IDENT", value = ident })
            end
            i = i + #ident
        else
            error("[airvent] Unexpected character '" .. c .. "' in expression: " .. expr, 3)
        end
    end

    return tokens
end

local function compileCondition(expr)
    if exprCache[expr] then
        return exprCache[expr].fn, exprCache[expr].deps
    end

    local deps = extractDependencies(expr)
    local tokens = tokenize(expr)

    local function compiledFn(callerEnv, callerLocals)
        local pos = 1

        local function peek()
            return tokens[pos]
        end

        local function consume()
            local t = tokens[pos]
            pos = pos + 1
            return t
        end

        local parseOr

        local function parsePrimary()
            local t = peek()
            if not t then error("[airvent] Unexpected end of expression: " .. expr, 3) end

            if t.type == "NUMBER" or t.type == "STRING" or t.type == "BOOL" or t.type == "NIL" then
                consume()
                return t.value
            elseif t.type == "IDENT" then
                consume()
                local nextTok = peek()
                if nextTok and nextTok.type == "OP" and nextTok.value == "(" then
                    local fn = SAFE_FUNCS[t.value]
                    if not fn then
                        error("[airvent] Disallowed or unknown function '" .. t.value .. "' in expression: " .. expr, 3)
                    end
                    consume()
                    local args = {}
                    if not (peek() and peek().type == "OP" and peek().value == ")") then
                        while true do
                            table.insert(args, parseOr())
                            local sep = peek()
                            if sep and sep.type == "OP" and sep.value == "," then
                                consume()
                            else
                                break
                            end
                        end
                    end
                    local close = consume()
                    if not close or close.value ~= ")" then
                        error("[airvent] Expected ')' after arguments in expression: " .. expr, 3)
                    end
                    return fn(table.unpack(args))
                end
                return resolveFromCaller(t.value, callerEnv, callerLocals)
            elseif t.type == "OP" and t.value == "(" then
                consume()
                local val = parseOr()
                local close = consume()
                if not close or close.value ~= ")" then
                    error("[airvent] Expected ')' in expression: " .. expr, 3)
                end
                return val
            end

            error("[airvent] Unexpected token '" .. tostring(t.value) .. "' in expression: " .. expr, 3)
        end

        local function parseUnary()
            local t = peek()
            if t and t.type == "OP" and t.value == "not" then
                consume()
                return not parseUnary()
            elseif t and t.type == "OP" and t.value == "-" then
                consume()
                return -parseUnary()
            elseif t and t.type == "OP" and t.value == "#" then
                consume()
                return #parseUnary()
            end
            return parsePrimary()
        end

        local function parseMul()
            local left = parseUnary()
            while true do
                local t = peek()
                if t and t.type == "OP" and (t.value == "*" or t.value == "/" or t.value == "%") then
                    consume()
                    local right = parseUnary()
                    if t.value == "*" then left = left * right
                    elseif t.value == "/" then left = left / right
                    else left = left % right end
                else
                    break
                end
            end
            return left
        end

        local function parseAdd()
            local left = parseMul()
            while true do
                local t = peek()
                if t and t.type == "OP" and (t.value == "+" or t.value == "-" or t.value == "..") then
                    consume()
                    local right = parseMul()
                    if t.value == "+" then left = left + right
                    elseif t.value == "-" then left = left - right
                    else left = tostring(left) .. tostring(right) end
                    else
                        break
                end
            end
            return left
        end
        local function parseCompare()
            local left = parseAdd()
            while true do
                local t = peek()
                if t and t.type == "OP" and (t.value == "==" or t.value == "~=" or t.value == "<"
                    or t.value == ">" or t.value == "<=" or t.value == ">=") then
                    consume()
                    local right = parseAdd()
                    if t.value == "==" then
                        left = (left == right)
                    elseif t.value == "~=" then
                        left = (left ~= right)
                    elseif left == nil or right == nil then
                        left = false
                    elseif t.value == "<" then
                        left = (left < right)
                    elseif t.value == ">" then
                        left = (left > right)
                    elseif t.value == "<=" then
                        left = (left <= right)
                    elseif t.value == ">=" then
                        left = (left >= right)
                    end
                else
                    break
                end
            end
            return left
        end
        local function parseAnd()
            local left = parseCompare()
            while true do
    local t = peek()
    if t and t.type == "OP" and t.value == "and" then
        consume()
        local right = parseCompare()
        left = (left and right)
    else
        break
    end
            end
            return left
        end
        parseOr = function()
            local left = parseAnd()
            while true do
                local t = peek()
                if t and t.type == "OP" and t.value == "or" then
                    consume()
                    local right = parseAnd()
                    left = (left or right)
                else
                    break
                end
            end
            return left
        end
        return parseOr()
    end
    exprCache[expr] = { fn = compiledFn, deps = deps }
    return compiledFn, deps
end
function airvent.new(opts)
    opts = opts or {}
    local defaultEnv = opts.env or captureCallerEnv(2)
    local internal = {
        triggers = {},
        triggerOrder = {},
        watchedRoots = {},
        proxiedTables = setmetatable({}, { __mode = "k" }),
        waiters = {},
        historyLog = {},
        historyLimit = opts.historyLimit or 50,
        elapsed = 0,
        callDepth = {},
        maxRecursion = opts.maxRecursion or 15,
        onError = opts.onError or function(err) print("[airvent Error] " .. tostring(err)) end,
        autoHook = opts.autoWatch ~= false,
        originalEnv = defaultEnv,
        hookedEnv = nil
    }
    local instance = {}
    function internal:recordHistory(name, payload)
        if self.historyLimit <= 0 then return end
            table.insert(self.historyLog, {
                name = name,
                timestamp = os.time(),
                elapsed = self.elapsed,
                data = payload
            })
            if #self.historyLog > self.historyLimit then
                table.remove(self.historyLog, 1)
            end
    end
    function internal:wrapTable(tbl)
        if type(tbl) ~= "table" then return tbl end
            if self.proxiedTables[tbl] then return self.proxiedTables[tbl] end
                local mt = getmetatable(tbl)
                if mt and mt.__airventProxy then return tbl end
                    local backing = {}
                    for k, v in pairs(tbl) do
                        backing[k] = self:wrapTable(v)
                        tbl[k] = nil
                    end
                    local proxyMeta = {
                        __airventProxy = true,
                        __airventBacking = backing,
                        __airventOrigMeta = mt,
                        __index = function(_, k)
                            local val = backing[k]
                            if val ~= nil then return val end
                                if mt and mt.__index then
                                    if type(mt.__index) == "function" then
                                        return mt.__index(tbl, k)
                                    elseif type(mt.__index) == "table" then
                                        return mt.__index[k]
                                    end
                                end
                                return nil
                        end,
                        __newindex = function(_, k, v)
                            local oldVal = backing[k]
                            local wrapped = self:wrapTable(v)
                            if mt and type(mt.__newindex) == "function" then
                                mt.__newindex(tbl, k, wrapped)
                            else
                                backing[k] = wrapped
                            end
                            if oldVal ~= wrapped then
                                self:evaluateAll(self.originalEnv, captureCallerLocals(3))
                            end
                        end,
                        __pairs = function()
                            return pairs(backing)
                        end,
                        __len = function()
                            return #backing
                        end
                    }
                    setmetatable(tbl, proxyMeta)
                    self.proxiedTables[tbl] = tbl
                    return tbl
    end
    function internal:unwrapAllTables()
        for tbl in pairs(self.proxiedTables) do
            local mt = getmetatable(tbl)
            if mt and mt.__airventProxy then
                setmetatable(tbl, mt.__airventOrigMeta)
                for k, v in pairs(mt.__airventBacking) do
                    tbl[k] = v
                end
            end
        end
        self.proxiedTables = setmetatable({}, { __mode = "k" })
    end
    function internal:resolveWaiters(eventName, payload, callerEnv, callerLocals)
        for i = #self.waiters, 1, -1 do
            local w = self.waiters[i]
            local matched = false
            if w.eventName and w.eventName == eventName then
                matched = true
            elseif w.conditionFn then
                local ok, res = pcall(w.conditionFn, callerEnv, callerLocals)
                if ok and res then
                    matched = true
                end
            end
            if matched then
                table.remove(self.waiters, i)
                coroutine.resume(w.co, true, payload)
            end
        end
    end
    function internal:getOrCreateTrigger(name)
        assert(type(name) == "string" and name ~= "", "[airvent] Trigger name must be a non-empty string")
        assert(not RESERVED_NAMES[name], "[airvent] Reserved keyword cannot be used as trigger name: " .. name)
        if not self.triggers[name] then
            self.triggers[name] = {
                name = name,
                listeners = {},
                conditionFn = nil,
                isStringExpr = false,
                deps = {},
                edgeTriggered = true,
                lastMatched = false,
                active = true,
                debounce = nil,
                throttle = nil,
                debounceTimer = nil,
                lastFiredAt = -math.huge
            }
            table.insert(self.triggerOrder, self.triggers[name])
        end
        return self.triggers[name]
    end
    function internal:executeTrigger(trig, payload, callerEnv, callerLocals)
        local name = trig.name
        local depth = (self.callDepth[name] or 0) + 1
        if depth > self.maxRecursion then
            self.onError("Max recursion depth (" .. self.maxRecursion .. ") exceeded for trigger '" .. name .. "'")
            return payload, true
        end
        self.callDepth[name] = depth
        trig.lastFiredAt = self.elapsed
        self:recordHistory(name, payload)
        local eventObj = {
            name = name,
            data = payload or {},
            cancelled = false,
            cancel = function(e) e.cancelled = true end
                }
                local snapshot = {}
                for i = 1, #trig.listeners do
                    snapshot[i] = trig.listeners[i]
                end
                for _, listener in ipairs(snapshot) do
                    if listener.active then
                        if listener.once then
                            listener.active = false
                        end
                        local ok, err = pcall(listener.callback, eventObj)
                        if not ok then
                            self.onError("Error in trigger '" .. name .. "': " .. tostring(err))
                        end
                        if eventObj.cancelled then
                            break
                        end
                    end
                end
                for i = #trig.listeners, 1, -1 do
                    if not trig.listeners[i].active then
                        table.remove(trig.listeners, i)
                    end
                end
                self.callDepth[name] = depth - 1
                self:resolveWaiters(name, eventObj.data, callerEnv, callerLocals)
                return eventObj.data, eventObj.cancelled
    end
    function internal:fireTrigger(name, payload, callerEnv, callerLocals)
        local trig = self.triggers[name]
        if not trig or not trig.active then
            self:resolveWaiters(name, payload, callerEnv, callerLocals)
            return payload, false
        end
        if trig.debounce and trig.debounce > 0 then
            trig.debounceTimer = trig.debounce
            trig.pendingPayload = payload
            return payload, false
        end
        if trig.throttle and trig.throttle > 0 then
            if (self.elapsed - trig.lastFiredAt) < trig.throttle then
                return payload, false
            end
        end
        if #trig.listeners == 0 then
            self:recordHistory(name, payload)
            self:resolveWaiters(name, payload, callerEnv, callerLocals)
            return payload, false
        end
        return self:executeTrigger(trig, payload, callerEnv, callerLocals)
    end
    function internal:evaluateAll(callerEnv, callerLocals)
        for _, trig in ipairs(self.triggerOrder) do
            if trig.active and trig.conditionFn then
                local ok, matched
                if trig.isStringExpr then
                    ok, matched = pcall(trig.conditionFn, callerEnv, callerLocals)
                else
                    ok, matched = pcall(trig.conditionFn)
                end
                if not ok then
                    self.onError("Condition error in trigger '" .. trig.name .. "': " .. tostring(matched))
                else
                    matched = not not matched
                    local shouldFire = matched and (not trig.edgeTriggered or not trig.lastMatched)
                    trig.lastMatched = matched
                    if shouldFire then
                        self:fireTrigger(trig.name, nil, callerEnv, callerLocals)
                    end
                end
            end
        end
        self:resolveWaiters(nil, nil, callerEnv, callerLocals)
    end
    function internal:installEnvHook()
        if not self.autoHook or self.hookedEnv then return end
            local backing = {}
            local origMeta = getmetatable(self.originalEnv)
            local origIndex = origMeta and origMeta.__index
            local origNewIndex = origMeta and origMeta.__newindex
            for k, v in pairs(self.originalEnv) do
                backing[k] = v
                self.originalEnv[k] = nil
            end
            local hookMeta = {
                __index = function(_, key)
                    local val = backing[key]
                    if val ~= nil then return val end
                        if type(origIndex) == "function" then
                            return origIndex(self.originalEnv, key)
                        elseif type(origIndex) == "table" then
                            return origIndex[key]
                        end
                        return nil
                end,
                __newindex = function(_, key, newVal)
                    local oldVal = backing[key]
                    if self.watchedRoots[key] and type(newVal) == "table" then
                        newVal = self:wrapTable(newVal)
                    end
                    if type(origNewIndex) == "function" then
                        origNewIndex(self.originalEnv, key, newVal)
                    else
                        backing[key] = newVal
                    end
                    if oldVal ~= newVal and self.watchedRoots[key] then
                        self:evaluateAll(self.originalEnv, captureCallerLocals(3))
                    end
                end,
                __pairs = function()
                    return pairs(backing)
                end
            }
            setmetatable(self.originalEnv, hookMeta)
            self.hookedEnv = { backing = backing, origMeta = origMeta }
    end
    function instance.check()
        local callerLocals = captureCallerLocals(2)
        internal:evaluateAll(internal.originalEnv, callerLocals)
    end
    function instance.trigger(name, arg2, arg3, arg4)
        local trig = internal:getOrCreateTrigger(name)
        local condition, callback, trigOpts
        if type(arg2) == "function" and (arg3 == nil or type(arg3) == "table") then
            callback = arg2
            trigOpts = arg3 or {}
        else
            condition = arg2
            callback = arg3
            trigOpts = arg4 or {}
        end
        assert(type(callback) == "function", "[airvent] Expected a callback function for trigger '" .. name .. "'")
        if trigOpts.debounce ~= nil then trig.debounce = trigOpts.debounce end
            if trigOpts.throttle ~= nil then trig.throttle = trigOpts.throttle end
                if condition ~= nil then
                    if trigOpts.edgeTriggered ~= nil then
                        trig.edgeTriggered = trigOpts.edgeTriggered
                    end
                    local callerEnv = internal.originalEnv
                    local callerLocals = captureCallerLocals(2)
                    if type(condition) == "string" then
                        local fn, deps = compileCondition(condition)
                        trig.conditionFn = fn
                        trig.isStringExpr = true
                        trig.deps = deps
                        for _, dep in ipairs(deps) do
                            local root = dep:match("^([^%.]+)")
                            if root then
                                internal.watchedRoots[root] = true
                                local val = resolveFromCaller(root, callerEnv, callerLocals)
                                if type(val) == "table" then
                                    internal:wrapTable(val)
                                end
                            end
                        end
                        internal:installEnvHook()
                        local ok, initialMatch = pcall(fn, callerEnv, callerLocals)
                        if ok then
                            trig.lastMatched = not not initialMatch
                        end
                    elseif type(condition) == "function" then
                        trig.conditionFn = condition
                        trig.isStringExpr = false
                        if type(trigOpts.vars) == "table" then
                            trig.deps = trigOpts.vars
                            for _, dep in ipairs(trigOpts.vars) do
                                local root = dep:match("^([^%.]+)")
                                if root then
                                    internal.watchedRoots[root] = true
                                    local val = resolveFromCaller(root, callerEnv, callerLocals)
                                    if type(val) == "table" then
                                        internal:wrapTable(val)
                                    end
                                end
                            end
                            internal:installEnvHook()
                        end
                        local ok, initialMatch = pcall(condition)
                        if ok then
                            trig.lastMatched = not not initialMatch
                        end
                    else
                        error("[airvent] Condition must be a string expression or predicate function", 2)
                    end
                end
                local listener = {
                    callback = callback,
                    priority = trigOpts.priority or 0,
                    once = trigOpts.once or false,
                    active = true
                }
                table.insert(trig.listeners, listener)
                table.sort(trig.listeners, function(a, b)
                    return a.priority > b.priority
                end)
                return function()
                    listener.active = false
                end
    end
    function instance.pause(name)
        local trig = internal.triggers[name]
        if trig then trig.active = false end
        end
        function instance.resume(name)
            local trig = internal.triggers[name]
            if trig then trig.active = true end
            end
            function instance.remove(name)
                local trig = internal.triggers[name]
                if not trig then return false end
                    internal.triggers[name] = nil
                    for i = #internal.triggerOrder, 1, -1 do
                        if internal.triggerOrder[i] == trig then
                            table.remove(internal.triggerOrder, i)
                            break
                        end
                    end
                    return true
            end
            function instance.reset(name)
                local trig = internal.triggers[name]
                if trig then
                    trig.lastMatched = false
                    trig.debounceTimer = nil
                end
            end
            function instance.watch(tbl, rootName)
                assert(type(tbl) == "table", "[airvent] Expected a table to watch")
                if type(rootName) == "string" and rootName ~= "" then
                    internal.watchedRoots[rootName] = true
                    internal:installEnvHook()
                end
                return internal:wrapTable(tbl)
            end
            function instance.set(path, value)
                assert(type(path) == "string" and path ~= "", "[airvent] Path must be a non-empty string")
                local segments = {}
                for seg in path:gmatch("[^%.]+") do
                    table.insert(segments, seg)
                end

                local callerEnv = internal.originalEnv
                local callerLocals = captureCallerLocals(2)
                local root = table.remove(segments, 1)

                if #segments == 0 then
                    callerEnv[root] = value
                else
                    local curr = resolveFromCaller(root, callerEnv, callerLocals)
                    for i = 1, #segments - 1 do
                        if type(curr) ~= "table" then
                            error("[airvent] Invalid intermediate path segment: " .. segments[i], 2)
                        end
                        curr = curr[segments[i]]
                    end
                    if type(curr) ~= "table" then
                        error("[airvent] Target parent is not a table for path: " .. path, 2)
                    end
                    curr[segments[#segments]] = value
                end

                internal:evaluateAll(callerEnv, callerLocals)
            end
            function instance.update(dt)
                assert(type(dt) == "number" and dt >= 0, "[airvent] dt must be a non-negative number")
                internal.elapsed = internal.elapsed + dt
                local callerEnv = captureCallerEnv(2)
                local callerLocals = captureCallerLocals(2)
                for _, trig in ipairs(internal.triggerOrder) do
                    if trig.active and trig.debounceTimer then
                        trig.debounceTimer = trig.debounceTimer - dt
                        if trig.debounceTimer <= 0 then
                            trig.debounceTimer = nil
                            local payload = trig.pendingPayload
                            trig.pendingPayload = nil
                            internal:executeTrigger(trig, payload, callerEnv, callerLocals)
                        end
                    end
                end
                for i = #internal.waiters, 1, -1 do
                    local w = internal.waiters[i]
                    if w.timeout then
                        w.timeout = w.timeout - dt
                        if w.timeout <= 0 then
                            table.remove(internal.waiters, i)
                            coroutine.resume(w.co, false, "timeout")
                        end
                    end
                end
            end
            function instance.waitFor(conditionOrName, timeout)
                local co = coroutine.running()
                assert(co ~= nil, "[airvent] waitFor must be called inside a coroutine")

                local waiter = {
                    co = co,
                    timeout = timeout
                }

                if internal.triggers[conditionOrName] then
                    waiter.eventName = conditionOrName
                elseif type(conditionOrName) == "function" then
                    waiter.conditionFn = conditionOrName
                elseif type(conditionOrName) == "string" then
                    local isExpr = conditionOrName:find("[=<>~%+%-*/%%%(%)#]") ~= nil
                        or conditionOrName:match("^not%s") ~= nil
                        or conditionOrName:find("%sand%s") ~= nil
                        or conditionOrName:find("%sor%s") ~= nil

                    if isExpr then
                        local fn, deps = compileCondition(conditionOrName)
                        waiter.conditionFn = fn
                        local callerEnv = internal.originalEnv
                        local callerLocals = captureCallerLocals(2)
                        for _, dep in ipairs(deps) do
                            local root = dep:match("^([^%.]+)")
                            if root then
                                internal.watchedRoots[root] = true
                                local val = resolveFromCaller(root, callerEnv, callerLocals)
                                if type(val) == "table" then
                                    internal:wrapTable(val)
                                end
                            end
                        end
                        internal:installEnvHook()
                    else
                        waiter.eventName = conditionOrName
                    end
                else
                    error("[airvent] waitFor expects a trigger name, condition string, or predicate function", 2)
                end

                table.insert(internal.waiters, waiter)
                return coroutine.yield()
            end

            function instance.inspect(name)
                local trig = internal.triggers[name]
                if not trig then return nil end
                    local activeListeners = 0
                    for _, l in ipairs(trig.listeners) do
                        if l.active then activeListeners = activeListeners + 1 end
                        end
                        return {
                            name = trig.name,
                            active = trig.active,
                            lastMatched = trig.lastMatched,
                            edgeTriggered = trig.edgeTriggered,
                            listenerCount = activeListeners,
                            dependencies = trig.deps,
                            debounce = trig.debounce,
                            throttle = trig.throttle
                        }
            end
            function instance.history(limit)
                local total = #internal.historyLog
                local count = limit and math.min(limit, total) or total
                local result = {}
                for i = total - count + 1, total do
                    table.insert(result, internal.historyLog[i])
                end
                return result
            end
            function instance.destroy()
                internal:unwrapAllTables()
                if internal.hookedEnv then
                    setmetatable(internal.originalEnv, internal.hookedEnv.origMeta)
                    for k, v in pairs(internal.hookedEnv.backing) do
                        internal.originalEnv[k] = v
                    end
                    internal.hookedEnv = nil
                end
                for i = #internal.waiters, 1, -1 do
                    local w = internal.waiters[i]
                    table.remove(internal.waiters, i)
                    coroutine.resume(w.co, false, "destroyed")
                end
                internal.triggers = {}
                internal.triggerOrder = {}
                internal.historyLog = {}
            end
            return setmetatable(instance, {
                __index = function(_, triggerName)
                    return function(payload)
                        local callerEnv = captureCallerEnv(2)
                        local callerLocals = captureCallerLocals(2)
                        internal:evaluateAll(callerEnv, callerLocals)
                        return internal:fireTrigger(triggerName, payload, callerEnv, callerLocals)
                    end
                end
            })
end
return airvent
