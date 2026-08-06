local cjson = require("cjson")
local version = require("src.version")
local manifest = require("src.manifest")
local resolver = require("src.resolver")

local PACKAGES_DIR = "packages"
local LATEST_DIR = PACKAGES_DIR .. "/latest"
local MIRROR_DIR = "mirror"

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

local function main()
    ensure_dir(PACKAGES_DIR)
    ensure_dir(LATEST_DIR)

    -- load manifest.json (downloaded separately by CI, or fall back to direct fetch)
    local m, err = manifest.load_json("manifest.json")
    if not m then
        m, err = manifest.fetch_json()
    end
    if not m then
        io.stderr:write("FATAL: cannot load manifest: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    local packages = manifest.get_packages(m)
    local total_packages = 0
    local total_written = 0
    local total_errors = 0

    for pkg_name, pkg_versions in pairs(packages) do
        total_packages = total_packages + 1

        -- determine latest version for this package
        local latest_vs = version.find_latest(pkg_versions)
        if not latest_vs then
            goto next_package
        end

        local pkg_latest_file = nil

        for vs_str, _ in pairs(pkg_versions) do
            local hash = sha256(pkg_name .. "@" .. vs_str)
            if not hash then
                io.stderr:write(string.format("ERROR: hash failed for %s@%s\n", pkg_name, vs_str))
                total_errors = total_errors + 1
                goto next_version
            end

            local output_file = PACKAGES_DIR .. "/" .. hash .. ".json"

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
            local visited = {}
            local errors = {}
            local closure = resolver.resolve_recursive(m, MIRROR_DIR, pkg_name, vs_str, visited, errors)

            for ek, em in pairs(errors) do
                io.stderr:write(string.format("WARN: %s -> %s: %s\n", pkg_name .. "@" .. vs_str, ek, em))
            end

            if #closure == 0 then
                io.stderr:write(string.format("WARN: %s: no data after resolution\n", pkg_name .. "@" .. vs_str))
                total_errors = total_errors + 1
                goto next_version
            end

            write_json(output_file, closure)
            total_written = total_written + 1

            if vs_str == latest_vs then
                pkg_latest_file = output_file
            end

            ::next_version::
        end

        if pkg_latest_file then
            local latest_path = LATEST_DIR .. "/" .. pkg_name .. ".json"
            os.execute("cp " .. string.format("%q", pkg_latest_file) .. " " .. string.format("%q", latest_path))
        end

        ::next_package::
    end

    io.write(string.format("packages: %d | written: %d | errors: %d\n", total_packages, total_written, total_errors))
end

main()
