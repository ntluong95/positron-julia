# ---------------------------------------------------------------------------------------------
# Copyright (C) 2024-2025 Posit Software, PBC. All rights reserved.
# Licensed under the Elastic License 2.0. See LICENSE.txt for license information.
# ---------------------------------------------------------------------------------------------

import Pkg
import TOML

function _positron_json_string(value::AbstractString)::String
    return "\"" * escape_string(value) * "\""
end

function _positron_print_json_string_array(values::Vector{String})
    print("[")
    for (index, value) in pairs(values)
        index > 1 && print(",")
        print(_positron_json_string(value))
    end
    print("]")
end

function _positron_print_json_field_separator!(first_field::Base.RefValue{Bool})
    if first_field[]
        first_field[] = false
    else
        print(",")
    end
end

function _positron_print_json_string_field!(first_field::Base.RefValue{Bool}, key::String, value::Union{Nothing, String})
    isnothing(value) && return
    _positron_print_json_field_separator!(first_field)
    print(_positron_json_string(key), ":", _positron_json_string(value))
end

function _positron_print_json_bool_field!(first_field::Base.RefValue{Bool}, key::String, value::Union{Nothing, Bool})
    isnothing(value) && return
    _positron_print_json_field_separator!(first_field)
    print(_positron_json_string(key), ":", value ? "true" : "false")
end

function _positron_print_json_string_array_field!(first_field::Base.RefValue{Bool}, key::String, values::Union{Nothing, Vector{String}})
    isnothing(values) && return
    _positron_print_json_field_separator!(first_field)
    print(_positron_json_string(key), ":")
    _positron_print_json_string_array(values)
end

function _positron_print_json_packages(packages::Vector{<:NamedTuple})
    print("[")
    for (index, package) in pairs(packages)
        index > 1 && print(",")
        print("{")
        first_field = Ref(true)

        _positron_print_json_string_field!(first_field, "id", package.id)
        _positron_print_json_string_field!(first_field, "name", package.name)
        _positron_print_json_string_field!(first_field, "displayName", package.displayName)
        _positron_print_json_string_field!(first_field, "version", package.version)
        _positron_print_json_string_field!(first_field, "description", hasproperty(package, :description) ? package.description : nothing)
        _positron_print_json_string_field!(first_field, "license", hasproperty(package, :license) ? package.license : nothing)
        _positron_print_json_string_field!(first_field, "latestVersion", hasproperty(package, :latestVersion) ? package.latestVersion : nothing)
        _positron_print_json_string_field!(first_field, "publishedDate", hasproperty(package, :publishedDate) ? package.publishedDate : nothing)
        _positron_print_json_string_array_field!(first_field, "availableVersions", hasproperty(package, :availableVersions) ? package.availableVersions : nothing)
        _positron_print_json_bool_field!(first_field, "attached", hasproperty(package, :attached) ? package.attached : nothing)

        print("}")
    end
    print("]")
end

function _positron_print_json_metadata(metadata::Dict{String, Dict{String, Any}})
    print("{")
    first_entry = true
    for package_name in sort!(collect(keys(metadata)))
        entry = metadata[package_name]
        first_entry || print(",")
        first_entry = false
        print(_positron_json_string(package_name), ":{")

        first_field = Ref(true)
        _positron_print_json_string_field!(first_field, "description", get(entry, "description", nothing))
        _positron_print_json_string_field!(first_field, "license", get(entry, "license", nothing))
        _positron_print_json_string_field!(first_field, "latestVersion", get(entry, "latestVersion", nothing))
        _positron_print_json_string_field!(first_field, "publishedDate", get(entry, "publishedDate", nothing))
        _positron_print_json_string_array_field!(first_field, "availableVersions", get(entry, "availableVersions", nothing))

        print("}")
    end
    print("}")
end

function _positron_is_package_attached(package_name::String)::Bool
    symbol = Symbol(package_name)
    isdefined(Main, symbol) || return false

    value = try
        getfield(Main, symbol)
    catch
        return false
    end
    return value isa Module && nameof(value) == symbol
end

function _positron_list_packages(direct_only::Bool=true)
    packages = NamedTuple[]
    for package_info in values(Pkg.dependencies())
        if direct_only && !package_info.is_direct_dep
            continue
        end
        name = package_info.name
        version = string(package_info.version)
        push!(packages, (
            id = "$(name)-$(version)",
            name = name,
            displayName = name,
            version = version,
            attached = _positron_is_package_attached(name),
        ))
    end
    sort!(packages, by = package -> lowercase(package.name))
    _positron_print_json_packages(packages)
end

function _positron_install_packages(specs::Vector{String})
    package_specs = Pkg.PackageSpec[]
    for spec in specs
        pieces = split(spec, "@"; limit=2)
        name = strip(pieces[1])
        isempty(name) && continue
        if length(pieces) == 2 && !isempty(strip(pieces[2]))
            push!(package_specs, Pkg.PackageSpec(name=name, version=strip(pieces[2])))
        else
            push!(package_specs, Pkg.PackageSpec(name=name))
        end
    end
    isempty(package_specs) || Pkg.add(package_specs)
    return nothing
end

function _positron_uninstall_packages(names::Vector{String})
    cleaned = filter(name -> !isempty(strip(name)), strip.(names))
    isempty(cleaned) || Pkg.rm(cleaned)
    return nothing
