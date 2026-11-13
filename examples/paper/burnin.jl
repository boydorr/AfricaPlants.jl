# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The backwards burn-in: every Africa species with an envelope and widths, filled from the occurrence
# records to what each cell's resources hold at the last month of the climate, run back through the
# ERA5 months to the first while each record is added at the month it was made, then settled for
# some years under the 1941-1950 average year repeated. Writes the settled state for `forward.jl`.
#
# Every replicate runs its own burn-in, so that nothing in the results rests on one realisation of
# it: with `AFRICA_SEED=2` this writes `burnin_seed2_00.jld2` and `start_seed2_00.jld2` beside seed
# 1's, and `examples/paper/forward.jl` with the same seed starts from them. The species themselves
# are the same in every replicate (`AFRICA_SPECIES_SEED`), so what varies is the simulation's
# randomness and not the pool it simulates.
#
#     AFRICA_SCALE=small julia --project=examples/paper examples/paper/burnin.jl
#     julia -t 8 --project=examples/paper examples/paper/burnin.jl
#     mpiexecjl --project=examples/paper -n 8 \
#         julia --project=examples/paper examples/paper/burnin.jl
#
# | variable          | default               | meaning                                          |
# |-------------------|-----------------------|--------------------------------------------------|
# | `AFRICA_SCALE`    | `large`               | `small`: 200 species, the coarsest grid, 6 months back and 1 year held; `medium`: 3,000 species across every level of recording, the coarsest grid, the full span |
# | `AFRICA_CELLSIZE` | chosen                | `50km` to override the memory-based choice       |
# | `AFRICA_DISTRIBUTED` | `auto`             | `serial` or `mpi` to demand one                  |
# | `AFRICA_SEED`     | `1`                   | the replicate: seeds this burn-in's random streams and names what it writes |
# | `AFRICA_SPECIES_SEED` | `1`               | seeds the species' own draws, the same in every replicate so that they simulate one pool |
# | `AFRICA_HELD`     | `10`                  | years the 1941-1950 average year is repeated     |
# | `AFRICA_SAVEDIR`  | `./Africa_run`        | where the settled state is written, made if need be |
# | `AFRICA_ENVELOPES`| the CEH envelope file | `global_plant_climate_envelopes.csv`, in `data/plant_trait/data/` |

using AfricaPlants
using EcoSISTEM
using EcoSISTEM.Units
using Unitful
using Unitful.DefaultSymbols
using CSV
using DataFrames
using JLD2
using MPI

MPI.Initialized() || MPI.Init()
const ISROOT = MPI.Comm_rank(MPI.COMM_WORLD) == 0
const DATA = joinpath(pkgdir(AfricaPlants), "data")
const ENVELOPES = get(ENV, "AFRICA_ENVELOPES",
                      joinpath(DATA, "plant_trait", "data",
                               "global_plant_climate_envelopes.csv"))
# The GBIF download the seeding records are cleaned from; a run's provenance carries its record.
const GBIF = joinpath(DATA, "gbif", "era5", GBIF_DOWNLOADS.era5.key * ".csv")
const SEED = parse(Int, get(ENV, "AFRICA_SEED", "1"))
# The data pipeline run the stage is part of, which `pipeline.jl` defines in the stage's module
# before including it, or `nothing` for a plain run. Every input is read through it: each file the
# stage reads is put in place from the run's store before it is read.
const HANDLE = isdefined(@__MODULE__, :PIPELINE) ? PIPELINE : nothing
const ENVELOPES_RECORD = envelopes_record(ENVELOPES, handle = HANDLE)
# The tables of ours the stage's species and seeding were made from, and their records, for its
# provenance: the seeding records, the niche widths and the reliable EVI.
const TABLE_FILES = (records_africa = "records_africa.csv",
                     species_widths = "species_widths.csv",
                     evi_reliable = joinpath("evi",
                                             "evi_reliable_2001_2025.tif"))
const TABLE_NAMES = NamedTuple{keys(TABLE_FILES)}(keys(TABLE_FILES))
const TABLE_RECORDS = map(TABLE_FILES, TABLE_NAMES) do file, table
    return table_record(joinpath(DATA, file), table, handle = HANDLE)
end
# The species are the same in every replicate, so that every replicate can start from one settled
# state: their own draws take this seed and the run's random streams take `SEED`.
const SPECIES_SEED = parse(Int, get(ENV, "AFRICA_SPECIES_SEED", "1"))
# `auto` builds a distributed ecosystem under a live multi-rank MPI session and a serial one
# otherwise; `mpi` and `serial` demand one or the other.
const DISTRIBUTED = let want = get(ENV, "AFRICA_DISTRIBUTED", "auto")
    want == "auto" ? :auto :
    want == "mpi" ? true :
    want == "serial" ? false :
    error("AFRICA_DISTRIBUTED=$want is not one of auto, mpi, serial")
