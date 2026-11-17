# SPDX-License-Identifier: LGPL-3.0-or-later
#
# A stage of the paper's run as a data pipeline run, the files it writes registered as the run's
# outputs. From the root of the repository:
#
#     fair pull --local examples/paper/burnin.yaml && fair run examples/paper/burnin.yaml
#     fair pull --local examples/paper/forward.yaml && fair run examples/paper/forward.yaml
#     fair pull --local examples/paper/figures.yaml && fair run examples/paper/figures.yaml
#
# The second is the forward run, or with `AFRICA_NEUTRAL=true` the control. The stage script,
# `burnin.jl` or `forward.jl`, runs as it is, configured by the `AFRICA_*` variables, which `fair run`
# passes on; the forward run and the control start from the settled state their seed's burn-in
# registered, read from the registry in place of `AFRICA_START`. The stage is given the run's handle
# as `PIPELINE`, and reads every input through it: each file is put where the plain stage reads it,
# from the run's store. The third draws the paper's figures from every whole replicate on the grid -
# its forward run, its control and its burn-in's seeding all registered - and registers them as
# `CaseStudy/<grid>/Figures/<Name>`.
#
# Each output is registered as `CaseStudy/<grid>/<Stage>/<Output>_<seed>` in the `AfricaPlants`
# namespace, as `CaseStudy/50km/Forward/Cells_01`. The grid is the cell size `AFRICA_CELLSIZE` names,
# which a full-scale pipeline run must; a reduced scale is named in its place, `Small` or `Medium`,
# since its species pool is not the paper's.

using AfricaPlants
using DataPipeline
using Printf
using Unitful: ustrip

const STAGE = only(ARGS)
STAGE in ("burnin", "forward", "figures") ||
    error("the stage is `burnin`, `forward` or `figures`, not `$STAGE`")

# The grid's segment of every name: the cell size a full-scale run names, else the reduced scale.
function gridname()
    smallscale() && return "Small"
    mediumscale() && return "Medium"
    cellsize = requested_cellsize()
    isnothing(cellsize) &&
        error("a pipeline run at full scale names its cell size in AFRICA_CELLSIZE")
    return "$(round(Int, ustrip(cellsize)))km"
end
const GRID = gridname()
const SEED = parse(Int, get(ENV, "AFRICA_SEED", "1"))

# The registered name of one of a stage's outputs.
function product(stage, output; seed = SEED)
    return @sprintf("CaseStudy/%s/%s/%s_%02d", GRID, stage, output, seed)
end

# Run the stage in a module of its own, which keeps its settings - where it wrote, and for the forward
# stage whether it was the control and kept its end state - and register what it wrote.
function runstage(handle)
    # ERA5's monthly files, put where the stage reads the climate before it asks them which month
    # they end in.
    provide_files(handle, :era5, era5_dir())
    if STAGE == "forward"
        haskey(ENV, "AFRICA_START") &&
            error("a pipeline run starts from $(product("Hold", "State")) as registered: " *
                  "unset AFRICA_START")
        ENV["AFRICA_START"] = link_read!(handle, product("Hold", "State"))
    end
    run = Module(:Stage)
    Core.eval(run, :(const PIPELINE = $handle))
    Base.include(run, joinpath(@__DIR__, "$STAGE.jl"))
    run.SEED == SEED || error("the stage ran seed $(run.SEED), not $SEED")
    # Each output's stage and kind, and the file the stage wrote it to.
    outputs = Pair{Tuple{String, String}, String}[]
    if STAGE == "burnin"
        burnin, start = "burnin_seed$(SEED)_00", "start_seed$(SEED)_00"
        append!(outputs,
                [("Burnin", "Diversity") => "diversity_burnin_seed$(SEED).csv",
                    ("Burnin", "Totals") => "totals_burnin_seed$(SEED).jld2",
                    ("Burnin", "Recorded") => "recorded_richness.csv",
                    ("Burnin", "Provenance") => "$burnin.provenance.toml",
                    ("Hold", "Diversity") => "diversity_hold_seed$(SEED).csv",
                    ("Hold", "Totals") => "totals_hold_seed$(SEED).jld2",
                    ("Hold", "State") => "$start.jld2",
                    ("Hold", "Provenance") => "$start.provenance.toml"])
    else
        kind = titlecase(run.STAGE)
        name = "$(run.STAGE)_seed$(SEED)"
        append!(outputs,
                [(kind, "Diversity") => "diversity_$(name).csv",
                    (kind, "Cells") => "$name.jld2",
                    (kind, "Provenance") => "$name.provenance.toml"])
        run.SAVEEND &&
            push!(outputs, (kind, "State") => "$(name)_end00.jld2")
    end
    for ((stage, output), file) in outputs
        link_write!(handle, product(stage, output),
                    path = joinpath(run.SAVEDIR, file))
    end
    return nothing
