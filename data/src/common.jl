# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Shared by the data scripts: where the data lives, the Africa box, provenance sidecars, and the
# data pipeline run a script launched by `fair run` takes part in.
# Included by each script; not part of the `AfricaPlants` module, because none of this is needed by a
# run once the data exist.

import AfricaPlants
import DataPipeline
import EcoSISTEM
using Dates
using EcoSISTEM.Provenancer: Provenancer
using TOML

# The citations of the sources EcoSISTEM's catalogue does not cite, by the keys their facts name.
const CITATIONS = joinpath(@__DIR__, "citations.bib")

"""
    pipeline_run(work; todo = nothing)

Call `work(handle)` with the handle of the data pipeline run `fair run` launched this script in, the
citations of [`CITATIONS`](@ref) registered with it, and finalise the run once `work` returns. Started any
other way, call `work(nothing)`, which tracks nothing. Where `todo(handle)` is empty, as
`EcoSISTEM.missingfiles` is with everything registered already, a launched script stops before a
code run exists.

  - `work`: what the script does, given the run's handle or `nothing`.
  - `todo`: what a run has still to do, given its handle, or `nothing` not to ask.
"""
function pipeline_run(work::Function; todo::Union{Nothing, Function} = nothing)
    launched = haskey(ENV, "FDP_CONFIG_DIR")
    if launched && !isnothing(todo)
        done = DataPipeline.rehearse() do handle
            DataPipeline.register_citations!(handle, CITATIONS)
            return isempty(todo(handle))
        end
        done && return nothing
    end
    handle = launched ? DataPipeline.initialise() : nothing
    isnothing(handle) || DataPipeline.register_citations!(handle, CITATIONS)
    result = work(handle)
    isnothing(handle) || DataPipeline.finalise(handle)
    return result
end

"""
    pipeline_register(paths, source; sidecar = Provenancer.sidecarpath)

Register each file at `paths` and EcoSISTEM's record of it with the data pipeline run `fair run`
launched this script in, under the root of `source`, as the record says the file came. Started any
other way, do nothing. A launched script with every file registered already stops before a code run
exists.

  - `paths`: the files, each recorded already by EcoSISTEM's provenance module.
  - `source`: the source's name, a key of `AfricaPlants.SOURCE_ROOTS`.
  - `sidecar`: where a file's record is, given the file's path.
"""
function pipeline_register(paths::AbstractVector{<:AbstractString},
                           source::Symbol;
                           sidecar::Function = Provenancer.sidecarpath)
    function todo(handle)
        track = AfricaPlants.source_track(handle, source)
        return reduce(vcat,
                      (EcoSISTEM.missingfiles(p, track = track,
                                              route = _recordedroute(p,
                                                                     sidecar(p)),
                                              sidecar = sidecar(p))
                       for p in paths),
                      init = @NamedTuple{file::String, reason::String}[])
    end
    pipeline_run(todo = todo) do handle
        isnothing(handle) && return nothing
        track = AfricaPlants.source_track(handle, source)
        for p in paths
            r = Provenancer.recordat(p, sidecar = sidecar(p))
            Provenancer.record_provenance(p, Provenancer.SourceFacts(r),
                                          role = r.role,
                                          route = _recordedroute(p, sidecar(p)),
                                          sidecar = sidecar(p), track = track)
        end
    end
    return nothing
end

# The route the record at `sidecar` says the file at `path` came by.
function _recordedroute(path::AbstractString, sidecar::AbstractString)
    r = Provenancer.recordat(path, sidecar = sidecar)
    return something(r.route, Provenancer.VersionOfRecord())
end

