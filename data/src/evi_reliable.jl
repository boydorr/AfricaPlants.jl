# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The mean EVI the seeding weighs records by, over the Africa box at its own 0.05 degree resolution:
# each cell's mean of good and marginal months, missing where fewer than
# `AfricaPlants.MIN_EVI_MONTHS` months went into it. Written as a GeoTIFF, which EcoSISTEM reads as a
# layer; the run multiplies it by each cell's land area there.
#
#     julia --project data/src/evi_reliable.jl [--force]
#
# Reads `evi/evi_mean_2001_2025.nc`; writes `evi/evi_reliable_2001_2025.tif`.

module EVIReliable

using AfricaPlants
using EcoSISTEM
using NCDatasets

include("common.jl")

const CELL = 0.05
const ArchGDAL = EcoSISTEM.ArchGDAL

"""
    box_indices(box; cell = CELL, west = -180.0, north = 90.0)

Return the column and row ranges of a global north-up grid of `cell` degrees, whose first cell's
corner is at `west` and `north`, covering the geographic `box` (with `north`, `west`, `south` and
`east` edges).
"""
function box_indices(box::NamedTuple; cell::Real = CELL, west::Real = -180.0,
                     north::Real = 90.0)
    columns = (round(Int, (box.west - west) / cell) + 1):round(Int,
                                                               (box.east - west) / cell)
    rows = (round(Int, (north - box.north) / cell) + 1):round(Int,
                                                              (north - box.south) / cell)
    return (columns = columns, rows = rows)
end

"""
    reliable_evi(evi, months; minimum = AfricaPlants.MIN_EVI_MONTHS)

Return `evi` with every cell that `months` says rests on fewer than `minimum` months set to `NaN`,
as does a cell with no value.
"""
function reliable_evi(evi::AbstractMatrix, months::AbstractMatrix{<:Integer};
                      minimum::Integer = AfricaPlants.MIN_EVI_MONTHS)
    out = Float32.(coalesce.(evi, NaN32))
    out[months .< minimum] .= NaN32
    return out
end

# Write `values`, indexed `[column, row]` from the north-west corner of `box`, as a GeoTIFF of
# `cell`-degree cells in WGS 84, `NaN` marking no value.
function write_geotiff(path::AbstractString, values::AbstractMatrix{Float32},
                       box::NamedTuple; cell::Real = CELL)
    ArchGDAL.create(path, driver = ArchGDAL.getdriver("GTiff"),
                    width = size(values, 1), height = size(values, 2),
                    nbands = 1, dtype = Float32,
                    options = ["COMPRESS=DEFLATE"]) do ds
        ArchGDAL.setgeotransform!(ds,
                                  [box.west, cell, 0.0, box.north, 0.0, -cell])
        ArchGDAL.setproj!(ds, ArchGDAL.toWKT(ArchGDAL.importEPSG(4326)))
        band = ArchGDAL.getband(ds, 1)
        ArchGDAL.setnodatavalue!(band, NaN)
        return ArchGDAL.write!(band, values)
    end
    return path
end

function main(argv)
    out = joinpath(datadir(), "evi", "evi_reliable_2001_2025.tif")
    if isfile(out) && !forced(argv)
        println("Already have ", out,
                "; nothing to do (use --force to rebuild).")
        return nothing
    end
    idx = box_indices(AFRICA_BOX)
    evi = NCDataset(joinpath(datadir(), "evi", "evi_mean_2001_2025.nc")) do ds
        return reliable_evi(ds["evi"][idx.columns, idx.rows],
                            ds["months"][idx.columns, idx.rows])
    end
    write_geotiff(out, evi, AFRICA_BOX)
    write_sidecar(out, source = "evi/evi_mean_2001_2025.nc",
                  min_evi_months = AfricaPlants.MIN_EVI_MONTHS,
                  box = Dict(string(k) => v for (k, v) in pairs(AFRICA_BOX)),
                  cells = length(evi), cells_with_evi = count(!isnan, evi))
    println(count(!isnan, evi), " of ", length(evi), " cells with EVI -> ", out)
    return nothing
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    EVIReliable.main(ARGS)
end
