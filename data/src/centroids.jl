# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Fetch the country centroids that `gbif_clean.jl` excludes records near: the points a record's
# coordinates were set to when all that was known of its locality was the country's name.
#
#     julia --project data/src/centroids.jl [--force]
#
# Reads GBIF's Catalogue of Centroids at a pinned commit (centroids gathered from
# CoordinateCleaner, GeoNames, the Getty Thesaurus of Geographic Names, GEOLocate and others)
# and keeps its country-level (`PCLI`) entries. Province centroids and capitals are listed there
# too and are not kept: records near them are mostly at real localities. Writes `centroids.csv`
# with `iso2, name, source, latitude, longitude`. The catalogue states no licence, so the table
# is regenerated rather than committed. EcoSISTEM's record of the table, as a file cut from the
# catalogue, is `centroids.csv.record.toml`. Launched by `fair run` from `fetch-centroids.yaml`, the
# script also registers the table and its record under `centroids`.

module Centroids

using CSV
using DataFrames
using Downloads

include("common.jl")

const COMMIT = "0959e14d0e7a90de28ae2bc23cf570b791e112ef"
const URL = "https://raw.githubusercontent.com/gbif/catalogue-of-centroids/$COMMIT/centroids.tsv"
const TYPES = ["PCLI"]

"""
    FACTS

What is known of the Catalogue of Centroids at the pinned commit, dated by that commit, which a
table cut from it is recorded with.
"""
const FACTS = Provenancer.SourceFacts(source = "GBIF Catalogue of Centroids",
                                      title = "Catalogue of Centroids",
                                      url = "https://github.com/gbif/catalogue-of-centroids/tree/$COMMIT",
                                      releasedate = "2024-02-12",
                                      identifies = :data,
                                      key = "gbif_centroids")

"""
    country_centroids(tsv; types = TYPES)

Return the centroids in the Catalogue of Centroids file `tsv` whose `type` is one of `types`,
as a `DataFrame` with columns `iso2, name, source, latitude, longitude`; rows without
coordinates are dropped. Namibia's ISO code `NA` is kept as a code, not read as missing.
"""
function country_centroids(tsv::AbstractString; types = TYPES)
    raw = CSV.read(tsv, DataFrame, delim = '\t', missingstring = "",
                   types = Dict(:iso2 => String))
    rows = filter(r -> !ismissing(r.type) && r.type in types &&
                       !ismissing(r.decimal_latitude) &&
                       !ismissing(r.decimal_longitude), raw)
    return DataFrame(iso2 = coalesce.(rows.iso2, ""),
                     name = coalesce.(rows.gbif_name, ""),
                     source = coalesce.(rows.source, ""),
                     latitude = Float64.(rows.decimal_latitude),
                     longitude = Float64.(rows.decimal_longitude))
end

# Where EcoSISTEM's record of a table is kept, beside the script's own sidecar.
ecorecord_path(path::AbstractString) = path * ".record.toml"

# EcoSISTEM's record of the table at `out`, as a file cut from the catalogue, registered under
# `centroids` with the data pipeline run `fair run` launched the script in, where it did.
function record(out::AbstractString)
    Provenancer.record_provenance(out, FACTS, role = :abundance,
                                  route = Provenancer.OtherOrigin(),
                                  sidecar = ecorecord_path(out))
    return pipeline_register([out], :centroids, sidecar = ecorecord_path)
end

function main(argv)
    out = joinpath(datadir(), "centroids.csv")
    if isfile(out) && !forced(argv)
        println("Already have ", out,
                "; nothing to do (use --force to rebuild).")
        record(out)
        return nothing
    end
    rm(ecorecord_path(out), force = true)
    tmp = out * ".part"
    println("Fetching ", URL, " ...")
    Downloads.download(URL, tmp)
    table = country_centroids(tmp)
    rm(tmp)
    CSV.write(out, table)
    write_sidecar(out, source = "GBIF Catalogue of Centroids, centroids.tsv",
                  url = URL, commit = COMMIT, types = TYPES,
                  centroids = nrow(table),
                  citation = "GBIF Catalogue of Centroids, https://github.com/gbif/catalogue-of-centroids (no licence stated)")
    record(out)
    println(nrow(table), " centroids -> ", out)
    return nothing
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    Centroids.main(ARGS)
end
