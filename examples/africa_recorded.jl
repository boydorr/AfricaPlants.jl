# SPDX-License-Identifier: LGPL-3.0-or-later
#
# What the simulation made of what it was given: the species a cell ends with against the species
# ever recorded in it. The richness pattern a run shows is seeded from the records, so a map of it
# says as much about collectors as about plants; what a run can claim is that the pattern **persists**
# under a century of dynamics, and that the model puts species where a cell can hold them rather than
# only where somebody looked. Both are questions about the scatter, not the map.
#
#     julia --project=examples examples/africa_recorded.jl
#
# | variable         | default        | meaning                                         |
# |------------------|----------------|-------------------------------------------------|
# | `AFRICA_SAVEDIR` | `./Africa_run` | where the runs are read and the figure written  |
# | `AFRICA_CELLSIZE`| as the runs used | the grid to place the records on              |
#
# Placing the records needs the run's own grid, which takes some minutes to build, so the counts are
# kept in `recorded_richness.csv` beside the runs and reused. Writes `recorded.pdf`.

using AfricaPlants
using EcoSISTEM
using EcoSISTEM.Units
using Unitful
using Unitful.DefaultSymbols
using CSV
using DataFrames
using JLD2
using Plots
using Printf
using Statistics

const SAVEDIR = get(ENV, "AFRICA_SAVEDIR", joinpath(pwd(), "Africa_run"))
const DATA = joinpath(pkgdir(AfricaPlants), "data")
const ENVELOPES = get(ENV, "AFRICA_ENVELOPES",
                      expanduser("~/git/plant_trait/data/global_plant_climate_envelopes.csv"))
const CACHE = joinpath(SAVEDIR, "recorded_richness.csv")

"""
    recorded_richness(cells)

Return how many of the simulated species were ever recorded in each of `cells` cells, by placing
every seeding record on the run's grid as the burn-in does, snapping a record in an unsimulated cell
to the nearest simulated one within three cells.
"""
function recorded_richness(cells::Integer)
    envelopes = CSV.read(ENVELOPES, DataFrame,
                         select = [:species, :genus, :family, :order, :tmin,
                             :tp, :ssr, :swvl1])
    widths = CSV.read(joinpath(DATA, "species_widths.csv"), DataFrame)
    pool = species_pool(envelopes, widths).pool
    records = CSV.read(joinpath(DATA, "records_africa.csv"), DataFrame,
                       select = [:species, :decimalLatitude, :decimalLongitude])
    simulated = Set(pool.species)
    filter!(r -> !ismissing(r.species) && r.species in simulated, records)
    positioning = positioning_layers()
    chosen = choose_cellsize(nrow(pool), regime = positioning.regime,
                             supply = positioning.supply)
    area = africa_area(chosen.cellsize, regime = positioning.regime,
                       supply = positioning.supply)
    layers = africa_layers(ForwardClimate())
    habitat = GridHabitat(regime = layers.regime, supply = layers.supply,
                          area = area)
    length(parent(habitat.active)) == cells ||
        error("the grid has $(length(parent(habitat.active))) cells and the runs have $(cells)")
    placed = grid_cells(habitat, records.decimalLatitude,
                        records.decimalLongitude, snap = 3)
    seen = [Set{String}() for _ in 1:cells]
    for (cell, species) in zip(placed, records.species)
        cell > 0 && push!(seen[cell], species)
    end
    return length.(seen)
end

runs = sort(filter(f -> startswith(f, "forward_seed") && endswith(f, ".jld2") &&
                        !contains(f, "_end"), readdir(SAVEDIR)))
isempty(runs) && error("no forward runs in $(SAVEDIR)")
run = load(joinpath(SAVEDIR, first(runs)))
active, years = run["active"], run["years"]
q0 = findfirst(==(0.0), run["qs"])

counts = if isfile(CACHE)
    CSV.read(CACHE, DataFrame).recorded
else
    println("placing the records on the run's grid; this takes a few minutes")
    flush(stdout)
    found = recorded_richness(length(active))
    CSV.write(CACHE, DataFrame(cell = eachindex(found), recorded = found))
    found
end

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
