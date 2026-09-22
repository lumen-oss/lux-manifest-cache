local cjson = require("cjson")
local version = require("src.version")
local manifest = require("src.manifest")
local resolver = require("src.resolver")

local PACKAGES_DIR = "packages"
local MIRROR_DIR = "mirror"
local FORMAT = 1

-- one cache tree per luarocks manifest (one per supported Lua version)
local MANIFEST_VERSIONS = { "5.1", "5.2", "5.3", "5.4", "5.5" }

local function sha256(s)
    local escaped = s:gsub("'", "'\\''")
    local f = io.popen("printf '%s' '" .. escaped .. "' | sha256sum 2>/dev/null")
    if not f then return nil end
    local result = f:read("*a"):match("^(%x+)")
    f:close()
    return result
end

local function ensure_dir(path)
    os.execute("mkdir -p " .. string.format("%q", path))
end

local function write_json(path, data)
    local f = io.open(path, "w")
    if not f then
        io.stderr:write("ERROR: cannot write " .. path .. "\n")
        return
    end
    f:write(cjson.encode(data))
    f:close()
end

-- build packages/<lua_version>/{<hash>.json,latest/<name>.json,versions/<name>.json}
local function build_for_manifest(lua_version)
    local dir = PACKAGES_DIR .. "/" .. lua_version
    local latest_dir = dir .. "/latest"
    local versions_dir = dir .. "/versions"
    ensure_dir(dir)
    ensure_dir(latest_dir)
    ensure_dir(versions_dir)

    -- manifest downloaded separately by CI, or fall back to direct fetch
    local manifest_file = "manifest-" .. lua_version .. ".json"
    local m, err = manifest.load_json(manifest_file)
    if not m then
        m, err = manifest.fetch_json(manifest_file)
    end
    if not m then
        io.stderr:write(string.format("FATAL: cannot load %s: %s\n", manifest_file, tostring(err)))
        return 0, 0, 0
    end

    local packages = manifest.get_packages(m)
    local total_packages = 0
    local total_written = 0
    local total_errors = 0

    for pkg_name, pkg_versions in pairs(packages) do
        total_packages = total_packages + 1

        local sorted = version.sort_latest(pkg_versions)
        if #sorted == 0 then goto next_package end

        write_json(versions_dir .. "/" .. pkg_name .. ".json", {
            format = FORMAT,
            versions = sorted,
        })

        local latest_vs = sorted[1]
        local pkg_latest_file = nil

        -- process the 2 most recent versions only
        for i = 1, math.min(2, #sorted) do
            local vs_str = sorted[i]
            local hash = sha256(pkg_name .. "@" .. vs_str)
            if not hash then
                io.stderr:write(string.format("ERROR: hash failed for %s@%s\n", pkg_name, vs_str))
                total_errors = total_errors + 1
                goto next_version
            end

            local output_file = dir .. "/" .. hash .. ".json"

            -- skip if already exists
            local f = io.open(output_file, "r")
            if f then
                f:close()
                if vs_str == latest_vs then
                    pkg_latest_file = output_file
                end
                goto next_version
            end

            -- get rockspec content
            local rockspec_str, rs_err = manifest.get_rockspec(MIRROR_DIR, pkg_name, vs_str)
            if not rockspec_str then
                io.stderr:write(string.format("WARN: %s: %s\n", pkg_name .. "@" .. vs_str, tostring(rs_err)))
                total_errors = total_errors + 1
                goto next_version
            end

            -- resolve with transitive deps
            local errors = {}
            local closure = resolver.resolve_recursive(m, MIRROR_DIR, pkg_name, vs_str, errors)

            for ek, em in pairs(errors) do
                io.stderr:write(string.format("WARN: %s -> %s: %s\n", pkg_name .. "@" .. vs_str, ek, em))
            end

            if #closure == 0 then
                io.stderr:write(string.format("WARN: %s: no data after resolution\n", pkg_name .. "@" .. vs_str))
                total_errors = total_errors + 1
                goto next_version
            end

            write_json(output_file, { format = FORMAT, specs = closure })
            total_written = total_written + 1

            if vs_str == latest_vs then
                pkg_latest_file = output_file
            end

            ::next_version::
        end

        if pkg_latest_file then
            local latest_path = latest_dir .. "/" .. pkg_name .. ".json"
            os.execute("cp " .. string.format("%q", pkg_latest_file) .. " " .. string.format("%q", latest_path))
        end

        ::next_package::
    end

    io.write(string.format("[%s] packages: %d | written: %d | errors: %d\n",
        lua_version, total_packages, total_written, total_errors))
    return total_packages, total_written, total_errors
end

local function main()
    ensure_dir(PACKAGES_DIR)

    local total_packages = 0
    local total_written = 0
    local total_errors = 0

    for _, lua_version in ipairs(MANIFEST_VERSIONS) do
        local p, w, e = build_for_manifest(lua_version)
        total_packages = total_packages + p
        total_written = total_written + w
        total_errors = total_errors + e
    end

    io.write(string.format("total | packages: %d | written: %d | errors: %d\n",
        total_packages, total_written, total_errors))
end

main()