end

function _positron_update_packages(names::Vector{String})
    cleaned = filter(name -> !isempty(strip(name)), strip.(names))
    isempty(cleaned) || Pkg.update(cleaned)
    return nothing
end

function _positron_update_all_packages()
    Pkg.update()
    return nothing
end

function _positron_latest_registry_version(entry)
    info = Pkg.Registry.registry_info(entry)
    isempty(info.version_info) && return "0"
    return string(maximum(keys(info.version_info)))
end

function _positron_search_packages(query::String)
    query = lowercase(strip(query))
    if isempty(query)
        _positron_print_json_packages(NamedTuple[])
        return
    end

    by_name = Dict{String, String}()

    for registry in Pkg.Registry.reachable_registries()
        for entry in values(registry.pkgs)
            package_name = entry.name
            occursin(query, lowercase(package_name)) || continue

            version = try
                _positron_latest_registry_version(entry)
            catch
                "0"
            end

            previous = get(by_name, package_name, nothing)
            if previous === nothing
                by_name[package_name] = version
            elseif previous != version
                try
                    if previous == "0" || VersionNumber(version) > VersionNumber(previous)
                        by_name[package_name] = version
                    end
                catch
                    # Keep the existing version if parsing fails.
                end
            end
        end
    end

    packages = NamedTuple[]
    for (name, version) in by_name
        push!(packages, (
            id = "$(name)-$(version)",
            name = name,
            displayName = name,
            version = version,
            attached = _positron_is_package_attached(name),
        ))
    end
    sort!(packages, by = package -> lowercase(package.name))
    _positron_print_json_packages(packages)
end

function _positron_search_package_versions(name::String)
    target = lowercase(strip(name))
    versions = Set{VersionNumber}()

    if isempty(target)
        _positron_print_json_string_array(String[])
        return
    end

    for registry in Pkg.Registry.reachable_registries()
        for entry in values(registry.pkgs)
            lowercase(entry.name) == target || continue
            info = try
                Pkg.Registry.registry_info(entry)
            catch
                continue
            end
            union!(versions, keys(info.version_info))
        end
    end

    sorted_versions = sort!(collect(versions); rev=true)
    _positron_print_json_string_array(string.(sorted_versions))
end

function _positron_find_registry_entry(name::String)
    target = lowercase(strip(name))
    isempty(target) && return nothing

    for registry in Pkg.Registry.reachable_registries()
        for entry in values(registry.pkgs)
            lowercase(entry.name) == target || continue
            return entry
        end
    end

    return nothing
end

function _positron_installed_package_source(name::String)::Union{Nothing, String}
    target = lowercase(strip(name))
    isempty(target) && return nothing

    for package_info in values(Pkg.dependencies())
        lowercase(package_info.name) == target || continue
        source = package_info.source
        if source isa String && !isempty(source)
            return source
        end
    end

    return nothing
end

function _positron_installed_package_metadata(name::String)::Tuple{Union{Nothing, String}, Union{Nothing, String}}
    source = _positron_installed_package_source(name)
    isnothing(source) && return nothing, nothing

    project_toml_path = joinpath(source, "Project.toml")
    isfile(project_toml_path) || return nothing, nothing

    project_data = try
        TOML.parsefile(project_toml_path)
    catch
        return nothing, nothing
    end

    description = _positron_optional_nonempty_string(get(project_data, "description", nothing))
    license = _positron_optional_nonempty_string(get(project_data, "license", nothing))

    return description, license
end

function _positron_optional_nonempty_string(value)::Union{Nothing, String}
    return value isa String && !isempty(strip(value)) ? value : nothing
end

function _positron_add_if_present!(entry::Dict{String, Any}, key::String, value)
    isnothing(value) || (entry[key] = value)
end

function _positron_registry_metadata(name::String)::Tuple{Union{Nothing, String}, Union{Nothing, Vector{String}}}
    entry = _positron_find_registry_entry(name)
    isnothing(entry) && return nothing, nothing

    info = try
        Pkg.Registry.registry_info(entry)
    catch
        return nothing, nothing
    end

    if isempty(info.version_info)
        return nothing, String[]
    end

    sorted_versions = sort!(collect(keys(info.version_info)); rev=true)
    version_strings = string.(sorted_versions)
    latest_version = isempty(version_strings) ? nothing : first(version_strings)

    return latest_version, version_strings
end

function _positron_get_package_metadata(package_names::Vector{String})
    requested_names = String[]
    seen = Set{String}()
    for name in package_names
        trimmed = strip(name)
        isempty(trimmed) && continue
        lowered = lowercase(trimmed)
        lowered in seen && continue
        push!(requested_names, trimmed)
        push!(seen, lowered)
    end

    metadata = Dict{String, Dict{String, Any}}()
    for package_name in requested_names
        key = lowercase(package_name)
        entry = Dict{String, Any}()

        description, license = _positron_installed_package_metadata(package_name)
        _positron_add_if_present!(entry, "description", description)
        _positron_add_if_present!(entry, "license", license)

        latest_version, available_versions = _positron_registry_metadata(package_name)
        _positron_add_if_present!(entry, "latestVersion", latest_version)
        _positron_add_if_present!(entry, "availableVersions", available_versions)

        metadata[key] = entry
    end

    _positron_print_json_metadata(metadata)
end
