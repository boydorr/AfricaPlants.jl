# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The layers a run is built from: the ERA5 monthly climate species are matched to, and the three
# resources they compete for - ground, light and water - each confined to the ground in a cell
# available to plants.

"""
    AVAILABLE_CLASSES

The EarthEnv land-cover classes counted as ground plants can grow on: every class but open water,
snow and ice, and urban or built-up land.
"""
const AVAILABLE_CLASSES = (:needleleaf_trees, :evergreen_broadleaf_trees,
                           :deciduous_broadleaf_trees, :other_trees, :shrubs,
                           :herbaceous, :cultivated_and_managed,
                           :regularly_flooded, :barren)

"""
    CLIMATE_LAYERS

The layers of [`africa_layers`](@ref) that follow the climate: the two regime layers and the light
and water supplies. Each climate timing gives them a rule of its own. The available ground does not
follow the climate.
"""
const CLIMATE_LAYERS = (:temperature, :rainfall, :light, :water)

"""
    era5_dir()

Return the directory the ERA5 monthly files are read from: `era5` under `AFRICA_DATADIR` if set,
and otherwise under the repository's `data/`.
"""
function era5_dir()
    return joinpath(get(ENV, "AFRICA_DATADIR",
                        joinpath(pkgdir(@__MODULE__), "data")), "era5")
end

"""
    era5_last_month(dir = era5_dir(); codes = ("t2m", "tp", "ssr"))

Return the last month of the ERA5 files in `dir` as `(year = y, month = m)`: the month a backwards
run starts from. Every variable in `codes` must end in the same month, or the climates of a reversed
run would not line up.

  - `dir`: the directory of the ERA5 monthly files.
  - `codes`: the ERA5 variables a run reads.
"""
function era5_last_month(dir::AbstractString = era5_dir();
                         codes = ("t2m", "tp", "ssr"))
    files = readdir(dir)
    ends = map(codes) do code
        mine = filter(f -> startswith(f, "era5_$(code)_") && endswith(f, ".nc"),
                      files)
        isempty(mine) && error("no era5_$(code)_*.nc under $dir")
        last = maximum(mine) do f
            NCDatasets.NCDataset(joinpath(dir, f)) do ds
                time = haskey(ds, "valid_time") ? "valid_time" : "time"
                return maximum(ds[time][:])
            end
        end
        # By month alone: an accumulated variable's months are stamped at 06:00.
        return (year = Dates.year(last), month = Dates.month(last))
    end
    allequal(ends) ||
        error("the ERA5 variables end in different months: " *
              join(("$c $(e.year)-$(e.month)" for (c, e) in zip(codes, ends)),
                   ", "))
    return first(ends)
end

"""
    available_ground(; handle = nothing)

Return the layer of ground available to plants in each cell, the summed shares of the
[`AVAILABLE_CLASSES`](@ref), as a space supply. `handle` is the data pipeline run the land cover is
read through, or `nothing`, the default, for none.
"""
function available_ground(; handle = nothing)
    classes = [SourceSpec(EarthEnv{LandCover}, class,
                          track = source_track(handle, :earthenv))
               for class in AVAILABLE_CLASSES]
    return ConstructedRasterSpec(classes..., axis = SurfaceArea) do bands...
        return sum(bands)
    end
end

"""
    AbstractClimateTiming

How a run's climate is laid out in time: [`ForwardClimate`](@ref), [`ReversedClimate`](@ref) or
[`HeldClimatology`](@ref).
"""
abstract type AbstractClimateTiming end

"""
    ForwardClimate()

The ERA5 months in calendar order as a dated series, held at the last month once it is passed.
"""
struct ForwardClimate <: AbstractClimateTiming end

"""
    ReversedClimate()

The ERA5 months from the last back to the first, one `month_mean_duration` apart from elapsed
zero, as an undated series held at the first month once it is passed.
"""
struct ReversedClimate <: AbstractClimateTiming end

"""
    HeldClimatology(years)

Each calendar month's climate averaged over `years`, as a climatology of the months of the year,
repeated for as long as a run lasts. Every layer is summarised month by month as a forward run sees
it, its twelve-month statistic included, before the months are averaged, so the held year is the
average of what a forward run through `years` meets.

  - `years`: the calendar years averaged, each of which the climate must hold whole.
"""
struct HeldClimatology <: AbstractClimateTiming
    years::UnitRange{Int}
    HeldClimatology(years::AbstractUnitRange{<:Integer}) = new(years)
end

"""
    FIRST_FULL_YEAR

The first year every month of which has a full twelve months of ERA5 ending in it, ERA5 starting in
January 1940: the year a backwards run goes back to and a forward run starts.
"""
const FIRST_FULL_YEAR = 1941

