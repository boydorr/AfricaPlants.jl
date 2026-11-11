# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Building and running the Africa ecosystem: the backwards burn-in that seeds it from the occurrence
# records, the years of held climate that settle it, and the forward run that records its
# diversity.

"""
    positioning_layers()

Return the `regime` and `supply` a study area over Africa is positioned and costed with: no regime,
and the ground available to plants as the supply. Land cover has values over the sea as well as the
land, so it removes no coastal cell the outline touches, and the outline alone decides which cells
are simulated.
"""
function positioning_layers()
    return (regime = nothing, supply = available_ground())
end

"""
    africa_ecosystem(species, area, timing = ForwardClimate(); placement = NoAbundance(),
                     from = nothing, elapsed = nothing, changing = (), seed = 1,
                     epoch = Dates.Date(1940, 1, 1), dir = era5_dir(), distributed = :auto,
                     provenance = EcoSISTEM.ProvenanceRecord[])

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
"""
function africa_ecosystem(species, area::StudyArea,
                          timing::AbstractClimateTiming = ForwardClimate();
                          placement = NoAbundance(),
                          from::Union{Nothing, AbstractString} = nothing,
                          elapsed::Union{Nothing, Unitful.Time} = nothing,
                          changing = (), seed::Integer = 1,
                          epoch::Dates.Date = Dates.Date(1940, 1, 1),
                          dir::AbstractString = era5_dir(), distributed = :auto,
                          provenance = EcoSISTEM.ProvenanceRecord[])
    layers = africa_layers(timing, dir = dir)
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

# Each species' demand per individual on the resource named `name`, as a vector.
_demands(eco, name::Symbol) = getproperty(eco.spplist.demand, name).resource

# Each cell's supply of the resource named `name`, as a vector in cell order.
function _supplies(eco, name::Symbol)
    return vec(parent(getproperty(eco.habitat.supply, name).matrix))
end

"""
    burnin_table(eco, records, grid; start, density = 1.0 / m^2, halflife = 20.0year, snap = 3)

Return what a backwards burn-in of `eco` adds, as a named tuple: `table`, the abundance table for an
`AddAbundanceTable`, and the numbers that went into it - the EVI scale `c` and the continental
`scale`, the records `used`, those `outside` the fine grid, those `snapped` to a nearby active cell
and those left in an `inactive` cell, the individuals `started` with and `added` over the burn-in,
and how many records were made `later` than `start`.

Half the individuals are present at elapsed zero and half arrive as the run passes the months their
records were made, across the continent as a whole. The rows at elapsed zero fill each cell to what
its resources hold at the run's first month, the species' shares taken from their records in the
cell, each weighted by its seeding factor and by [`recency_weight`](@ref). Every record is then added
at its own month, by its seeding factor times one continental scale and at least one individual, the
scale chosen so that the records within the run add as many individuals as the start holds. A record
made after `start` counts in the starting shares and is not added.

# Arguments

  - `eco`: the ecosystem, built with [`ReversedClimate`](@ref).
  - `records`: the seeding records of `eco`'s species, as [`seeding_rows`](@ref) takes them.
  - `grid`: the fine seeding grid, from [`read_seeding_grid`](@ref).
  - `start`: the month the backwards run begins at, the last month of the climate, as
    [`era5_last_month`](@ref) gives it.
  - `density`: plants per unit of available ground, as the species were built with.
  - `halflife`: how long before `start` a record's weight in the starting shares halves.
  - `snap`: how many cells a record in an inactive cell may be moved to reach an active one.
"""
function burnin_table(eco, records::DataFrame, grid::NamedTuple;
                      start::NamedTuple,
                      density::Unitful.Quantity = 1.0 / m^2,
                      halflife::Unitful.Time = 20.0year, snap::Integer = 3)
    active = vec(parent(eco.habitat.active))
    space = _supplies(eco, :space)
    landarea = sum(space[active])
    seeded = seeding_rows(records, grid, eco.habitat, landarea,
                          density = density, start = start, snap = snap)
    names = eco.spplist.names
    index = Dict(n => i for (i, n) in enumerate(names))
    shape = size(parent(eco.habitat.active))
    linear = LinearIndices(shape)
    rows = seeded.rows
    cells = [linear[y, x] for (y, x) in zip(rows.y, rows.x)]
    shares = [max(f, 1.0) * recency_weight(t, halflife = halflife)
              for (f, t) in zip(rows.count, rows.time)]
    counts = SparseArrays.sparse([index[s] for s in rows.species], cells,
                                 shares, length(names), prod(shape))
    resources = (:space, :light, :water)
    filled = fill_to_capacity(counts, map(r -> _supplies(eco, r), resources),
                              map(r -> _demands(eco, r), resources))
    started = sum(filled.count, init = 0)
    within = [t >= zero(t) for t in rows.time]
    scaled = scale_to_total(rows.count[within], started)
    added = max.(scaled.scale .* rows.count[within], 1.0)
    positions = CartesianIndices(shape)[filled.cell]
    table = build_abundance_table(eco,
                                  (species = vcat(names[filled.species],
                                                  rows.species[within]),
                                   y = vcat([p[1] for p in positions],
                                            rows.y[within]),
                                   x = vcat([p[2] for p in positions],
                                            rows.x[within]),
                                   time = vcat(zeros(length(filled.cell)) .*
                                               1.0month_mean_duration,
                                               rows.time[within]),
                                   count = vcat(Float64.(filled.count),
                                                added)))
    return (table = table, c = seeded.c, scale = scaled.scale,
            used = seeded.used, outside = seeded.outside,
            snapped = seeded.snapped, inactive = seeded.inactive,
            started = started, added = sum(added, init = 0.0),
            later = count(!, within))