# The record of the table at `path` written afresh, `table` naming it among `AfricaPlants.TABLES`,
# and the table and its record registered as outputs of the data pipeline run `handle` where there
# is one, under the table's root as EcoSISTEM's `Track` names them. A script that has just written
# the table replaces the file an earlier record described.
function record_table(path::AbstractString, table::Symbol; handle = nothing)
    rm(AfricaPlants.table_sidecar(path), force = true)
    record = AfricaPlants.table_record(path, table)
    isnothing(handle) && return record
    root = AfricaPlants.table_root(table)
    stem = first(splitext(basename(path)))
    DataPipeline.link_write!(handle, "$root/data/$stem", path = path)
    DataPipeline.link_write!(handle, "$root/provenance/$stem",
                             path = AfricaPlants.table_sidecar(path))
    return record
end

"""
    datadir()

Return the directory the data scripts read and write, `AFRICA_DATADIR` if set and otherwise
`data/` at the repository root, created if missing.
"""
function datadir()
    dir = abspath(get(ENV, "AFRICA_DATADIR", joinpath(@__DIR__, "..")))
    mkpath(dir)
    return dir
end

"""
    AFRICA_BOX

The geographic box every download is cut to, in degrees: the continent with Madagascar and a
margin of about a degree. `era5_download.jl` hands it to the CDS as north, west, south, east.
"""
const AFRICA_BOX = (north = 40.0, west = -25.0, south = -36.0, east = 56.0)

"""
    forced(argv)

Return whether `--force` was given: rebuild or refetch an output that already exists.
"""
forced(argv) = "--force" in argv

"""
    repopath(path)

Return `path` relative to the repository root when it lies inside it, relative to the data
directory when it lies inside that, and otherwise its basename: a name that means the same on
every machine, for provenance records, which must carry no absolute path.
"""
function repopath(path::AbstractString)
    full = abspath(path)
    root = abspath(joinpath(@__DIR__, "..", ".."))
    startswith(full, root) && return relpath(full, root)
    data = datadir()
    startswith(full, data) && return joinpath("data", relpath(full, data))
    return basename(full)
end

# The script a provenance record is written by, named from the outermost script module enclosing
# the one `common.jl` was included into, so every sidecar says which file produced it without any
# script having to say so: a script that includes another, as `species_widths.jl` includes
# `species_traits.jl`, is the one that ran.
const SCRIPTS = Dict("Inventory" => "inventory.jl",
                     "GBIFDownload" => "gbif_download.jl",
                     "GBIFClean" => "gbif_clean.jl",
                     "Centroids" => "centroids.jl",
                     "Gardens" => "gardens.jl",
                     "EVIDownload" => "evi_download.jl",
                     "EVIMean" => "evi_mean.jl",
                     "SpeciesTraits" => "species_traits.jl",
                     "SpeciesWidths" => "species_widths.jl",
                     "WidthHoldout" => "width_holdout.jl",
                     "EVIReliable" => "evi_reliable.jl")
function _writer()
    script = string(nameof(@__MODULE__))
    m = @__MODULE__
    while parentmodule(m) !== m
        m = parentmodule(m)
        haskey(SCRIPTS, string(nameof(m))) && (script = string(nameof(m)))
    end
    return "data/src/" * get(SCRIPTS, script, script)
end

"""
    write_sidecar(path; source, fields...)

Write `path.provenance.toml` beside `path`: the script that wrote it, the `source` it came
from, when, its size, and any further `fields` (strings, numbers, vectors or dictionaries of
those). Nothing here may name an absolute path or a person: pass paths through
[`repopath`](@ref) and keep credentials and addresses out of `fields`.
"""
function write_sidecar(path::AbstractString; source::AbstractString,
                       fields...)
    record = Dict{String, Any}("writer" => _writer(),
                               "source" => source,
                               "written" => string(now(UTC)))
    isfile(path) && (record["bytes"] = filesize(path))
    for (k, v) in fields
        record[string(k)] = v
    end
    open(path * ".provenance.toml", "w") do io
        return TOML.print(io, record)
    end
    return nothing
end

"""
    provenance_path(path)

Return the path of the provenance sidecar `write_sidecar` writes for `path`.
"""
provenance_path(path::AbstractString) = path * ".provenance.toml"