"""
    HELD_DECADE

The years whose climatology the settling hold and the control repeat, the decade from
[`FIRST_FULL_YEAR`](@ref).
"""
const HELD_DECADE = FIRST_FULL_YEAR:(FIRST_FULL_YEAR + 9)

"""
    AbstractRegimeStatistic

What a regime layer holds of a monthly climate variable: each [`MonthlyValue`](@ref), or the
[`TrailingMinimum`](@ref) or [`TrailingMean`](@ref) over the months ending in each.
"""
abstract type AbstractRegimeStatistic end

"""
    MonthlyValue()

Each month's own value.
"""
struct MonthlyValue <: AbstractRegimeStatistic end

"""
    TrailingMinimum(months = 12)

The least monthly value over the `months` ending in each month, the statistic the species'
temperature tolerances were fitted on.
"""
struct TrailingMinimum <: AbstractRegimeStatistic
    months::Int
    TrailingMinimum(months::Integer = 12) = new(months)
end

"""
    TrailingMean(months = 12)

The mean monthly value over the `months` ending in each month, the statistic the species'
precipitation tolerances were fitted on.
"""
struct TrailingMean <: AbstractRegimeStatistic
    months::Int
    TrailingMean(months::Integer = 12) = new(months)
end

# `statistic` over the months of `window`, which run along dimension `t`.
_reduced(::TrailingMinimum, window, t::Int) = minimum(window, dims = t)
_reduced(::TrailingMean, window, t::Int) = mean(window, dims = t)

# The raster `r`, a monthly stack in time order, with every month replaced by `statistic` over the
# months ending in it. A month with too few before it takes the first full run of months instead, so
# that none is summarised over a shorter stretch than the rest; a stack no longer than the run is
# therefore the same throughout.
_summarised(r, ::MonthlyValue) = r
function _summarised(r, statistic::AbstractRegimeStatistic)
    array = r.array
    t = DimensionalData.dimnum(array, DimensionalData.Ti)
    # Reduced as bare numbers and given their unit back: a minimum over quantities cannot start from
    # a slice holding `NaN`, which every slice with sea in it does.
    unit = Unitful.unit(eltype(array))
    data = ustrip.(unit, parent(array))
    span = min(statistic.months, size(data, t))
    out = similar(data)
    for k in axes(data, t)
        last = max(k, first(axes(data, t)) + span - 1)
        window = selectdim(data, t, (last - span + 1):last)
        selectdim(out, t, k) .= dropdims(_reduced(statistic, window, t),
                                         dims = t)
    end
    return EcoSISTEM.ClimateRaster(ERA,
                                   DimensionalData.rebuild(array,
                                                           data = out .* unit),
                                   r.code)
end

# The raster `r` summarised by `statistic` and laid out as `timing` says. A calendar order is
# summarised before it is reversed or averaged into a climatology, so that a month looks back over the
# same months whichever way a run passes it.
function _laidout(r, statistic::AbstractRegimeStatistic,
                  timing::AbstractClimateTiming)
    return _retime(_summarised(r, statistic), timing)
end

# What a series of each timing does past its last slice, and what its coordinates mean.
_atend(::ForwardClimate) = HoldAtEnd()
_atend(::ReversedClimate) = HoldAtEnd()
_atend(::HeldClimatology) = RepeatAtEnd()
_calendar(::ForwardClimate) = nothing
_calendar(::ReversedClimate) = UndatedSeries()
_calendar(::HeldClimatology) = MonthOfYearSeries()

# The raster `r`, a monthly stack on real dates, laid out as `timing` says.
_retime(r, ::ForwardClimate) = r

function _retime(r, ::ReversedClimate)
    n = size(r.array, DimensionalData.Ti)
    return _slices(r, n:-1:1, (0:(n - 1)) .* 1.0month_mean_duration)
end

function _retime(r, timing::HeldClimatology)
    dates = DimensionalData.lookup(r.array, DimensionalData.Ti)
    t = DimensionalData.dimnum(r.array, DimensionalData.Ti)
    # Averaged as bare numbers and given their unit back, as `_summarised` reduces.
    unit = Unitful.unit(eltype(r.array))
    data = ustrip.(unit, parent(r.array))
    out = similar(data, ntuple(d -> d == t ? 12 : size(data, d), ndims(data)))
    for month in 1:12
        which = findall(d -> Dates.year(d) in timing.years &&
                             Dates.month(d) == month, dates)
        length(which) == length(timing.years) ||
            error("the climate holds $(length(which)) months of $(Dates.monthname(month)) " *
                  "in $(timing.years), not $(length(timing.years))")
        selectdim(out, t, month) .= dropdims(mean(selectdim(data, t, which),
                                                  dims = t), dims = t)
    end
    first_year = findall(d -> Dates.year(d) == first(timing.years), dates)
    held = _slices(r, first_year, (1:12) .* 1.0month_mean_duration)
    return EcoSISTEM.ClimateRaster(ERA,
                                   DimensionalData.rebuild(held.array,
                                                           data = out .* unit),
                                   r.code)
