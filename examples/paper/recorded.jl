# SPDX-License-Identifier: LGPL-3.0-or-later
#
# What the simulation made of what it was given: the species a cell ends with against the species
# ever recorded in it, for every forward run, each drawn as a series of its own in one colour so that
# the spread between replicates shows. The richness pattern a run shows is seeded from the records,
# so a map of it says as much about collectors as about plants; what a run can claim is that the
# pattern **persists** under a century of dynamics, and that the model puts species where a cell can
# hold them rather than only where somebody looked. Both are questions about the scatter, not the map.
#
#     julia --project=examples/paper examples/paper/recorded.jl
#
# | variable         | default        | meaning                                         |
# |------------------|----------------|-------------------------------------------------|
# | `AFRICA_SAVEDIR` | `./Africa_run` | where the runs are read and the figure written  |
#
# The species recorded in each cell are those the burn-in placed there from the records, which
# `burnin.jl` writes beside the runs as `recorded_richness.csv`. Writes `recorded.pdf`.

using CSV
using DataFrames
using JLD2
using Plots
using Printf
using Statistics

const SAVEDIR = get(ENV, "AFRICA_SAVEDIR", joinpath(pwd(), "Africa_run"))
const RECORDED = joinpath(SAVEDIR, "recorded_richness.csv")
const COLOUR = :darkgreen

# Every forward run in `SAVEDIR` in seed order, each its seed and loaded file, refusing runs made on
# different grids or spans. The name's pattern leaves out the end states, `forward_seed<N>_end00.jld2`.
function forward_runs()
    found = filter(!isnothing,
                   match.(r"^forward_seed(\d+)\.jld2$", readdir(SAVEDIR)))
    isempty(found) && error("no forward runs in $(SAVEDIR)")
    runs = map(sort(found, by = m -> parse(Int, m[1]))) do m
        return (seed = parse(Int, m[1]),
                data = load(joinpath(SAVEDIR, m.match)))
    end
    for run in runs
        (run.data["shape"] == first(runs).data["shape"] &&
         run.data["years"] == first(runs).data["years"]) ||
            error("the forward runs in $(SAVEDIR) are not all on one grid and span")
    end
    return runs
end

# One run's cells in the last year against `counts`, the species recorded in each cell. A cell is
# compared only where both numbers mean something: it is simulated, it holds individuals, and
# something was recorded there. The cells simulated with nothing recorded are counted apart.
function compared(run, counts)
    q0 = findfirst(==(0.0), run["qs"])
    simulated = run["diversity"][:, q0, end]
    shown = run["active"] .& (run["cell_totals"][:, end] .> 0) .&
            isfinite.(simulated)
    both = shown .& (counts .> 0)
    return (recorded = counts[both], simulated = simulated[both],
            empty_of_records = count(shown .& (counts .== 0)),
            fit = cor(log10.(counts[both]), log10.(simulated[both])))
end

runs = forward_runs()
years = first(runs).data["years"]
isfile(RECORDED) ||
    error("no $(RECORDED): run `burnin.jl` into $(SAVEDIR) first")
counts = CSV.read(RECORDED, DataFrame).recorded
length(counts) == length(first(runs).data["active"]) ||
    error("$(RECORDED) has $(length(counts)) cells and the runs have " *
          "$(length(first(runs).data["active"]))")
comparisons = [compared(run.data, counts) for run in runs]
ratios = [c.simulated ./ c.recorded for c in comparisons]
# One set of bins for every run's histogram, so that their outlines can be compared.
edges = range(minimum(r -> minimum(log10, r), ratios),
              maximum(r -> maximum(log10, r), ratios), length = 61)

scatter = plot(xscale = :log10, yscale = :log10,
               xlabel = "species recorded in the cell",
               ylabel = "species simulated in $(years[end])",
               title = "A  simulated against recorded", titleloc = :left,
               legend = :bottomright, grid = false)
histogram2 = plot(xlabel = "log10(simulated / recorded)", ylabel = "cells",
                  title = "B  how many more species a cell holds",
                  titleloc = :left,
                  legend = false, grid = false)
for (c, ratio) in zip(comparisons, ratios)
    plot!(scatter, c.recorded, c.simulated, seriestype = :scatter,
          markersize = 1.2,
          markeralpha = 0.15, markerstrokewidth = 0, colour = COLOUR,
          label = "")
    stephist!(histogram2, log10.(ratio), bins = edges, colour = COLOUR,
              linewidth = 1,
              label = "")
end
# The legend's marker, opaque and larger than the points it stands for, with the runs' mean
# correlation on log scales.
plot!(scatter, [NaN], [NaN], seriestype = :scatter, markersize = 4,
      markerstrokewidth = 0,
      colour = COLOUR,
      label = @sprintf("%d to %d climate: %d runs, r = %.3f", first(years),
                       last(years),
                       length(runs), mean(c.fit for c in comparisons)))
plot!(scatter, [1, maximum(counts)], [1, maximum(counts)], colour = :black,
      linestyle = :dash, label = "")
vline!(histogram2, [0.0], colour = :black, linestyle = :dash)

figure = plot(scatter, histogram2, layout = (1, 2), size = (1100, 460),
              margin = 5Plots.mm, left_margin = 10Plots.mm)
out = joinpath(SAVEDIR, "recorded.pdf")
savefig(figure, out)
for (run, c, ratio) in zip(runs, comparisons, ratios)
    @printf("seed %d: %d cells compared, %d simulated cells with no records; median simulated/recorded %.2f, r = %.2f\n",
            run.seed, length(c.recorded), c.empty_of_records, median(ratio),
            c.fit)
end
println(length(runs), " forward runs -> ", out)
