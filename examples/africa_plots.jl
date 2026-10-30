# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Maps of Africa from the forward runs and their controls, averaged over every replicate seed in
# `AFRICA_SAVEDIR`.
#
# `richness.pdf`: species richness in the first and last recorded years, the control's last year, and
# how far the forward runs depart from it - which is the part of the change the climate is
# responsible for. With no control runs to compare against, the change between the two years is
# drawn in place of the last two panels.
#
# `abundance.pdf` and `climate_effect.pdf`, drawn only where control runs exist: the individuals each
# cell holds at the end under the changing climate and under the held climate, and, on its own, the
# difference between them in individuals. This is where a century of climate shows itself.
#
#     julia --project=examples examples/africa_plots.jl
#
# | variable         | default        | meaning                                         |
# |------------------|----------------|-------------------------------------------------|
# | `AFRICA_SAVEDIR` | `./Africa_run` | where the runs are read and the figures written |
#
# Richness is normalised subcommunity alpha diversity at order 0, which for one cell is the number of
# species in it. A cell that held no individual in any recorded year of any run - a desert cell with
# no records to seed it - is drawn as sea rather than as no species, so that it cannot be read as an
# extinction; a cell that held plants and lost them all is drawn as empty. Writes
# `richness.pdf`, and where there are controls `abundance.pdf` and `climate_effect.pdf`, beside the
# runs.

using JLD2
using Plots
using Printf
using Statistics

const SAVEDIR = get(ENV, "AFRICA_SAVEDIR", joinpath(pwd(), "Africa_run"))

# Richness is drawn on a scale that stops at the 98th percentile of cell richness: on a scale
# reaching the Cape's few thousand species, every other cell reads as near black. The cells above it,
# about one in fifty, all take the palest colour, and the caption says so. The difference panel is
# clipped the same way, so that a handful of extreme cells does not leave the rest colourless.
const CLIP = 0.98
const GREEN = cgrad(:algae, rev = true)

# Every run of `kind` in `SAVEDIR`, as the loaded files, refusing runs made on different grids.
function load_runs(kind::AbstractString)
    names = sort(filter(f -> startswith(f, kind * "_seed") &&
                             endswith(f, ".jld2") &&
                             !contains(f, "_end"), readdir(SAVEDIR)))
    runs = [load(joinpath(SAVEDIR, n)) for n in names]
    for r in runs
        haskey(r, "cell_totals") ||
            error("$(kind) runs in $(SAVEDIR) predate the per-cell totals; rerun them with the " *
                  "current `examples/africa_forward.jl`")
        (r["shape"] == runs[1]["shape"] && r["years"] == runs[1]["years"]) ||
            error("the $(kind) runs in $(SAVEDIR) are not all on one grid and span")
    end
    return runs
end

# The active cells that hold an individual in some recorded year of any of `runs`, forward runs and
# controls together: the cells drawn. Every other cell is drawn as sea.
function ever_held(runs)
    return reduce(.|,
                  [r["active"] .& vec(any(r["cell_totals"] .> 0, dims = 2))
                   for r in runs])
end

# Each cell's richness in the `column`th recorded year, averaged over `runs`: `NaN` outside `drawn`,
# which is what keeps an unseeded desert off the map, and zero in a cell of `drawn` that holds nothing
# that year.
function richness(runs, column::Integer, drawn::AbstractVector{Bool})
    each = map(runs) do r
        held = r["cell_totals"][:, column] .> 0
        d = r["diversity"][:, findfirst(==(0.0), r["qs"]), column]
        return [drawn[c] ? (held[c] ? d[c] : 0.0) : NaN for c in eachindex(d)]
    end
    return reduce(+, each) ./ length(each)
end

# Each cell's individuals in the `column`th recorded year, in millions, averaged over `runs`, and
# `NaN` outside `drawn`, as `richness` has it.
function abundance(runs, column::Integer, drawn::AbstractVector{Bool})
    each = map(runs) do r
        held = r["cell_totals"][:, column]
        return [drawn[c] ? held[c] / 1.0e6 : NaN for c in eachindex(held)]
    end
    return reduce(+, each) ./ length(each)
end

# `values` as a `y x x` map on the runs' grid, rows in ascending `y` as `heatmap` expects.
function as_map(values::AbstractVector, run)
    grid = reshape(values, run["shape"])
    return run["y"][1] < run["y"][end] ? grid : grid[end:-1:1, :]
end