end
const SAVEDIR = mkpath(get(ENV, "AFRICA_SAVEDIR",
                           joinpath(pwd(), "Africa_run")))
# The backwards run starts at the last month of the climate and runs back to January of the first
# year whose every month has twelve months of climate behind it.
const START = era5_last_month()
const MONTHS = smallscale() ? 6 :
               12 * (START.year - FIRST_FULL_YEAR) + START.month
const HELD = smallscale() ? 1 : parse(Int, get(ENV, "AFRICA_HELD", "10"))

# Where each stage's yearly record of the whole landscape goes: individuals, species and every
# metacommunity measure at each order, one file per stage so a rerun of one does not disturb another.
record(stage) = joinpath(SAVEDIR, "diversity_$(stage)_seed$(SEED).csv")

say(xs...) = ISROOT && (println(xs...); flush(stdout))

# Write how many species are placed in each cell of the grid over the whole burn-in, from the rows
# its records place, as `recorded.jl` reads them: a row for each cell in the grid's order.
function write_recorded(rows, habitat)
    shape = size(parent(habitat.active))
    linear = LinearIndices(shape)
    seen = [Set{String}() for _ in 1:prod(shape)]
    for (cell, species) in zip(rows.cell, rows.species)
        push!(seen[cell isa CartesianIndex ? linear[cell] : cell], species)
    end
    CSV.write(joinpath(SAVEDIR, "recorded_richness.csv"),
              DataFrame(cell = eachindex(seen), recorded = length.(seen)))
    return nothing
end

# One progress line from a record: where the run has got to, what it holds, and its gamma diversity.
function report(where, recorded, elapsed)
    counts = recorded.counts
    say(where, ", ", round(Int, elapsed), " s elapsed, ", counts.total,
        " individuals, ", counts.alive, " species, largest ",
        round(100 * counts.largest / counts.total, digits = 3), "%")
    return say("  gamma: ",
               join(round.(recorded.measures.gamma, digits = 1), ", "),
               " at q = ", join(DIVERSITY_ORDERS, ", "))
end

# The species, under WFO's accepted names. A small run keeps the most-recorded species.
envelopes = CSV.read(ENVELOPES, DataFrame,
                     select = [:species, :numrecords, :tmin, :tp, :ssr])
widths = CSV.read(joinpath(DATA, "species_widths.csv"), DataFrame)
built = species_pool(envelopes, widths,
                     authority = wfo_authority(handle = HANDLE),
                     provenance = [ENVELOPES_RECORD,
                         TABLE_RECORDS.species_widths],
                     verbosity = ISROOT ? :normal : :silent)
pool = scaled_pool(built.pool)
# Every plant record, named by the WFO species its name means, with how long before the start it was
# made. Every record counts as collecting effort; those of a simulated species are placed.
records = CSV.read(joinpath(DATA, "records_africa.csv"), DataFrame,
                   select = [:wfo_species, :decimalLatitude, :decimalLongitude,
                       :year, :month])
rename!(records, :wfo_species => :species)
records.elapsed = months_back(records.year, records.month, start = START) .*
                  1.0month_mean_duration
simulated = Set(pool.species.name)
say(length(pool), " species (", length(built.unmatched),
    " recorded species with no envelope left out, ", length(built.nowidth),
    " on their relatives' width alone); ",
    count(s -> !ismissing(s) && s in simulated, records.species), " of ",
    nrow(records), " records are theirs")

species = africa_species(pool, seed = SPECIES_SEED,
                         verbosity = ISROOT ? :normal : :silent)
positioning = positioning_layers(handle = HANDLE)
within = africa_within(handle = HANDLE)
chosen = choose_cellsize(length(pool), regime = positioning.regime,
                         supply = positioning.supply, within = within)
chosen.fits ||
    error("$(length(pool)) species at $(chosen.cellsize) do not fit in the memory available")
area = africa_area(chosen.cellsize, regime = positioning.regime,
                   supply = positioning.supply, within = within,
                   verbosity = ISROOT ? :normal : :silent)
say("grid ", chosen.cellsize)

# A record weighs its 0.05 degree cell's EVI times land area, shared among every record made in that
# cell, and nothing where the EVI is not reliable. A record in a cell that is not simulated moves to
# the nearest one within three cells.
effort = WeightPerCell(seeding_layer(joinpath(DATA, "evi",
                                              "evi_reliable_2001_2025.tif"),
                                     handle = HANDLE),
                       novalue = 0.0km^2)
snap = 3 * chosen.cellsize

# Backwards through the climate. Half the individuals fill each cell to what its resources hold at
# the start, the species sharing it by their records' weights.
# The seeding's own inputs: the download the records are cleaned from, the records, and the EVI.
seeded_from = [gbif_record(GBIF), TABLE_RECORDS.records_africa,
    TABLE_RECORDS.evi_reliable]
