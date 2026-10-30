# SPDX-License-Identifier: LGPL-3.0-or-later
#
# What the whole landscape did over the century, the forward run against its control: the plants it
# holds, the species still alive, and the diversity partition at order 1 - the effective number of
# species over the continent, and the effective number of distinct communities its cells make up.
#
#     julia --project=examples/paper examples/paper/series.jl
#
# | variable         | default        | meaning                                         |
# |------------------|----------------|-------------------------------------------------|
# | `AFRICA_SAVEDIR` | `./Africa_run` | where the `diversity_*.csv` are read and the figure written |
# | `AFRICA_SEED`    | `1`            | which replicate's records to draw               |
#
# It draws the runs alone, from 1940. The settling hold before them is left out: its years are not
# calendar years, so drawing them to the left of 1940 reads as a decade of the 1930s that was never
# simulated. `diversity_hold_seed<N>.csv` holds them for anyone who wants them.
#
# It reads the yearly tables every stage writes, not the runs themselves, so it costs nothing to
# redraw. Writes `timeseries.pdf` beside the runs.

using CSV
using DataFrames
using Plots

const SAVEDIR = get(ENV, "AFRICA_SAVEDIR", joinpath(pwd(), "Africa_run"))
const SEED = get(ENV, "AFRICA_SEED", "1")
const START = 1940

# One stage's yearly record. `offset` puts its `years` on the calendar: the hold ends where the
# forward run and the control begin, so it is drawn to the left of them.
function stage(name::AbstractString, offset::Real)
    path = joinpath(SAVEDIR, "diversity_$(name)_seed$(SEED).csv")
    isfile(path) ||
        error("no yearly record at $(path); the runs predate it, or the seed is wrong")
    table = CSV.read(path, DataFrame)
    table.year = table.years .+ offset
    return table
end

# One measure at one order through a stage, and one of the per-year totals, both as year and value.
function measure(table::DataFrame, name::AbstractString, q::AbstractString)
    rows = filter(r -> r.measure == name && string(r.q) == q, table)
    return sort!(unique(select(rows, :year, :diversity => :value)), :year)
end
function total(table::DataFrame, column::Symbol)
    return sort!(combine(groupby(table, :year), column => first => :value),
                 :year)
end

forward = stage("forward", START)
control = stage("neutral", START)

# One panel: the two runs that share a settled state, which part at `START`.
function panel(of, title, ylabel; legend = false)
    plt = plot(title = title, titleloc = :left, ylabel = ylabel,
               xlabel = "year", legend = legend, grid = false)
    for (table, label, colour) in ((control, "$(START) climate held",
                                    :steelblue),
                                   (forward, "$(START) to 2026 climate",
                                    :firebrick))
        series = of(table)
        plot!(plt, series.year, series.value, label = label, colour = colour,
              linewidth = 2)
    end
    # From zero, so that the size of a change can be read against the quantity itself.
    ylims!(plt, 0, Inf)
    return plt
end

figure = plot(panel(t -> total(t, :individuals), "A  individual plants",
                    "individuals", legend = :bottomright),
              panel(t -> measure(t, "gamma", "1.0"),
                    "B  effective number of species (q = 1)",
                    "effective species"),
              panel(t -> measure(t, "norm_beta", "1.0"),
                    "C  distinct communities (q = 1)",
                    "effective communities"),
              layout = (1, 3), size = (1500, 470), margin = 5Plots.mm,
              left_margin = 12Plots.mm, bottom_margin = 8Plots.mm)
out = joinpath(SAVEDIR, "timeseries.pdf")
savefig(figure, out)
println("seed ", SEED, ": ", START, " to ",
        round(Int, maximum(forward.year)), "; drawn to ", out)