# A heatmap of `values` on the runs' grid in kilometres, with the continent's own aspect.
function panel(run, values; title, clims, color = GREEN)
    y = run["y"]
    ys = y[1] < y[end] ? y : reverse(y)
    return heatmap(run["x"] ./ 1000, ys ./ 1000, as_map(values, run),
                   title = title, titleloc = :left, aspect_ratio = :equal,
                   color = color, clims = clims,
                   background_color_inside = :lightblue, grid = false,
                   xlabel = "km", ylabel = "km", xticks = -8000:4000:8000)
end

# The value the scale stops at: the `CLIP` quantile of everything drawn, so that one panel cannot
# set a scale the others are invisible on.
top(maps...) = max(quantile(filter(!isnan, vcat(maps...)), CLIP), 1)

forward = load_runs("forward")
isempty(forward) && error("no forward runs in $(SAVEDIR)")
neutral = load_runs("neutral")
run = forward[1]
drawn = ever_held(vcat(forward, neutral))
first_year, last_year = run["years"][1], run["years"][end]
before = richness(forward, 1, drawn)
after = richness(forward, length(run["years"]), drawn)

panels = if isempty(neutral)
    change = after .- before
    span = top(abs.(change))
    scale = top(before, after)
    [panel(run, before, title = "A  $(first_year)", clims = (0, scale)),
        panel(run, after, title = "B  $(last_year)", clims = (0, scale)),
        panel(run, change, title = "C  change", clims = (-span, span),
              color = :balance)]
else
    control = richness(neutral, length(run["years"]), drawn)
    departure = after .- control
    span = top(abs.(departure))
    scale = top(before, after, control)
    [panel(run, before, title = "A  $(first_year)", clims = (0, scale)),
        panel(run, after, title = "B  $(last_year)", clims = (0, scale)),
        panel(run, control, title = "C  $(last_year) control",
              clims = (0, scale)),
        panel(run, departure,
              title = "D  $(last_year) climate minus control",
              clims = (-span, span), color = :balance)]
end

# Two panels to a row, so that the maps are as large as the page allows; a figure of one panel is
# drawn wider than half a row, so that its title has the room a two-panel row's does not give it.
function sheet(panels::Vector, path::AbstractString)
    columns = min(2, length(panels))
    rows = cld(length(panels), columns)
    width = length(panels) == 1 ? 760 : 560 * columns
    figure = plot(panels..., layout = (rows, columns),
                  size = (width, 460 * rows), margin = 3Plots.mm,
                  left_margin = 10Plots.mm)
    savefig(figure, path)
    return path
end

sheet(panels, joinpath(SAVEDIR, "richness.pdf"))
@printf("%d forward run%s%s; richness %d to %d, scale to %d species, %d cells never held a plant -> %s\n",
        length(forward), length(forward) == 1 ? "" : "s",
        isempty(neutral) ? "" :
        " and $(length(neutral)) control run$(length(neutral) == 1 ? "" : "s")",
        first_year, last_year, round(Int, top(before, after)),
        count(run["active"] .& .!drawn),
        joinpath(SAVEDIR, "richness.pdf"))

# The climate's effect on how many plants a cell holds, which needs a control to compare against.
if !isempty(neutral)
    climate = abundance(forward, length(run["years"]), drawn)
    held = abundance(neutral, length(run["years"]), drawn)
    scale = top(climate, held)
    # The difference in individuals, not as a percentage of the control: a desert cell whose few
    # plants double is a large percentage and a negligible number of plants, and on a percentage
    # scale the Sahara swamps the tropics, where nearly all of the continent's plants are.
    difference = [isnan(climate[c]) || isnan(held[c]) ? NaN :
                  climate[c] - held[c]
                  for c in eachindex(climate)]
    reach = top(abs.(difference))
    sheet([
              panel(run, climate, title = "A  $(last_year) individuals",
                    clims = (0, scale)),
              panel(run, held, title = "B  $(last_year) control",
                    clims = (0, scale))],
          joinpath(SAVEDIR, "abundance.pdf"))
    sheet([panel(run, difference,
                 title = "climate minus control, millions of plants, $(last_year)",
                 clims = (-reach, reach), color = :balance)],
          joinpath(SAVEDIR, "climate_effect.pdf"))
    @printf("abundance: scale to %.0f million a cell; the difference, clipped at +/- %.0f million, drawn on its own -> %s, %s\n",
            scale, reach, joinpath(SAVEDIR, "abundance.pdf"),
            joinpath(SAVEDIR, "climate_effect.pdf"))
end
