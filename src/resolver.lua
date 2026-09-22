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
-- returns list of { str = <raw dep string>, type = "runtime"|"build"|"test" }
-- dependencies, build_dependencies and test_dependencies are kept distinct
function resolver.get_dep_strings(spec)
    local deps = {}
    local seen = {}

    local function add(dep_list, dep_type)
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
                    table.insert(deps, { str = dep_str, type = dep_type })
                end
            elseif type(v) == "table" then
                add(v, dep_type)
            end
        end
    end

    add(spec.dependencies, "runtime")
    add(spec.build_dependencies, "build")
    add(spec.test_dependencies, "test")

    return deps
end

-- how optional a dependency kind is. "root" is the strongest (always needed),
-- test is the most optional. When combining a parent's requirement with an
-- edge, the more optional of the two wins:
--   runtime -> build  == build  (build-time need of a runtime dep)
--   build   -> runtime == build (runtime dep of a build dep is only built)
--   test    -> runtime == test  (runtime dep of a test-only dep is test-only)
local KIND_RANK = { root = 0, runtime = 1, build = 2, test = 3 }

local function more_optional(a, b)
    if (KIND_RANK[a] or 0) >= (KIND_RANK[b] or 0) then return a end
    return b
end

-- recursively resolve a package and all its dependencies
-- returns array of rockspec tables: [pkg_spec, dep1_spec, dep2_spec, ...]
-- the first entry is the requested package (dependency_type = "root");
-- every other entry carries dependency_type = "runtime"|"build"|"test"
-- reflecting the strongest requirement on it from the root
-- errors maps "name@version" -> error message for unresolvable deps
function resolver.resolve_recursive(m, mirror_dir, name, version_str, errors)
    local specs = {}
    local index = {}
    local kinds = {}

    local queue = { { name = name, version = version_str, kind = "root" } }
    local head = 1

    while head <= #queue do
        local item = queue[head]
        head = head + 1

        local key = item.name .. "@" .. item.version
        -- weaker (or equal) requirement than a path we already took: skip
        if kinds[key] and KIND_RANK[item.kind] >= KIND_RANK[kinds[key]] then
            goto continue
        end
        kinds[key] = item.kind

        local rockspec_str, rs_err = manifest.get_rockspec(mirror_dir, item.name, item.version)
        if not rockspec_str then
            errors[key] = "rockspec not found: " .. tostring(rs_err)
            goto continue
        end

        local spec, eval_err = sandbox.evaluate(rockspec_str)
        if not spec then
            errors[key] = "eval failed: " .. tostring(eval_err)
            goto continue
        end

        spec.available_types = manifest.get_arch_types(m, item.name, item.version)
        spec.rockspec_raw = rockspec_str
        spec.dependency_type = item.kind

        if not index[key] then
            table.insert(specs, spec)
            index[key] = #specs
        end

        for _, entry in ipairs(resolver.get_dep_strings(spec)) do
            local dep = resolver.parse_dep_string(entry.str)
            if not dep then goto next_dep end

            -- lua and luarocks are language/platform deps, not packages in the manifest
            if dep.name == "lua" or dep.name == "luarocks" then goto next_dep end

            local dep_version, dep_err = resolver.resolve_dep(dep, m)
            if not dep_version then
                if errors then
                    errors[dep.name] = tostring(dep_err)
                end
                goto next_dep
            end

            table.insert(queue, {
                name = dep.name,
                version = dep_version,
                kind = more_optional(item.kind, entry.type),
            })

            ::next_dep::
        end

        ::continue::
    end

    return specs
end

return resolver