end

# The slices `which` of raster `r`, in that order, relabelled with elapsed `times`.
function _slices(r, which, times)
    array = r.array[DimensionalData.Ti(which)]
    return EcoSISTEM.ClimateRaster(ERA,
                                   DimensionalData.set(array,
                                                       DimensionalData.Ti =>
                                                           collect(times)),
                                   r.code)
end

# An ERA5 monthly variable read from `dir` as a dated series, through the data pipeline run `handle`
# where there is one.
function _era5source(code::AbstractString, dir::AbstractString, handle)
    return SourceSpec(ERA, code, directory = dir, atend = HoldAtEnd(),
                      track = source_track(handle, :era5))
end

# An ERA5 monthly variable read from `dir` onto `axis`, the axis the species' tolerance names,
# summarised by `statistic` and laid out in time as `timing` says. Every timing goes through a combine, forward included, so that the three timings
# build onto the same active cells.
function _era5(code::AbstractString, axis::Type{<:EcoSISTEM.NicheAxis},
               dir::AbstractString, timing::AbstractClimateTiming,
               statistic::AbstractRegimeStatistic, handle)
    return ConstructedRasterSpec(_era5source(code, dir, handle), axis = axis,
                                 atend = _atend(timing),
                                 calendar = _calendar(timing)) do values
        return _laidout(values, statistic, timing)
    end
end

# A supply of ERA5 variable `code` on `axis`, confined to the ground available to plants, summarised
# by `statistic` and laid out as `timing` says. The share of each cell that is available is the
# ground layer itself, [`available_ground`](@ref), so that every supply agrees with it about what
# ground there is. Values below zero, which regridding and ERA5's packing leave in dry cells, are no
# supply at all.
function _gated(code::AbstractString, axis::Type{<:EcoSISTEM.NicheAxis},
                dir::AbstractString, timing::AbstractClimateTiming,
                statistic::AbstractRegimeStatistic, handle)
    return ConstructedRasterSpec(_era5source(code, dir, handle),
                                 available_ground(handle = handle),
                                 axis = axis, atend = _atend(timing),
                                 calendar = _calendar(timing)) do values, ground
        gated = max.(values, zero(eltype(values.array))) .* ground
        return _laidout(gated, statistic, timing)
    end
end

"""
    africa_layers(timing = ForwardClimate(); dir = era5_dir(),
                  temperature = TrailingMinimum(), rainfall = TrailingMean(),
                  water = TrailingMean(), handle = nothing)

Return the layers of a run as a named tuple of `regime`, the ERA5 2 m temperature and total
precipitation named `temperature` and `rainfall`, and `supply`: the available ground named `space`,
and the ERA5 net solar radiation named `light` and total precipitation named `water`, each scaled by
the share of the cell available to plants.

Each regime layer holds the statistic the species' tolerances were fitted on, so that a species is
matched against the same quantity its tolerance describes: the least monthly temperature and the
mean precipitation over the twelve months ending in each month. Rain is both: as a regime it says
which species a place suits, and as a supply how many plants the place can hold, so that a desert
cannot fill to the density of a forest. The water supply is the year's mean too, since a plant draws
on what the ground has stored, and a month with no rain at all would otherwise be a month with no
supply. Light stays monthly.

# Arguments

  - `timing`: an [`AbstractClimateTiming`](@ref), how the climate is laid out in time; a dated one
    steps one month per `month_mean_duration` in a run built with a `MeanMonths()` calendar.
  - `dir`: the directory of the ERA5 monthly files.
  - `temperature`: the [`AbstractRegimeStatistic`](@ref) the temperature layer holds.
  - `rainfall`: the statistic the precipitation layer holds.
  - `water`: the statistic the precipitation supply holds.
  - `handle`: the data pipeline run the climate and land cover are read through, or `nothing`, the
    default, for none.
"""
function africa_layers(timing::AbstractClimateTiming = ForwardClimate();
                       dir::AbstractString = era5_dir(),
                       temperature::AbstractRegimeStatistic = TrailingMinimum(),
                       rainfall::AbstractRegimeStatistic = TrailingMean(),
                       water::AbstractRegimeStatistic = TrailingMean(),
                       handle = nothing)
    return (regime = (temperature = _era5("t2m", AnnualMinimumTemperature, dir,
                                          timing, temperature, handle),
                      rainfall = _era5("tp", AnnualMeanPrecipitation, dir,
                                       timing, rainfall, handle)),
            supply = (space = available_ground(handle = handle),
                      light = _gated("ssr", SolarRadiation, dir, timing,
                                     MonthlyValue(), handle),
                      water = _gated("tp", Precipitation, dir, timing, water,
                                     handle)))
end
