local sandbox = {}

local MAX_LINES = 2000

-- safely evaluate a rockspec string, returning a table of all fields or nil, error
function sandbox.evaluate(text)
    -- strip shebang
    text = text:gsub("^#[^\n]*\n?", "")

    local spec = {}
    local fn, err = load(text, "rockspec", "t", spec)
    if not fn then
        return nil, "parse error: " .. err
    end

    if jit then jit.off(fn) end

    local lines = 0
    local function check_hook()
        lines = lines + 1
        if lines > MAX_LINES then
            debug.sethook()
            error("too many lines evaluated")
        end
    end

    debug.sethook(check_hook, "l")
    local ok, result = pcall(fn)
    debug.sethook()

    if not ok then
        return nil, "eval error: " .. tostring(result)
    end

    if type(spec.package) ~= "string" or spec.package == "" then
        return nil, "missing or invalid package name"
    end
    if type(spec.version) ~= "string" or spec.version == "" then
        return nil, "missing or invalid version"
    end

    return spec
end

return sandbox
