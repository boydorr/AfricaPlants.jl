# SPDX-License-Identifier: LGPL-3.0-or-later
#
# What the whole landscape did over the century, every forward run against every control: the plants
# it holds, and the diversity partition at order 1 - the effective number of species over the
# continent, and the effective number of distinct communities its cells make up. Each run is a thin
# line in its kind's colour, so that the replicates show as a bundle.
#
#     julia --project=examples/paper examples/paper/series.jl
#
# | variable         | default        | meaning                                         |
# |------------------|----------------|-------------------------------------------------|
# | `AFRICA_SAVEDIR` | `./Africa_run` | where the `diversity_*.csv` are read and the figure written |
#
# It draws the runs alone, from 1941. The settling hold before them is left out: its years are not
# calendar years, so drawing them to the left of 1941 reads as a decade of the 1930s that was never
# simulated. `diversity_hold_seed<N>.csv` holds them for anyone who wants them.
#
# It reads the yearly tables every stage writes, not the runs themselves, so it costs nothing to
# redraw. Writes `timeseries.pdf` beside the runs.

using AfricaPlants: FIRST_FULL_YEAR, HELD_DECADE
using CSV
using DataFrames
using Plots

const SAVEDIR = get(ENV, "AFRICA_SAVEDIR", joinpath(pwd(), "Africa_run"))
const START = FIRST_FULL_YEAR

# Every run of `kind`, `forward` or `neutral`, in `SAVEDIR` in seed order, each as its yearly record
# with `years` put on the calendar. A table in which a year appears twice holds more than one run,
# and is refused.
function stage(kind::AbstractString)
    found = filter(!isnothing,
                   match.(Regex("^diversity_$(kind)_seed(\\d+)\\.csv\$"),
                          readdir(SAVEDIR)))
    return map(sort(found, by = m -> parse(Int, m[1]))) do m
        table = CSV.read(joinpath(SAVEDIR, m.match), DataFrame)
        for rows in groupby(table, [:measure, :q])
            allunique(rows.years) ||
                error("$(m.match) in $(SAVEDIR) holds a year more than once, so more than one run")
        end
        table.year = table.years .+ START
        return table
    end
end

# One measure at one order through a run, and one of the per-year totals, both as year and value.
function measure(table::DataFrame, name::AbstractString, q::AbstractString)
    rows = filter(r -> r.measure == name && string(r.q) == q, table)
    return sort!(unique(select(rows, :year, :diversity => :value)), :year)
end
function total(table::DataFrame, column::Symbol)
    return sort!(combine(groupby(table, :year), column => first => :value),
                 :year)
end

forward = stage("forward")
control = stage("neutral")
isempty(forward) && error("no yearly records of forward runs in $(SAVEDIR)")

# One panel: every control and every forward run, each pair sharing a settled state, which part at
# `START`.
function panel(of, title, ylabel; legend = false)
    plt = plot(title = title, titleloc = :left, ylabel = ylabel,
               xlabel = "year", legend = legend, grid = false)
    for (runs, label, colour) in ((control,
                                   "$(first(HELD_DECADE))-$(last(HELD_DECADE)) average held",
                                   :steelblue),
                                  (forward, "$(START) to 2026 climate",
                                   :firebrick))
        for (i, table) in enumerate(runs)
            series = of(table)
            plot!(plt, series.year, series.value, colour = colour,
                  linewidth = 1,
                  label = i == 1 ?
                          "$(label), $(length(runs)) run$(length(runs) == 1 ? "" : "s")" :
                          "")
        end
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
println(length(forward), " forward runs and ", length(control), " controls, ",
        START, " to ", round(Int, maximum(maximum(t.year) for t in forward)),
        "; drawn to ", out)
