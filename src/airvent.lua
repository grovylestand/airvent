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
local _G = _G

local exprCache = {}

local LUA_KEYWORDS = {
    ["and"] = true, ["or"] = true, ["not"] = true,
    ["true"] = true, ["false"] = true, ["nil"] = true
}

local function extractDependencies(expr)
    local stripped = expr:gsub("%b''", " "):gsub('%b""', " ")
    local deps = {}
    local seen = {}

    for ident in stripped:gmatch("[%a_][%w_%.]*") do
        if not LUA_KEYWORDS[ident] and not seen[ident] then
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
            or expr:sub(i, i + 1) == "<=" or expr:sub(i, i + 1) == ">=" then
            local op = expr:sub(i, i + 1)
            if op == "!=" then op = "~=" end
            table.insert(tokens, { type = "OP", value = op })
            i = i + 2
        elseif c:match("[<>%+%-*/%%%(%)]") then
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
                if t and t.type == "OP" and (t.value == "+" or t.value == "-") then
                    consume()
                    local right = parseMul()
                    if t.value == "+" then left = left + right
                    else left = left - right end
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
                    if t.value == "==" then left = (left == right)
                    elseif t.value == "~=" then left = (left ~= right)
                    elseif t.value == "<" then left = (left < right)
                    elseif t.value == ">" then left = (left > right)
                    elseif t.value == "<=" then left = (left <= right)
                    elseif t.value == ">=" then left = (left >= right) end
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
        callDepth = {},
        maxRecursion = opts.maxRecursion or 15,
        onError = opts.onError or function(err) print("[airvent Error] " .. tostring(err)) end,
        autoHook = opts.autoWatch ~= false,
        originalEnv = defaultEnv,
        hookedEnv = nil
    }
    local instance = {}
    function internal:getOrCreateTrigger(name)
        assert(type(name) == "string" and name ~= "", "[airvent] Trigger name must be a non-empty string")
        assert(name ~= "trigger" and name ~= "check" and name ~= "destroy",
            "[airvent] Reserved keyword cannot be used as trigger name: " .. name)
        if not self.triggers[name] then
            self.triggers[name] = {
                name = name,
                listeners = {},
                conditionFn = nil,
                isStringExpr = false,
                edgeTriggered = true,
                lastMatched = false,
                active = true
            }
            table.insert(self.triggerOrder, self.triggers[name])
        end
        return self.triggers[name]
    end
    function internal:fireTrigger(name, payload, callerEnv, callerLocals)
        local trig = self.triggers[name]
        if not trig or not trig.active or #trig.listeners == 0 then
            return payload, false
        end
        local depth = (self.callDepth[name] or 0) + 1
        if depth > self.maxRecursion then
            self.onError("Max recursion depth (" .. self.maxRecursion .. ") exceeded for trigger '" .. name .. "'")
            return payload, true
        end
        self.callDepth[name] = depth
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
        return eventObj.data, eventObj.cancelled
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
                local callerEnv = captureCallerEnv(3)
                local callerLocals = captureCallerLocals(3)
                internal:evaluateAll(callerEnv, callerLocals)
            end
            function instance.trigger(name, arg2, arg3, arg4)
                local trig = internal:getOrCreateTrigger(name)
                local condition, callback, opts
                if type(arg2) == "function" and (arg3 == nil or type(arg3) == "table") then
                    callback = arg2
                    opts = arg3 or {}
                else
                    condition = arg2
                    callback = arg3
                    opts = arg4 or {}
                end
                assert(type(callback) == "function", "[airvent] Expected a callback function for trigger '" .. name .. "'")
                if condition ~= nil then
                    if opts.edgeTriggered ~= nil then
                        trig.edgeTriggered = opts.edgeTriggered
                    end
                    local callerEnv = captureCallerEnv(3)
                    local callerLocals = captureCallerLocals(3)
                    if type(condition) == "string" then
                        local fn, deps = compileCondition(condition)
                        trig.conditionFn = fn
                        trig.isStringExpr = true
                        for _, dep in ipairs(deps) do
                            local root = dep:match("^([^%.]+)")
                            if root then
                                internal.watchedRoots[root] = true
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
                        if type(opts.vars) == "table" then
                            for _, dep in ipairs(opts.vars) do
                                local root = dep:match("^([^%.]+)")
                                if root then
                                    internal.watchedRoots[root] = true
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
                    priority = opts.priority or 0,
                    once = opts.once or false,
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
            function instance.destroy()
                if internal.hookedEnv then
                    setmetatable(internal.originalEnv, internal.hookedEnv.origMeta)
                    for k, v in pairs(internal.hookedEnv.backing) do
                        internal.originalEnv[k] = v
                    end
                    internal.hookedEnv = nil
                end
                internal.triggers = {}
                internal.triggerOrder = {}
            end
            return setmetatable(instance, {
                __index = function(_, triggerName)
                    return function(payload)
                        local callerEnv = captureCallerEnv(3)
                        local callerLocals = captureCallerLocals(3)
                        internal:evaluateAll(callerEnv, callerLocals)
                        return internal:fireTrigger(triggerName, payload, callerEnv, callerLocals)
                    end
                end
            })
end
return airvent
