local cjson = require("cjson")

local manifest = {}

local LUAROCKS_BASE = "https://luarocks.org"

local function http_get(url)
    local f = io.popen("curl -fsSL --max-time 30 '" .. url .. "' 2>/dev/null")
    if not f then return nil end
    local body = f:read("*a")
    local ok = f:close()
    if not ok then return nil end
    return body
end

-- load luarocks.org manifest.json
-- returns { repository = { package_name = { version = [{arch="rockspec"}, ...] } } }
function manifest.load_json(path)
    local f = io.open(path, "r")
    if not f then return nil, "cannot open manifest: " .. path end
    local content = f:read("*a")
    f:close()
    return cjson.decode(content)
end

-- fetch manifest.json from luarocks.org
function manifest.fetch_json()
    local body = http_get(LUAROCKS_BASE .. "/manifest.json")
    if not body then
        return nil, "failed to fetch manifest.json"
    end
    return cjson.decode(body)
end

-- get all packages from the manifest
function manifest.get_packages(m)
    return m.repository or {}
end

-- get versions for a package: { version_string = [{arch="rockspec"}, ...] }
function manifest.get_versions(m, package_name)
    local repo = m.repository or {}
    return repo[package_name] or {}
end

-- read a rockspec from the moonrocks-mirror cloned directory
-- mirror has flat files named like "package-version-revision.rockspec"
function manifest.read_rockspec(mirror_dir, name, version_str)
    -- version_str is already the full thing like "1.0.0-1"
    local path = mirror_dir .. "/" .. name .. "-" .. version_str .. ".rockspec"
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        return content
    end
    return nil
end

-- download a rockspec from luarocks.org
function manifest.download_rockspec(name, version_str)
    local url = LUAROCKS_BASE .. "/" .. name .. "-" .. version_str .. ".rockspec"
    local body = http_get(url)
    if not body then
        return nil, "failed to download " .. name .. "-" .. version_str .. ".rockspec"
    end
    return body
end

-- get a rockspec, trying mirror first then HTTP
function manifest.get_rockspec(mirror_dir, name, version_str)
    local content = manifest.read_rockspec(mirror_dir, name, version_str)
    if content then return content end
    return manifest.download_rockspec(name, version_str)
end

return manifest