weighted = FromOccurrences(records, weight = effort, snap = snap,
                           level = EcoSISTEM.ProblemNotice(),
                           provenance = seeded_from)
eco = africa_ecosystem(species, area, ReversedClimate(), seed = SEED,
                       distributed = DISTRIBUTED, handle = HANDLE,
                       placement = ToCapacity(weighted))
atstart = RecordTotals(eco, 1)
atstart(eco, (count = 1,))
startcount = sum(atstart.species)
# The other half arrive as the run passes each record's month: each record at least one individual,
# the rest in proportion to its weight. A record made after the start shapes the start alone. The
# species placed in each cell are written for `recorded.jl`, as `recorded_richness.csv`.
additions = FromOccurrences(records, time = :elapsed, weight = effort,
                            snap = snap,
                            level = EcoSISTEM.ProblemNotice(),
                            provenance = seeded_from
                            ) do rows, habitat, context
    ISROOT && write_recorded(rows, habitat)
    within = rows[rows.time .>= zero(eltype(rows.time)), :]
    scaled = scale_to_total(ustrip.(km^2, within.weight), startcount)
    say("seeding: ", startcount, " individuals to start; ", nrow(within),
        " records add ", round(Int, sum(scaled.counts)), " over the burn-in; ",
        nrow(rows) - nrow(within), " made after ", START.year, "-",
        lpad(START.month, 2, '0'), " shape the start alone")
    return (species = within.species, cell = within.cell, time = within.time,
            count = round.(Int, scaled.counts))
end
seeding = Intervention(EveryStep(), ActiveCells(), AddAbundance(additions),
                       provenance = seeded_from)
# A stage's recorders for the start and `years` recorded years: each species' and each cell's
# individuals, which say which species a stage lost and when, and where the individuals are, and the
# landscape's metacommunity measures.
function recorders(eco, years::Integer)
    return (totals = RecordTotals(eco, years + 1),
            diversity = RecordDiversity(eco, years + 1, qs = DIVERSITY_ORDERS,
                                        metacommunity = collect(METACOMMUNITY_MEASURES)))
end
# Record an occurrence of `stage` and append its year to the stage's table.
function keep!(kept, eco, stage::AbstractString, years::Integer, occurrence)
    kept.totals(eco, occurrence)
    kept.diversity(eco, occurrence)
    return record_diversity(record(stage), stage, years, kept.totals,
                            kept.diversity, occurrence.count)
end
function save_totals(stage::AbstractString, kept)
    ISROOT &&
        jldsave(joinpath(SAVEDIR, "totals_$(stage)_seed$(SEED).jld2"),
                species = pool.species.name,
                species_totals = kept.totals.species,
                cell_totals = kept.totals.cells,
                years = collect(0:(size(kept.totals.species, 2) - 1)))
    return nothing
end

backwards = recorders(eco, MONTHS ÷ 12)
started = time()
@time simulate!(eco, MONTHS * 1.0month_mean_duration, 1.0month_mean_duration,
                every = EveryInterval(12 * 1.0month_mean_duration),
                intervention = seeding) do occurrence
    back = occurrence.count - 1
    now = keep!(backwards, eco, "burnin", back, occurrence)
    back % 10 == 0 &&
        report("burn-in: $(back) years back", now, time() - started)
    return nothing
end
SaveAbundance(SAVEDIR, "burnin_seed$(SEED)_")(eco, (count = 1,))
save_totals("burnin", backwards)

# The average year of the first decade repeated, from the state the backwards run reached and saved.
# Its clock goes back to the start, and every species goes on with its own random stream. It is built
# on the same study area, whose raw layer reads this build reuses. Every climate layer changes its
# rule here. The backwards run's ecosystem is dropped before the build, and the area, tens of
# gigabytes, after it.
eco = nothing
Base.GC.gc()
held = africa_ecosystem(species, area, HeldClimatology(HELD_DECADE),
                        seed = SEED,
                        distributed = DISTRIBUTED, handle = HANDLE,
                        from = joinpath(SAVEDIR, "burnin_seed$(SEED)_00.jld2"),
                        elapsed = 0.0s, changing = CLIMATE_LAYERS,
                        provenance = seeded_from)
area = nothing
Base.GC.gc()
settling = recorders(held, HELD)
started = time()
@time simulate!(held, HELD * 1.0year, 1.0month_mean_duration,
                every = EveryInterval(12 * 1.0month_mean_duration)
                ) do occurrence
    year = occurrence.count - 1
    now = keep!(settling, held, "hold", year, occurrence)
    report("held climate: year $(year) of $(HELD)", now, time() - started)
    return nothing
end
SaveAbundance(SAVEDIR, "start_seed$(SEED)_")(held, (count = 1,))
save_totals("hold", settling)
say("settled state written to ",
    joinpath(SAVEDIR, "start_seed$(SEED)_00.jld2"))
