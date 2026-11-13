# SPDX-License-Identifier: LGPL-3.0-or-later
#
# What the simulation made of what it was given: the species a cell ends with against the species
# ever recorded in it. The richness pattern a run shows is seeded from the records, so a map of it
# says as much about collectors as about plants; what a run can claim is that the pattern **persists**
# under a century of dynamics, and that the model puts species where a cell can hold them rather than
# only where somebody looked. Both are questions about the scatter, not the map.
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

runs = sort(filter(f -> startswith(f, "forward_seed") && endswith(f, ".jld2") &&
                        !contains(f, "_end"), readdir(SAVEDIR)))
isempty(runs) && error("no forward runs in $(SAVEDIR)")
run = load(joinpath(SAVEDIR, first(runs)))
active, years = run["active"], run["years"]
q0 = findfirst(==(0.0), run["qs"])

isfile(RECORDED) ||
    error("no $(RECORDED): run `burnin.jl` into $(SAVEDIR) first")
counts = CSV.read(RECORDED, DataFrame).recorded
length(counts) == length(active) ||
    error("$(RECORDED) has $(length(counts)) cells and the runs have $(length(active))")

# A cell is compared only where both numbers mean something: it is simulated, it holds individuals,
# and something was recorded there. The cells with no records are the point of the second panel.
simulated = run["diversity"][:, q0, length(years)]
held = run["cell_totals"][:, length(years)] .> 0
shown = active .& held .& isfinite.(simulated)
both = shown .& (counts .> 0)
empty_of_records = shown .& (counts .== 0)

fit = cor(log10.(counts[both]), log10.(simulated[both]))
scatter = plot(counts[both], simulated[both], seriestype = :scatter,
               markersize = 1.2, markeralpha = 0.25, markerstrokewidth = 0,
               colour = :darkgreen, xscale = :log10, yscale = :log10,
               xlabel = "species recorded in the cell",
               ylabel = "species simulated in $(years[end])",
               title = "A  simulated against recorded", titleloc = :left,
               legend = false, grid = false)
plot!(scatter, [1, maximum(counts)], [1, maximum(counts)], colour = :black,
      linestyle = :dash)
annotate!(scatter, 2, 0.6 * maximum(simulated[both]),
          text(@sprintf("r = %.2f on log scales\n%d cells", fit, count(both)),
               :left, 8))

ratio = simulated[both] ./ counts[both]
histogram2 = histogram(log10.(ratio), bins = 60, colour = :darkgreen,
                       linewidth = 0, legend = false, grid = false,
                       xlabel = "log10(simulated / recorded)",
                       ylabel = "cells", titleloc = :left,
                       title = "B  how many more species a cell holds")
vline!(histogram2, [0.0], colour = :black, linestyle = :dash)

figure = plot(scatter, histogram2, layout = (1, 2), size = (1100, 460),
              margin = 5Plots.mm, left_margin = 10Plots.mm)
out = joinpath(SAVEDIR, "recorded.pdf")
savefig(figure, out)
@printf("%d cells compared, %d simulated cells with no records; median simulated/recorded %.2f, r = %.2f -> %s\n",
        count(both), count(empty_of_records), median(ratio), fit, out)
