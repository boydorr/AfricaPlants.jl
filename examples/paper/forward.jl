# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The forward run: the settled state `burnin.jl` wrote, run from 1941 through the ERA5 months
# in calendar order, recording normalised subcommunity alpha diversity in every cell each 1 January,
# with each species' and each cell's individuals.
# One replicate per seed; `AFRICA_NEUTRAL=true` repeats the 1941-1950 average year throughout
# instead, the neutral control, the climate the burn-in settled under. A replicate is a burn-in, a forward run and a control that share one `AFRICA_SEED`
# and so one settled state, `AFRICA_SPECIES_SEED` holding the species themselves the same throughout;
# the control differs from its forward run only in climate. Another seed repeats the whole
# experiment, its own burn-in included, so that no result rests on a single settled state. Each year both write the whole landscape's diversity to
# `diversity_<forward|neutral>_seed<N>.csv` beside the per-cell diversity they save at the end.
#
#     AFRICA_SCALE=small julia --project=examples/paper examples/paper/forward.jl
#     AFRICA_SEED=2 mpiexecjl --project=examples/paper -n 8 \
#         julia --project=examples/paper examples/paper/forward.jl
#
# | variable          | default        | meaning                                                  |
# |-------------------|----------------|----------------------------------------------------------|
# | `AFRICA_SCALE`    | `large`        | `small` or `medium`: the same species and grid as a burn-in at that scale; `small` runs 1 year |
# | `AFRICA_CELLSIZE` | chosen         | as for the burn-in, which it must match                  |
# | `AFRICA_DISTRIBUTED` | `auto`             | `serial` or `mpi` to demand one                  |
# | `AFRICA_SEED`     | `1`            | the replicate: seeds the run's random streams            |
# | `AFRICA_SPECIES_SEED` | `1`        | seeds the species' own draws, as the burn-in's did       |
# | `AFRICA_NEUTRAL`  | `false`        | `true` to repeat the 1941-1950 average year              |
# | `AFRICA_SAVEDIR`  | `./Africa_run` | where the settled state is read and the diversity written |
# | `AFRICA_START`    | `start_seed<N>_00.jld2` | the settled state in `AFRICA_SAVEDIR` to start from: this seed's own burn-in |
# | `AFRICA_SAVEEND`  | `true`         | `false` to skip saving the state the run ends in, which is as large as the settled state it started from |
# | `AFRICA_ENVELOPES`| the CEH file   | as for the burn-in                                       |

using AfricaPlants
using EcoSISTEM
using EcoSISTEM.Units
using Unitful
using Unitful.DefaultSymbols
using CSV
using DataFrames
using JLD2
using DimensionalData: DimensionalData
using Diversity: Diversity
using MPI

MPI.Initialized() || MPI.Init()
const ISROOT = MPI.Comm_rank(MPI.COMM_WORLD) == 0
const DATA = joinpath(pkgdir(AfricaPlants), "data")
const ENVELOPES = get(ENV, "AFRICA_ENVELOPES",
                      joinpath(DATA, "plant_trait", "data",
                               "global_plant_climate_envelopes.csv"))
# The GBIF download the seeding records are cleaned from, named by its request key; a run's
# provenance carries its record.
const GBIF = let dir = joinpath(DATA, "gbif", "era5")
    joinpath(dir, strip(read(joinpath(dir, "request.key"), String)) * ".csv")
end
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
const NEUTRAL = get(ENV, "AFRICA_NEUTRAL", "false") == "true"
const SAVEDIR = get(ENV, "AFRICA_SAVEDIR", joinpath(pwd(), "Africa_run"))
const START = get(ENV, "AFRICA_START", "start_seed$(SEED)_00.jld2")
const SAVEEND = get(ENV, "AFRICA_SAVEEND", "true") == "true"
const YEARS = smallscale() ? 1 : 2025 - FIRST_FULL_YEAR + 1

say(xs...) = ISROOT && (println(xs...); flush(stdout))

# The same species as the burn-in built, which the settled state names.
envelopes = CSV.read(ENVELOPES, DataFrame,
                     select = [:species, :numrecords, :tmin, :tp, :ssr])
widths = CSV.read(joinpath(DATA, "species_widths.csv"), DataFrame)
pool = scaled_pool(species_pool(envelopes, widths,
                                authority = wfo_authority(handle = HANDLE),
                                provenance = [ENVELOPES_RECORD,
                                    TABLE_RECORDS.species_widths],
                                verbosity = ISROOT ? :normal : :silent).pool)
species = africa_species(pool, seed = SPECIES_SEED,
                         verbosity = ISROOT ? :normal : :silent)
