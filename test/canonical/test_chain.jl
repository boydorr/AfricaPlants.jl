# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The blessing test on the real data: the small-scale chain of one replicate - the backwards burn-in
# and its held year, then the forward run and its control, seed 1 - run by the paper's stage scripts
# in `examples/paper/`, in that directory's environment, on the ERA5 months, records, widths, seeding
# grid and envelopes on this machine. It blesses what the chain was built from, as the SHA-256 of
# each input, and what it produced: each stage's yearly individuals, species, largest species and
# diversity, and each run's species totals at the end.
# Skipped where the data is not here, as on CI. Run with `Pkg.test(test_args = ["canonical"])`; see
# README.md in this directory.

using CSV
using DataFrames
using JLD2
using SHA

const CHAIN_DATA = joinpath(pkgdir(AfricaPlants), "data")
const CHAIN_ENVELOPES = get(ENV, "AFRICA_ENVELOPES",
                            joinpath(CHAIN_DATA, "plant_trait", "data",
                                     "global_plant_climate_envelopes.csv"))
# The tables the drivers read beside the ERA5 months, by the name each is blessed under.
const CHAIN_TABLES = [
    "records_africa.csv" => joinpath(CHAIN_DATA, "records_africa.csv"),
    "species_widths.csv" => joinpath(CHAIN_DATA, "species_widths.csv"),
    "seeding_grid.nc" => joinpath(CHAIN_DATA, "seeding_grid.nc"),
    "evi_mean_2001_2025.nc" =>
        joinpath(CHAIN_DATA, "evi", "evi_mean_2001_2025.nc"),
    "global_plant_climate_envelopes.csv" => CHAIN_ENVELOPES]

# The SHA-256 of a file, in hexadecimal.
filedigest(path) = open(io -> bytes2hex(sha256(io)), path)

# One digest over every ERA5 file, from each file's own in name order, so that it names the months'
# contents and not the files' names.
function era5digest(dir)
    files = sort(filter(f -> endswith(f, ".nc"), readdir(dir)))
    return bytes2hex(sha256(join(filedigest(joinpath(dir, f)) for f in files)))
end

const PAPER = joinpath(pkgdir(AfricaPlants), "examples", "paper")

# Julia in the paper's environment on this process's threads, as a job starts it. A child would
# inherit the load path `Pkg.test` sets, putting this test's environment in place of the paper's.
function paperjulia(args)
    return `$(Base.julia_cmd()) --threads=$(Threads.nthreads()) --project=$PAPER $args`
end
const OWN_LOAD_PATH = ("JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)

# A stage in a process of its own, as a job runs it, with the settings it reads from the environment
# set around it.
function runstage(script, savedir; neutral = false)
    withenv(OWN_LOAD_PATH..., "AFRICA_SCALE" => "small", "AFRICA_SEED" => "1",
            "AFRICA_SPECIES_SEED" => "1", "AFRICA_SAVEDIR" => savedir,
            "AFRICA_SAVEEND" => "false", "AFRICA_DISTRIBUTED" => "serial",
            "AFRICA_NEUTRAL" => string(neutral), "AFRICA_CELLSIZE" => nothing,
            "AFRICA_START" => nothing, "AFRICA_HELD" => nothing) do
        return run(paperjulia(joinpath(PAPER, script)))
    end
end

@testset "Canonical: the small chain on the real data" begin
    era5 = era5_dir()
    present = all(isfile ∘ last, CHAIN_TABLES) && isdir(era5) &&
              any(endswith(".nc"), readdir(era5))
    if !present
        @test_skip "the ERA5 months, tables and envelopes are not on this machine"
    else
        for (name, path) in CHAIN_TABLES
            canonical("chain/input/$name", filedigest(path))
        end
        canonical("chain/input/era5", era5digest(era5))

        withenv(OWN_LOAD_PATH...) do
            return run(paperjulia(`-e "using Pkg; Pkg.instantiate()"`))
        end
        dir = mktempdir()
        runstage("burnin.jl", dir)
        runstage("forward.jl", dir)
        runstage("forward.jl", dir, neutral = true)

        # Each stage's yearly record: a row per year, measure and order, the landscape's totals
        # repeated on every row of a year.
        yearly = Dict{String, DataFrame}()
        for stage in ("burnin", "hold", "forward", "neutral")
            file = joinpath(dir, "diversity_$(stage)_seed1.csv")
            @test isfile(file)
            table = CSV.read(file, DataFrame)
            years = table[.!nonunique(table, :years), :]
            @test all(>(0), years.individuals) && all(>(0), years.species)
            @test all(isfinite, table.diversity)
            canonical("chain/$stage/individuals", years.individuals)
            canonical("chain/$stage/species", years.species)
            canonical("chain/$stage/largest", years.largest)
            canonical("chain/$stage/diversity", table.diversity)
            yearly[stage] = years
        end
        # The forward run and its control start from the one settled state.
        @test first(yearly["forward"].individuals) ==
              first(yearly["neutral"].individuals)
        @test first(yearly["forward"].species) ==
              first(yearly["neutral"].species)

        for stage in ("forward", "neutral")
            run = load(joinpath(dir, "$(stage)_seed1.jld2"))
            species, cells = run["species_totals"], run["cell_totals"]
            @test size(species, 1) == length(run["species"])
            @test vec(sum(species, dims = 1)) == vec(sum(cells, dims = 1))
            canonical("chain/$stage/species_end", species[:, end])
            canonical("chain/$stage/surviving_end",
                      count(>(0), species[:, end]))
            canonical("chain/$stage/occupied_end", count(>(0), cells[:, end]))
            if stage == "forward"
                canonical("chain/pool/species", length(run["species"]))
                canonical("chain/grid/shape", collect(run["shape"]))
                canonical("chain/grid/active", count(run["active"]))
            end
        end
    end
end
