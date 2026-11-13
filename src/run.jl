# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Building the Africa ecosystem and recording it: the layers a study area is positioned with, the
# ecosystem each stage runs, and the table of each recorded year a stage writes.

"""
    positioning_layers(; handle = nothing)

Return the `regime` and `supply` a study area over Africa is positioned and costed with: no regime,
and the ground available to plants as the supply. Land cover has values over the sea as well as the
land, so it removes no coastal cell the outline touches, and the outline alone decides which cells
are simulated. `handle` is the data pipeline run the land cover is read through, or `nothing`, the
default, for none.
"""
function positioning_layers(; handle = nothing)
    return (regime = nothing, supply = available_ground(handle = handle))
end

"""
    africa_ecosystem(species, area, timing = ForwardClimate(); placement = NoAbundance(),
                     from = nothing, elapsed = nothing, changing = (), seed = 1,
                     epoch = Dates.Date(FIRST_FULL_YEAR, 1, 1), dir = era5_dir(),
                     distributed = :auto,
                     provenance = EcoSISTEM.ProvenanceRecord[], handle = nothing)

Build the ecosystem of `species` on `area` with the climate laid out as `timing` says, stepped by
`MeanMonths()` from `epoch`, serial or across MPI ranks as the process was launched: empty, or
placed by `placement`, or the state a run saved at `from`, carried on.

# Arguments

  - `species`: the species list, from [`africa_species`](@ref).
  - `area`: the study area, from [`africa_area`](@ref).
  - `timing`: an [`AbstractClimateTiming`](@ref).
  - `placement`: where the individuals start, any placement `build_ecosystem` takes; none by
    default.
  - `from`: the path of a state a run saved, such as a `SaveAbundance` file, to start from in place of
    `placement`. On the run's own `seed` every species goes on with the random stream it had there.
  - `elapsed`: the clock a run from `from` starts at, `nothing` for the state's own; `0.0s` starts it
    afresh at `epoch`.
  - `changing`: the names of the layers whose rule a run from `from` changes, such as
    [`CLIMATE_LAYERS`](@ref) when `timing` differs from the saved run's. The run warns of a layer whose
    rule changed but is not named.
  - `seed`: seeds the run's random streams; replicates differ by seed.
  - `epoch`: the date elapsed time zero falls on.
  - `dir`: the directory of the ERA5 monthly files.
  - `distributed`: `:auto` builds a distributed ecosystem when the process is a live multi-rank MPI
    session and a serial one otherwise; `true` and `false` demand one or the other.
  - `provenance`: the records of the data the run as a whole was given, such as the occurrence
    records it was seeded from.
  - `handle`: the data pipeline run the climate and land cover are read through, or `nothing`, the
    default, for none.
"""
function africa_ecosystem(species, area::StudyArea,
                          timing::AbstractClimateTiming = ForwardClimate();
                          placement = NoAbundance(),
                          from::Union{Nothing, AbstractString} = nothing,
                          elapsed::Union{Nothing, Unitful.Time} = nothing,
                          changing = (), seed::Integer = 1,
                          epoch::Dates.Date = Dates.Date(FIRST_FULL_YEAR, 1, 1),
                          dir::AbstractString = era5_dir(), distributed = :auto,
                          provenance = EcoSISTEM.ProvenanceRecord[],
                          handle = nothing)
    layers = africa_layers(timing, dir = dir, handle = handle)
    habitat = GridHabitat(regime = layers.regime, supply = layers.supply,
                          area = area)
    isnothing(from) ||
        return build_ecosystem(species, habitat, from = from, elapsed = elapsed,
                               changing = changing, seed = seed, epoch = epoch,
                               calendar = MeanMonths(),
                               distributed = distributed,
                               provenance = provenance)
    return build_ecosystem(placement, species, habitat, seed = seed,
                           epoch = epoch, calendar = MeanMonths(),
                           distributed = distributed, provenance = provenance)
end