positioning = positioning_layers(handle = HANDLE)
within = africa_within(handle = HANDLE)
chosen = choose_cellsize(length(pool), regime = positioning.regime,
                         supply = positioning.supply, within = within)
area = africa_area(chosen.cellsize, regime = positioning.regime,
                   supply = positioning.supply, within = within,
                   verbosity = ISROOT ? :normal : :silent)

# From the settled state, its clock back at the start and every species going on with its own random
# stream, so that a forward run and its control go on from one state alike. The forward run changes
# the rule of every climate layer; the control keeps the held year's.
timing = NEUTRAL ? HeldClimatology(HELD_DECADE) : ForwardClimate()
eco = africa_ecosystem(species, area, timing, seed = SEED, handle = HANDLE,
                       distributed = DISTRIBUTED,
                       from = joinpath(SAVEDIR, START), elapsed = 0.0s,
                       changing = NEUTRAL ? () : CLIMATE_LAYERS,
                       provenance = [gbif_record(GBIF),
                           TABLE_RECORDS.records_africa,
                           TABLE_RECORDS.evi_reliable])
# The study area holds every raw layer read, tens of gigabytes, and nothing more is built on it.
area = nothing
Base.GC.gc()

# The recorders are called from a callback of our own rather than passed to `simulate!`, so that a
# year is recorded and reported in one place: the recorders keep each cell's normalised alpha
# diversity, the landscape's metacommunity measures and each species' and each cell's individuals,
# which say which species were lost and when, and where the individuals are. Each year's measures
# are added to `diversity_<stage>_seed<N>.csv` as it is recorded, and each decade is reported.
const QS = DIVERSITY_ORDERS
const STAGE = NEUTRAL ? "neutral" : "forward"
totals = RecordTotals(eco, YEARS + 1)
recorder = RecordDiversity(eco, YEARS + 1, qs = QS,
                           subcommunity = [Diversity.NormalisedAlpha],
                           metacommunity = collect(METACOMMUNITY_MEASURES))
started = time()
@time simulate!(eco, YEARS * 1.0year, 1.0month_mean_duration,
                every = EveryYear()) do occurrence
    totals(eco, occurrence)
    recorder(eco, occurrence)
    year = FIRST_FULL_YEAR + occurrence.count - 1
    now = record_diversity(joinpath(SAVEDIR,
                                    "diversity_$(STAGE)_seed$(SEED).csv"),
                           STAGE, occurrence.count - 1, totals, recorder,
                           occurrence.count)
    if occurrence.count == 1 || year % 10 == 0 || occurrence.count == YEARS + 1
        counts = now.counts
        say(year, ": ", round(Int, time() - started), " s elapsed, ",
            counts.total, " individuals, ", counts.alive, " species, largest ",
            round(100 * counts.largest / counts.total, digits = 3), "%")
        say("  gamma: ", join(round.(now.measures.gamma, digits = 1), ", "),
            " at q = ", join(QS, ", "))
    end
    return nothing
end

# The state a run ends in, so that another can carry on from it, as `AFRICA_START` names. It is as
# large as the settled state it started from, about 10 GB for the continent at 50 km, so a machine
# short of room turns it off.
if SAVEEND
    SaveAbundance(SAVEDIR, "$(STAGE)_seed$(SEED)_end")(eco, (count = 1,))
    say("final state written to ",
        joinpath(SAVEDIR, "$(STAGE)_seed$(SEED)_end00.jld2"))
end

if ISROOT
    name = (NEUTRAL ? "neutral" : "forward") * "_seed$(SEED)"
    # The grid's cell centres in metres, so the results can be drawn without rebuilding the area.
    function centres(dim)
        return ustrip.(m,
                       DimensionalData.Lookups.shiftlocus(DimensionalData.Lookups.Center(),
                                                          DimensionalData.lookup(eco.habitat.active,
                                                                                 dim)))
    end
    # Each cell's normalised alpha, cells x orders x years.
    jldsave(joinpath(SAVEDIR, name * ".jld2"),
            diversity = recorder.subcommunity[1, :, :, :], qs = QS,
            years = collect(FIRST_FULL_YEAR:(FIRST_FULL_YEAR + YEARS)),
            species = pool.species.name, species_totals = totals.species,
            cell_totals = totals.cells,
            active = vec(parent(eco.habitat.active)),
            shape = size(parent(eco.habitat.active)),
            y = centres(DimensionalData.Y), x = centres(DimensionalData.X),
            crs = "EPSG:10592")
    write_provenance(joinpath(SAVEDIR, name * ".provenance.toml"),
                     EcoSISTEM.provenance(recorder))
    say("diversity written to ", joinpath(SAVEDIR, name * ".jld2"))
end