end

# The outputs the figures are drawn from, each with the file name its stage wrote it under, given the
# seed. Every seed's `Recorded` is the same file, the burn-in's seeding being the same in each.
const DRAWN_FROM = (("Forward", "Cells") => seed -> "forward_seed$(seed).jld2",
                    ("Neutral", "Cells") => seed -> "neutral_seed$(seed).jld2",
                    ("Forward", "Diversity") =>
                        seed -> "diversity_forward_seed$(seed).csv",
                    ("Neutral", "Diversity") =>
                        seed -> "diversity_neutral_seed$(seed).csv",
                    ("Burnin", "Recorded") => seed -> "recorded_richness.csv")

# Each figure a script draws, by its registered name.
const FIGURES = ("Richness" => "richness.pdf", "Abundance" => "abundance.pdf",
                 "ClimateEffect" => "climate_effect.pdf",
                 "Timeseries" => "timeseries.pdf", "Recorded" => "recorded.pdf")

# The seeds on this grid that the run may read anything of, split into the whole replicates, whose
# every output in `DRAWN_FROM` it may read, and the rest. The seeds are found in the working config's
# `read:` entries, which `canread` consults too, so nothing is recorded as an input.
function replicates(handle)
    pattern = Regex("^CaseStudy/$GRID/[^/]+/[^/]+_(\\d+)\$")
    found = Set{Int}()
    for entry in get(handle.config, "read", [])
        m = match(pattern, String(entry["data_product"]))
        isnothing(m) || push!(found, parse(Int, m[1]))
    end
    whole(seed) = all(DRAWN_FROM) do ((stage, output), _)
        return DataPipeline.canread(handle, product(stage, output, seed = seed))
    end
    complete = sort!(filter(whole, collect(found)))
    return (complete = complete,
            incomplete = sort!(setdiff(collect(found), complete)))
end

# Draw the paper's figures from every whole replicate the run may read on this grid - its forward run,
# its control and its burn-in's seeding - each output put in a directory of its own under the name its
# stage wrote it as, and register each figure drawn. A replicate missing any of them is left out, since
# the maps average the forward runs and the controls apart, so both must cover the same seeds.
function drawfigures(handle)
    seeds = replicates(handle)
    isempty(seeds.incomplete) ||
        println("Left out, not yet whole replicates: seeds ",
                join(seeds.incomplete, ", "))
    isempty(seeds.complete) &&
        error("no seed on the $GRID grid has its forward run, control and burn-in all to read")
    println("Drawn from seeds ", join(seeds.complete, ", "))
    dir = mktempdir()
    for seed in seeds.complete, ((stage, output), file) in DRAWN_FROM
        link_read!(handle, product(stage, output, seed = seed),
                   path = joinpath(dir, file(seed)))
    end
    withenv("AFRICA_SAVEDIR" => dir) do
        for script in ("plots.jl", "series.jl", "recorded.jl")
            Base.include(Module(:Figure), joinpath(@__DIR__, script))
        end
    end
    for (name, file) in FIGURES
        path = joinpath(dir, file)
        isfile(path) &&
            link_write!(handle, "CaseStudy/$GRID/Figures/$name", path = path)
    end
    return nothing
end

const HANDLE = DataPipeline.initialise()
STAGE == "figures" ? drawfigures(HANDLE) : runstage(HANDLE)
DataPipeline.finalise(HANDLE)