"""
    GBIF_DOWNLOADS

The GBIF occurrence downloads the records come from, by name: `era5`, every georeferenced plant
record in the Africa box from 1940 on, which the runs are seeded from, and `early`, 1806 to 1939.
Each is its DOI, by which it is cited and fetched, and the key GBIF knows it by, which names its
CSV, `<key>.csv`.
"""
const GBIF_DOWNLOADS = (era5 = (doi = "10.15468/dl.n4a2sa",
                                key = "0014627-260903145123482"),
                        early = (doi = "10.15468/dl.4guss6",
                                 key = "0014628-260903145123482"))

"""
    gbif_record(path)

Return the [`ProvenanceRecord`](@ref) of the GBIF occurrence download at `path`, which the seeding
records are cleaned from, for a run's provenance: the record `data/src/gbif_download.jl` writes
beside it. Only that record is read, so the download itself need not be present.
"""
function gbif_record(path::AbstractString)
    record = EcoSISTEM.provenance(path)
    isnothing(record) &&
        error("`$path` has no provenance record beside it that EcoSISTEM can read: " *
              "`data/src/gbif_download.jl` writes it")
    return record
end

"""
    DIVERSITY_ORDERS

The orders of diversity a run records: 0, the species richness, 1, 2 and infinity.
"""
const DIVERSITY_ORDERS = [0.0, 1.0, 2.0, Inf]

"""
    METACOMMUNITY_MEASURES

The metacommunity measures a run records, Diversity.jl's measure types by the name each is recorded
under. Beta is the raw effective number of distinct subcommunities and rho its redundancy; the
normalised pair weight each subcommunity by its share of the individuals.
"""
const METACOMMUNITY_MEASURES = (raw_alpha = Diversity.RawAlpha,
                                norm_alpha = Diversity.NormalisedAlpha,
                                raw_beta = Diversity.RawBeta,
                                norm_beta = Diversity.NormalisedBeta,
                                raw_rho = Diversity.RawRho,
                                norm_rho = Diversity.NormalisedRho,
                                gamma = Diversity.Gamma)

"""
    record_diversity(path, stage, years, totals, diversity, k)

Append occurrence `k` of a stage's two recorders to the table at `path`, one row per metacommunity
measure and order: the `stage` of the run and how many `years` into it this is, the individuals,
living species and largest species from `totals`, and each measure from `diversity`. Write the header
first if the file is new, and write each year as it is recorded, so that a run stopped part way keeps
the years it reached. Return the counts and the measures by name, so that a caller can report them.

Under MPI every rank holds both recorders' values, and only the root writes.

  - `path`: the stage's table.
  - `stage`: the stage's name, written on every row.
  - `years`: how many years into the stage this occurrence is.
  - `totals`: the stage's `RecordTotals`.
  - `diversity`: the stage's `RecordDiversity`, recording the [`METACOMMUNITY_MEASURES`](@ref) in
    that order.
  - `k`: the occurrence, as `simulate!` counts it.
"""
function record_diversity(path::AbstractString, stage::AbstractString,
                          years::Real, totals::RecordTotals,
                          diversity::RecordDiversity, k::Integer)
    diversity.measures.metacommunity == collect(METACOMMUNITY_MEASURES) ||
        error("the diversity recorder must record the metacommunity measures " *
              "$(collect(METACOMMUNITY_MEASURES)), in that order")
    perspecies = view(totals.species, :, k)
    counts = (total = sum(perspecies), alive = count(>(0), perspecies),
              largest = maximum(perspecies, init = 0))
    values = [diversity.metacommunity[i, :, k]
              for i in axes(diversity.metacommunity, 1)]
    measures = NamedTuple{keys(METACOMMUNITY_MEASURES)}(Tuple(values))
    if !MPI.Initialized() || MPI.Comm_rank(MPI.COMM_WORLD) == 0
        isfile(path) ||
            open(io -> println(io,
                               "stage,years,individuals,species,largest,measure,q,diversity"),
                 path, "w")
        open(path, "a") do io
            for (name, values) in pairs(measures),
                (q, value) in zip(diversity.qs, values)
                println(io, stage, ",", years, ",", counts.total, ",",
                        counts.alive, ",", counts.largest, ",", name, ",", q,
                        ",", value)
            end
        end
    end
    return (counts = counts, measures = measures)
end