end

"""
    run_burnin!(eco, table, months; provenance = EcoSISTEM.ProvenanceRecord[])

Run `eco`, built with [`ReversedClimate`](@ref), back through `months` months of climate in steps of
one `month_mean_duration`, adding the rows of `table` from [`burnin_table`](@ref) as their times
pass. `provenance` records the data the table was made from.
"""
function run_burnin!(eco, table, months::Integer;
                     provenance = EcoSISTEM.ProvenanceRecord[])
    seeding = Intervention(EveryStep(), ActiveCells(),
                           AddAbundanceTable(table), provenance = provenance)
    simulate!(eco, months * 1.0month_mean_duration, 1.0month_mean_duration,
              intervention = seeding)
    return eco
end

"""
    DIVERSITY_ORDERS

The orders of diversity a run records: 0, the species richness, 1, 2 and infinity.
"""
const DIVERSITY_ORDERS = [0.0, 1.0, 2.0, Inf]

# Diversity.jl's metacommunity measures, by the name each is recorded under. Beta is the raw
# effective number of distinct subcommunities and rho its redundancy; the normalised pair weight
# each subcommunity by its share of the individuals.
const METACOMMUNITY_MEASURES = (raw_alpha = Diversity.raw_meta_alpha,
                                norm_alpha = Diversity.norm_meta_alpha,
                                raw_beta = Diversity.raw_meta_beta,
                                norm_beta = Diversity.norm_meta_beta,
                                raw_rho = Diversity.raw_meta_rho,
                                norm_rho = Diversity.norm_meta_rho,
                                gamma = Diversity.meta_gamma)

"""
    population(eco)

Return what `eco` holds as a named tuple of the `total` individuals, the `alive` species with any
individuals left, and the `largest` species' individuals. Under MPI each rank holds every cell of
its own species, so the counts are summed across the ranks and every rank must call it.
"""
function population(eco)
    perspecies = vec(sum(eco.abundances.matrix, dims = 2))
    return (total = round(Int, sum(perspecies)),
            alive = count(>(0), perspecies),
            largest = maximum(perspecies, init = 0))
end

function population(eco::MPIEcosystem)
    perspecies = vec(sum(eco.abundances.rows_matrix, dims = 2))
    comm = MPI.COMM_WORLD
    return (total = MPI.Allreduce(sum(perspecies), +, comm),
            alive = MPI.Allreduce(count(>(0), perspecies), +, comm),
            largest = MPI.Allreduce(maximum(perspecies, init = 0), max, comm))
end

