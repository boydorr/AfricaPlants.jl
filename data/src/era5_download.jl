# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Fetch the ERA5 monthly means the Africa runs use from the Climate Data Store: one file per
# variable per decade over the Africa box, through EcoSISTEM's `era5requests` and `fetchfiles`.
# A file already present is not asked for again, and EcoSISTEM writes a provenance record beside
# each file when it fetches it, or when it first finds it without one.
#
#     julia --project data/src/era5_download.jl [--through=2026-08] [--dry-run]
#
# Needs a `~/.cdsapirc` holding the CDS URL and key, which CDSAPI.jl reads. Writes under
# `$AFRICA_DATADIR/era5/` (default `data/era5/`), each file named by its variable, its decade and
# the box (`era5_t2m_1940s_40N25W36S56E.nc`). A decade not yet complete is named by its years
# (`era5_t2m_2020-2025_40N25W36S56E.nc`), so asking again once another year is complete fetches
# that block afresh; delete the old one.
#
# The series runs to the end of the last complete year, or to the month `--through` names, the
# months of its year in a file of their own (`era5_t2m_2026-2026_40N25W36S56E_m01-08.nc`). Only
# final ERA5 is wanted: the CDS serves its latest two or three months as preliminary ERA5T, marked
# by each month's `expver`, and the script refuses a file holding any such month. Name an earlier
# month and delete the file.
#
# Launched by `fair run` from `fetch-era5.yaml`, which names the month, it also registers every file
# and its record under `era5`, once each is fetched and checked.

module ERA5Download

using CDSAPI
using Dates
using EcoSISTEM
using NCDatasets

include("common.jl")

const CODES = ("t2m", "tp", "ssr", "swvl1")
const FIRST_YEAR = 1940
# The `expver` of a final ERA5 month; preliminary ERA5T months carry another.
const FINAL_EXPVER = "0001"

"""
    last_complete_year(today = today())

Return the last year every month of which is available at the CDS: the previous calendar year.
"""
last_complete_year(today::Date = Dates.today()) = Dates.year(today) - 1

"""
    cdsarea()

Return the Africa box as the CDS takes it, `(north, west, south, east)` in whole degrees.
"""
function cdsarea()
    return round.(Int,
                  (AFRICA_BOX.north, AFRICA_BOX.west, AFRICA_BOX.south,
                   AFRICA_BOX.east))
end

"""
    requests(dir; through = Date(last_complete_year(), 12))

Return, for each of `CODES` in order, the vector of `EcoSISTEM.CDSRequest`s that fetch that
variable from `FIRST_YEAR` to the month of `through` into `dir`: one per decade of whole years, and
one more for the months of `through`'s year when it stops before December.
"""
function requests(dir::AbstractString;
                  through::Date = Date(last_complete_year(), 12))
    year, month = Dates.year(through), Dates.month(through)
    whole = FIRST_YEAR:(month == 12 ? year : year - 1)
    return map(CODES) do code
        files = EcoSISTEM.era5requests(code, whole, dir = dir,
                                       area = cdsarea())
        month == 12 ||
            append!(files,
                    EcoSISTEM.era5requests(code, year:year, dir = dir,
                                           months = 1:month,
                                           area = cdsarea()))
        return files
    end
end

"""
    preliminary_months(path)

Return the months of the ERA5 file at `path` that are preliminary ERA5T rather than final ERA5, by
each month's `expver`; none for a file that carries no `expver`.
"""
function preliminary_months(path::AbstractString)
    return NCDataset(path) do ds
        haskey(ds, "expver") || return Date[]
        times = ds[haskey(ds, "valid_time") ? "valid_time" : "time"][:]
        return [Date(t)
                for (t, e) in zip(times, ds["expver"][:]) if e != FINAL_EXPVER]
    end
end

# The month `--through=YYYY-MM` names, or December of the last complete year without one.
function _through(argv)
    i = findfirst(a -> startswith(a, "--through="), argv)
    isnothing(i) && return Date(last_complete_year(), 12)
    return Date(argv[i][(length("--through=") + 1):end], dateformat"yyyy-mm")
end

function main(argv)
    dir = joinpath(datadir(), "era5")
    mkpath(dir)
    wanted = requests(dir, through = _through(argv))
    specs(handle) = [SourceSpec(ERA, code, files = files,
                                track = AfricaPlants.source_track(handle,
                                                                  :era5))
                     for (code, files) in zip(CODES, wanted)]
    if "--dry-run" in argv
        for entry in EcoSISTEM.fetchfiles(specs(nothing), dryrun = true)
            println(entry.present ? "  have   " : "  fetch  ",
                    basename(entry.entry.path))
        end
        return nothing
    end
    # Fetched and checked untracked, so that no preliminary month is ever registered.
    paths = EcoSISTEM.fetchfiles(specs(nothing))
    println(length(paths), " file(s) in ", dir)
    late = [basename(p) * " " * Dates.format(m, "yyyy-mm")
            for p in paths for m in preliminary_months(p)]
    isempty(late) ||
        error("preliminary ERA5T months fetched: ", join(late, ", "),
              ". Name an earlier month with --through and delete these files.")
    pipeline_run(todo = handle -> EcoSISTEM.missingfiles(specs(handle))) do handle
        return isnothing(handle) || EcoSISTEM.fetchfiles(specs(handle))
    end
    return nothing
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    ERA5Download.main(ARGS)
end
