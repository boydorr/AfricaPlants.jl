# SPDX-License-Identifier: LGPL-3.0-or-later
#
# What a backwards burn-in seeds from: occurrence records, each weighed by the vegetation where it was
# made. EVI stands in for how many plants a place holds, and a record count for how hard it was
# searched, so the vegetation of each 0.05 degree cell is shared among the records made there.

"""
    MIN_EVI_MONTHS

The fewest good or marginal months a 0.05 degree cell's mean EVI must be taken over to be trusted;
a cell with fewer has no EVI, and its records weigh nothing.
"""
const MIN_EVI_MONTHS = 36

"""
    seeding_layer(path)

Return the layer each seeding record is weighed by, on a 0.05 degree grid of its own over Africa:
each cell's mean EVI times the cell's land area within Natural Earth's Africa, as an area. A negative
mean counts as no vegetation, and a cell whose EVI is not reliable has no value. Under MPI every rank
must call it.

  - `path`: the mean EVI over the Africa box as a GeoTIFF, `NaN` where it rests on too few months, as
    `data/src/evi_reliable.jl` writes it.
"""
function seeding_layer(path::AbstractString)
    evi = RasterFileSpec(path, axis = EcoSISTEM.NicheAxis)
    land = ShapeCoverage(NaturalEarthSpec("Africa", level = "CONTINENT"),
                         axis = SurfaceArea)
    amount = ConstructedRasterSpec(evi, land, axis = SurfaceArea) do e, l
        return max.(e, 0.0) .* l
    end
    grid = StudyArea(regime = evi, within = africa_within(), cellsize = 0.05°,
                     verbosity = :silent)
    return EcoSISTEM.materialise(amount, grid, role = EcoSISTEM.Resource)
end

"""
    months_back(year, month; start)

Return how many months each record's `(year, month)` lies before `start`, the month a backwards
run begins at: zero for a record in that month, negative for one after it.
"""
function months_back(year::AbstractVector{<:Integer},
                     month::AbstractVector{<:Integer}; start::NamedTuple)
    first = start.year * 12 + start.month
    return [first - (y * 12 + mo) for (y, mo) in zip(year, month)]
end

"""
    scale_to_total(factors, total; floor = 1.0)

Return `(scale, counts)`: the one multiplier `scale` for which `counts = max.(scale .* factors,
floor)` sums to `total`, found by bisection, so that relative factors become individuals adding up to
a chosen number while each still seeds at least `floor`. Where even the floors exceed `total` the
scale is zero.

  - `factors`: the relative factors, none negative.
  - `total`: the sum the counts are to reach.
  - `floor`: the fewest each factor's count may be.
"""
function scale_to_total(factors::AbstractVector{<:Real}, total::Real;
                        floor::Real = 1.0)
    all(>=(0), factors) || error("seeding factors cannot be negative")
    summed(k) = sum(f -> max(k * f, floor), factors, init = 0.0)
    if summed(0.0) >= total
        return (scale = 0.0, counts = fill(Float64(floor), length(factors)))
    end
    lo, hi = 0.0, total / sum(factors)
    for _ in 1:200
        mid = (lo + hi) / 2
        summed(mid) < total ? (lo = mid) : (hi = mid)
    end
    return (scale = hi, counts = max.(hi .* factors, floor))
end
