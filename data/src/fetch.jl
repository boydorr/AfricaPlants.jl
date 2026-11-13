# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Fetch the files of the sources EcoSISTEM fetches into its own asset cache: the WFO Plant List
# release species names are standardised through, Natural Earth's outline of Africa, WorldClim's
# annual mean temperature, which positions the grid the seeding records are cut to Africa's outline
# on, and EarthEnv's land cover, which gives the available ground. A file already held is not
# fetched again.
#
#     julia --project data/src/fetch.jl [wfo|naturalearth|worldclim|earthenv]
#
# With no source named, every one is fetched. Launched by `fair run` from `fetch-<source>.yaml`, the
# script fetches the source its config names and registers each file and its record under the
# source's root. Run that way with everything registered already, it stops before a code run
# exists. The registry derives every output of a run from all of its inputs, so each source is
# fetched in a run of its own.

module Fetch

using AfricaPlants
using EcoSISTEM
using RasterDataSources

include("common.jl")

"""
    source_specs(source, handle)

Return the specs whose files the source named `source` gives the runs, each tracked by the data
pipeline run `handle`, or by none where it is `nothing`.
"""
function source_specs(source::Symbol, handle)
    source === :wfo && return [wfo_authority(handle = handle)]
    source === :naturalearth && return [africa_within(handle = handle)]
    source === :worldclim &&
        return [SourceSpec(WorldClim{BioClim}, :bio1,
                           track = source_track(handle, :worldclim))]
    source === :earthenv && return [available_ground(handle = handle)]
    return error("`$source` is not a source this script fetches: name one of wfo, naturalearth, " *
                 "worldclim or earthenv.")
end

function main(argv)
    launched = haskey(ENV, "FDP_CONFIG_DIR")
    sources = Symbol.(argv)
    if isempty(sources)
        launched &&
            error("name the source this run fetches: one of wfo, naturalearth, worldclim or " *
                  "earthenv.")
        sources = [:wfo, :naturalearth, :worldclim, :earthenv]
    end
    launched && length(sources) > 1 &&
        error("a run fetches one source, so name only one.")
    specs(handle) = reduce(vcat, (source_specs(s, handle) for s in sources))
    pipeline_run(todo = handle -> EcoSISTEM.missingfiles(specs(handle))) do handle
        files = EcoSISTEM.fetchfiles(specs(handle))
        println("Fetched or already held: ", length(files), " files")
        return files
    end
    return nothing
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    Fetch.main(ARGS)
end