"""
    abundance_totals(eco)

Return the individuals `eco` holds summed two ways, as a named tuple: `species`, each species' total
over the landscape, and `cells`, each cell's total over the species, in the orders of the species
list and of the grid's cells. They are small enough to keep for every recorded year, where the whole
landscape is not, and say which species a run lost and when, and where its individuals are. Under
MPI each rank holds every cell of its own species, so both are summed across the ranks and every
rank must call it.
"""
function abundance_totals(eco)
    matrix = eco.abundances.matrix
    return (species = vec(sum(matrix, dims = 2)),
            cells = vec(sum(matrix, dims = 1)))
end

function abundance_totals(eco::MPIEcosystem)
    rows = eco.abundances.rows_tuple
    matrix = eco.abundances.rows_matrix
    # Each rank's species go into their places in a landscape-wide vector, so that summing the
    # vectors across the ranks gives every rank the whole of it.
    species = zeros(Int, rows.total)
    species[rows.first:rows.last] = vec(sum(matrix, dims = 2))
    comm = MPI.COMM_WORLD
    return (species = MPI.Allreduce(species, +, comm),
            cells = MPI.Allreduce(vec(sum(matrix, dims = 1)), +, comm))
end

"""
    metacommunity_diversity(eco; qs = DIVERSITY_ORDERS)

Return the diversity of `eco` as a whole at each order in `qs`, as a named tuple of `raw_alpha`,
`norm_alpha`, `raw_beta`, `norm_beta`, `raw_rho`, `norm_rho` and `gamma`, each a vector over `qs`.
Every measure is Diversity.jl's own, over the landscape partitioned into its cells.

Under MPI no rank holds the whole landscape, so the root gathers its `species x cells` abundances,
measures them, and sends the answers back to every rank. Every rank must call this, and a run that
records often is better off in one process.
"""
function metacommunity_diversity(eco;
                                 qs::AbstractVector{<:Real} = DIVERSITY_ORDERS)
    return _measure(eco, qs)
end

# Every measure of one metacommunity, by Diversity.jl.
_measure(meta, qs) = map(m -> m(meta, qs).diversity, METACOMMUNITY_MEASURES)

# An ecosystem is measured as one snapshot, whose normalised abundances every measure shares: asked
# of the ecosystem itself, each measure normalises a copy of its own, as large as the landscape.
function _measure(eco::Ecosystem, qs)
    snapshot = Metacommunity(getabundance(eco), gettypes(eco),
                             getpartition(eco))
    return _measure(snapshot, qs)
end

# A distributed one has to be gathered first, and `gatherabundance` fills the array on the root
# alone, so only the root can measure it; the answers then go back to every rank, which keeps a
# caller that reports or records them the same on all of them. The counts go to Diversity as they
# are, which normalises them into one copy; converted to floats first, they are copied twice and
# warned about every time as not summing to one.
function _measure(eco::MPIEcosystem, qs)
    gathered = EcoSISTEM.gatherabundance(eco)
    measured = MPI.Comm_rank(MPI.COMM_WORLD) == 0 ?
               _measure(Metacommunity(gathered), qs) :
               map(_ -> Float64[], METACOMMUNITY_MEASURES)
    return MPI.bcast(measured, 0, MPI.COMM_WORLD)
end

"""
    record_diversity(path, eco, stage, years; qs = DIVERSITY_ORDERS)

Append what `eco` holds to the table at `path`, one row per measure and order: the `stage` of the
run and how many `years` into it this is, the individuals, living species and largest species of
[`population`](@ref), and every measure of [`metacommunity_diversity`](@ref). Write the header first
if the file is new. Return the population and the measures, so that a caller can report them.

Under MPI every rank must call this, because the measures are gathered; only the root writes.
"""
function record_diversity(path::AbstractString, eco, stage::AbstractString,
                          years::Real;
                          qs::AbstractVector{<:Real} = DIVERSITY_ORDERS)
    counts = population(eco)
    measures = metacommunity_diversity(eco, qs = qs)
    if !MPI.Initialized() || MPI.Comm_rank(MPI.COMM_WORLD) == 0
        isfile(path) ||
            open(io -> println(io,
                               "stage,years,individuals,species,largest,measure,q,diversity"),
                 path, "w")
        open(path, "a") do io
            for (name, values) in pairs(measures), (q, value) in zip(qs,
                                                                     values)
                println(io, stage, ",", years, ",", counts.total, ",",
                        counts.alive, ",", counts.largest, ",", name, ",", q,
                        ",", value)
            end
        end
    end
    return (counts = counts, measures = measures)
end
