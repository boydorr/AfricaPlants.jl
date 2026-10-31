# SPDX-License-Identifier: LGPL-3.0-or-later
#
# A stage of the paper's run as a data pipeline run, the files it writes registered as the run's
# outputs. From the root of the repository:
#
#     fair pull --local examples/paper/burnin.yaml && fair run examples/paper/burnin.yaml
#     fair pull --local examples/paper/forward.yaml && fair run examples/paper/forward.yaml
#
# The second is the forward run, or with `AFRICA_NEUTRAL=true` the control. The stage script,
# `burnin.jl` or `forward.jl`, runs as it is, configured by the `AFRICA_*` variables, which `fair run`
# passes on; the forward run and the control start from the settled state their seed's burn-in
# registered, read from the registry in place of `AFRICA_START`.
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
STAGE in ("burnin", "forward") ||
    error("the stage is `burnin` or `forward`, not `$STAGE`")

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
function product(stage, output)
    return @sprintf("CaseStudy/%s/%s/%s_%02d", GRID, stage, output, SEED)
end

const HANDLE = DataPipeline.initialise()

if STAGE == "forward"
    haskey(ENV, "AFRICA_START") &&
        error("a pipeline run starts from $(product("Hold", "State")) as registered: " *
              "unset AFRICA_START")
    ENV["AFRICA_START"] = link_read!(HANDLE, product("Hold", "State"))
end

# The stage in a module of its own, which keeps its settings: where it wrote, and for the forward
# stage whether it was the control and kept its end state.
const RUN = Module(:Stage)
Base.include(RUN, joinpath(@__DIR__, "$STAGE.jl"))
RUN.SEED == SEED || error("the stage ran seed $(RUN.SEED), not $SEED")

# Each output's stage and kind, and the file the stage wrote it to.
outputs = Pair{Tuple{String, String}, String}[]
if STAGE == "burnin"
    append!(outputs,
            [("Burnin", "Diversity") => "diversity_burnin_seed$(SEED).csv",
                ("Burnin", "Totals") => "totals_burnin_seed$(SEED).jld2",
                ("Hold", "Diversity") => "diversity_hold_seed$(SEED).csv",
                ("Hold", "Totals") => "totals_hold_seed$(SEED).jld2",
                ("Hold", "State") => "start_seed$(SEED)_00.jld2"])
else
    kind = titlecase(RUN.STAGE)
    append!(outputs,
            [(kind, "Diversity") => "diversity_$(RUN.STAGE)_seed$(SEED).csv",
                (kind, "Cells") => "$(RUN.STAGE)_seed$(SEED).jld2"])
    RUN.SAVEEND &&
        push!(outputs,
              (kind, "State") => "$(RUN.STAGE)_seed$(SEED)_end00.jld2")
end

for ((stage, output), file) in outputs
    link_write!(HANDLE, product(stage, output),
                path = joinpath(RUN.SAVEDIR, file))
end
DataPipeline.finalise(HANDLE)
