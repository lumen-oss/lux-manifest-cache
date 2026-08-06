local version = require("src.version")
local sandbox = require("src.sandbox")
local manifest = require("src.manifest")

local resolver = {}

-- parse a dependency string like "lua >= 5.1, < 5.4" or "lfs ~> 1.2"
-- returns { name = "lua", constraints = { {op=">=", version=parsed}, {op="<", version=parsed} } }
-- optional deps have "?" suffix on the name
function resolver.parse_dep_string(dep_str)
    dep_str = dep_str:match("^%s*(.-)%s*$")
    if dep_str == "" then return nil end

    local name_part, rest = dep_str:match("^([%w%.%-_]+%??)(.*)$")
    if not name_part then return nil end

    local optional = false
    if name_part:sub(-1) == "?" then
        optional = true
        name_part = name_part:sub(1, -2)
    end

    local constraints = {}
    rest = rest:match("^%s*(.*)$") or ""

    if rest == "" then
        constraints[1] = { op = "==", version = version.parse("0") }
    end

    while #rest > 0 do
        local op, ver_str, remaining = rest:match("^%s*([<>=~!]*)%s*([%w%.%_%-]+)[%s,]*(.*)$")
        if not op or op == "" then
            -- bare version = "=="
            local v, rem = rest:match("^%s*([%w%.%_%-]+)[%s,]*(.*)$")
            if v then
                table.insert(constraints, { op = "==", version = version.parse(v) })
                rest = rem
            else
                break
            end
        else
            if op == "=" then op = "==" end
            if op == "!=" then op = "~=" end
            table.insert(constraints, { op = op, version = version.parse(ver_str) })
            rest = remaining or ""
        end
    end

    return {
        name = name_part,
        constraints = constraints,
        optional = optional,
    }
end

-- given a rockspec table and the full manifest, find a matching version for each dependency
function resolver.resolve_dep(dep, m)
    local versions = manifest.get_versions(m, dep.name)
    if next(versions) == nil then
        return nil, "no versions found for " .. dep.name
    end

    local best = version.find_latest(versions, dep.constraints)
    if not best then
        return nil, "no version satisfies constraints for " .. dep.name
    end

    return best
end

-- get dependencies from a rockspec table
-- returns list of raw dependency strings (from dependencies, build_dependencies, test_dependencies)
function resolver.get_dep_strings(spec)
    local deps = {}
    local seen = {}

    local function add(dep_list)
        if type(dep_list) ~= "table" then return end
        for k, v in pairs(dep_list) do
            if type(v) == "string" then
                local dep_str
                if type(k) == "string" and not tonumber(k) then
                    -- dict format: {lua = ">= 5.1"} -> "lua >= 5.1"
                    dep_str = k .. " " .. v
                else
                    dep_str = v
                end
                if not seen[dep_str] then
                    seen[dep_str] = true
                    table.insert(deps, dep_str)
                end
            elseif type(v) == "table" then
                add(v)
            end
        end
    end

    add(spec.dependencies)
    add(spec.build_dependencies)
    add(spec.test_dependencies)

    return deps
end

-- recursively resolve a package and all its dependencies
-- returns array of rockspec tables: [pkg_spec, dep1_spec, dep2_spec, ...]
-- visited maps "name@version" -> true to detect cycles
-- errors maps "name@version" -> error message for unresolvable deps
function resolver.resolve_recursive(m, mirror_dir, name, version_str, visited, errors)
    local key = name .. "@" .. version_str
    if visited[key] then return {} end
    visited[key] = true

    local rockspec_str, err = manifest.get_rockspec(mirror_dir, name, version_str)
    if not rockspec_str then
        errors[key] = "rockspec not found: " .. tostring(err)
        return {}
    end

    local spec, eval_err = sandbox.evaluate(rockspec_str)
    if not spec then
        errors[key] = "eval failed: " .. tostring(eval_err)
        return {}
    end

    local result = { spec }
    local dep_strings = resolver.get_dep_strings(spec)

    for _, ds in ipairs(dep_strings) do
        local dep = resolver.parse_dep_string(ds)
        if not dep then goto continue end

        local dep_version, dep_err = resolver.resolve_dep(dep, m)
        if not dep_version then
            if errors then
                errors[dep.name] = tostring(dep_err)
            end
            goto continue
        end

        local transitive = resolver.resolve_recursive(
            m, mirror_dir, dep.name, dep_version, visited, errors
        )

        for _, tspec in ipairs(transitive) do
            table.insert(result, tspec)
        end

        ::continue::
    end

    return result
end

return resolver
