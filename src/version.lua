local version = {}

-- pre-release tag deltas (same as luarocks/core/vers.lua)
local deltas = {
    dev  =  120000000,
    scm  =  110000000,
    cvs  =  100000000,
    rc   =     -1000,
    pre  =    -10000,
    beta =   -100000,
    alpha = -1000000,
}

-- parse a version string like "2.0rc1", "1.0.0-1", "5.2.0alpha.1-3"
function version.parse(vstring)
    if type(vstring) == "table" then
        return vstring
    end

    vstring = vstring:match("^%s*(.-)%s*$")
    local main = vstring
    local revision = nil

    local rev = main:match("-(%d+)$")
    if rev then
        revision = tonumber(rev)
        main = main:sub(1, -(#rev + 2))
    end

    local tokens = {}
    local idx = 0

    local rest = main
    while #rest > 0 do
        local num = rest:match("^(%d+)[%.%-_]*(.*)")
        if num then
            idx = idx + 1
            tokens[idx] = tokens[idx] and tokens[idx] + tonumber(num) / 100000 or tonumber(num)
            rest = num:len() < #rest and rest:sub(#num + 1) or ""
            rest = rest:match("^[%.%-_]*(.*)")
        else
            local alpha = rest:match("^(%a+)[%.%-_]*(.*)")
            if not alpha then
                break
            end
            tokens[idx] = tokens[idx] or 0
            tokens[idx] = deltas[alpha] or (alpha:byte() / 1000)
            rest = rest:sub(#alpha + 1)
            rest = rest:match("^[%.%-_]*(.*)")
        end
    end

    local result = tokens
    result.string = vstring
    result.revision = revision

    return result
end

-- returns true if a < b
function version.compare(a, b)
    if type(a) == "string" then a = version.parse(a) end
    if type(b) == "string" then b = version.parse(b) end

    local max_len = math.max(#a, #b)
    for i = 1, max_len do
        local ai = a[i] or 0
        local bi = b[i] or 0
        if ai ~= bi then
            return ai < bi
        end
    end

    if a.revision and b.revision then
        return a.revision < b.revision
    elseif a.revision then
        return false
    elseif b.revision then
        return true
    end

    return false
end

function version.eq(a, b)
    return not version.compare(a, b) and not version.compare(b, a)
end

function version.lte(a, b)
    return version.compare(a, b) or version.eq(a, b)
end

function version.gte(a, b)
    return not version.compare(a, b)
end

function version.lt(a, b)
    return version.compare(a, b)
end

function version.gt(a, b)
    return version.compare(b, a)
end

-- pessimistic/~> constraint: prefix match
function version.partial_match(actual, requested)
    if type(actual) == "string" then actual = version.parse(actual) end
    if type(requested) == "string" then requested = version.parse(requested) end

    for i = 1, #requested do
        if (actual[i] or 0) ~= requested[i] then
            return false
        end
    end

    if requested.revision then
        return requested.revision == actual.revision
    end

    return true
end

-- match a parsed version against a list of {op=">=", version=parsed_version} constraints
function version.match_constraints(ver, constraints)
    if type(ver) == "string" then ver = version.parse(ver) end

    for _, c in ipairs(constraints) do
        local cv = type(c.version) == "string" and version.parse(c.version) or c.version
        local op = c.op

        if op == "==" or op == "=" or op == "" then
            if not version.eq(ver, cv) then return false end
        elseif op == "~=" or op == "!=" then
            if version.eq(ver, cv) then return false end
        elseif op == "<" then
            if not version.lt(ver, cv) then return false end
        elseif op == ">" then
            if not version.gt(ver, cv) then return false end
        elseif op == "<=" then
            if not version.lte(ver, cv) then return false end
        elseif op == ">=" then
            if not version.gte(ver, cv) then return false end
        elseif op == "~>" then
            if not version.partial_match(ver, cv) then return false end
        end
    end

    return true
end

-- find the latest version from a {version_string -> {}} table that satisfies constraints
function version.find_latest(versions, constraints)
    local best = nil

    for vs, _ in pairs(versions) do
        if constraints == nil or #constraints == 0 or version.match_constraints(vs, constraints) then
            local pv = version.parse(vs)
            if best == nil or version.compare(best, pv) then
                best = pv
            end
        end
    end

    if best == nil then return nil end
    return best.string or best
end

-- sort version strings, latest first
function version.sort_latest(version_strings)
    local result = {}
    for vs in pairs(version_strings) do
        table.insert(result, vs)
    end
    table.sort(result, function(a, b)
        return version.compare(version.parse(b), version.parse(a))
    end)
    return result
end

return version
