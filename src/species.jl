# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The species pool: every species with seeding records in Africa that the published climate
# envelopes name, with the niche each is matched to, what it consumes and how it breeds and moves.

"""
    ENVELOPES_DOI

The DOI of the published plant climate envelopes the species' tolerance means and demands are
taken from.
"""
const ENVELOPES_DOI = "10.5285/ca339c86-3674-4030-b891-35326e71141e"

"""
    ENVELOPES_PAPER_DOI

The DOI of the paper the envelopes were published with, which describes how they were built.
"""
const ENVELOPES_PAPER_DOI = "10.1111/geb.13564"

"""
    PRIOR_RECORDS

The fewest records a species' width must rest on to inform the prior width of its relatives.
"""
const PRIOR_RECORDS = 30

"""
    PRIOR_MEMBERS

The fewest well-recorded relatives a taxonomic group must hold to give a prior width.
"""
const PRIOR_MEMBERS = 5

"""
    WFO_RELEASE

The release of the World Flora Online Plant List every species name is standardised against, so
that the envelopes and the occurrence records, which name species by different checklists, meet on
one accepted name.
"""
const WFO_RELEASE = "2026-06"

"""
    wfo_authority(; path = nothing)

Return the name authority species names are standardised through: the WFO Plant List release
[`WFO_RELEASE`](@ref), names WFO has not checked left out, and a name written alike for several
species taken as the one of them WFO accepts, where it accepts one.

  - `path`: where the release's file is kept, or `nothing` for EcoSISTEM's asset cache, which fetches
    it on first use.
"""
function wfo_authority(; path::Union{Nothing, AbstractString} = nothing)
    return WFOPlantList(release = WFO_RELEASE, prefer_accepted = true,
                        path = path)
end

# The mean of `values` weighted by `weights`, over the entries that have a value; `missing` where none
# does.
function _weightedmean(values::AbstractVector, weights::AbstractVector)
    known = [i for i in eachindex(values, weights) if !ismissing(values[i])]
    isempty(known) && return missing
    return sum(weights[i] * values[i] for i in known) /
           sum(weights[i] for i in known)
end

"""
    merge_envelopes(rows)

Return the envelope values of a species that several of the envelopes' names mean, as a named tuple:
`tmin`, `tp` and `ssr` each the mean over `rows` weighted by their `numrecords`, so that each is close
to the mean over the names' records taken together, and `numrecords` their sum.

  - `rows`: the envelopes' rows the names have, with `numrecords`, `tmin`, `tp` and `ssr`.
"""
function merge_envelopes(rows)
    n = rows.numrecords
    return (numrecords = sum(n), tmin = _weightedmean(rows.tmin, n),
            tp = _weightedmean(rows.tp, n), ssr = _weightedmean(rows.ssr, n))
end

"""
    merge_widths(rows)

Return the widths of a species that several of the records' names mean, as a named tuple: the
records each width rests on counted together (`tmin_n`, `tp_n`), and each width (`tmin_sd`,
`tp_sd`) the root mean square of the names' widths weighted by their records. The spread between the
names' own means is not in it, so it is no wider than the widest name's.

  - `rows`: the widths' rows the names have, with `tmin_n`, `tmin_sd`, `tp_n` and `tp_sd`.
"""
function merge_widths(rows)
    pooled(sd, n) = (w = _weightedmean(sd .^ 2, n); ismissing(w) ? w : sqrt(w))
    return (tmin_n = sum(rows.tmin_n),
            tmin_sd = pooled(rows.tmin_sd, rows.tmin_n),
            tp_n = sum(rows.tp_n), tp_sd = pooled(rows.tp_sd, rows.tp_n))
end

"""
    shrink_width(width, n, prior, strength)

Return the `width` across `n` records shrunk towards `prior`, which carries the weight of `strength`
further records: the two variances averaged by those weights. A width across few records is mostly
the prior, and one across many is mostly its own.
"""
function shrink_width(width::Real, n::Integer, prior::Real, strength::Real)
    return sqrt((n * width^2 + strength * prior^2) / (n + strength))
end

"""
    width_priors(widths, counts, taxonomy; records = PRIOR_RECORDS, members = PRIOR_MEMBERS)

Return the prior width of every species from its relatives, as a named tuple of the `prior` and the
`depth` of the level it came from. A species' prior is the median width of the well-recorded species
- those whose width rests on at least `records` records - in the first of its taxonomic groups to
hold at least `members` of them besides itself, its genus first; where none does, it is the median
over every well-recorded species, at a depth one past the last level.

  - `widths`: the width across each species' records, `missing` where it has too few.
  - `counts`: how many records each width rests on.
  - `taxonomy`: each species' groups from the narrowest outwards, such as `(genus, family, order)`,
    `missing` where one is not known.
"""
function width_priors(widths::AbstractVector, counts::AbstractVector{<:Integer},
                      taxonomy::AbstractVector{<:Tuple};
                      records::Integer = PRIOR_RECORDS,
                      members::Integer = PRIOR_MEMBERS)
    informed = [i
                for i in eachindex(widths)
                if !ismissing(widths[i]) && counts[i] >= records]
    # With nobody well recorded, every known width stands in, so that a small pool still has a prior.
    known = isempty(informed) ? findall(!ismissing, widths) : informed
    overall = median(Float64[widths[i] for i in known])
    depths = isempty(taxonomy) ? 0 : length(first(taxonomy))
    levels = [Dict{String, Vector{Int}}() for _ in 1:depths]
    for i in informed, (depth, name) in enumerate(taxonomy[i])
        ismissing(name) || push!(get!(levels[depth], name, Int[]), i)
    end
    prior = fill(overall, length(widths))
    depth = fill(depths + 1, length(widths))
    for i in eachindex(widths)
        for (d, name) in enumerate(taxonomy[i])
            ismissing(name) && continue
            others = Float64[widths[m]
                             for m in get(levels[d], name, Int[]) if m != i]
            length(others) >= members || continue
            prior[i] = median(others)
            depth[i] = d
            break
        end
    end
    return (prior = prior, depth = depth)
end

"""
    species_pool(envelopes, widths; strength = 12.0, authority = wfo_authority(),
                 provenance = EcoSISTEM.ProvenanceRecord[], verbosity = :normal)

Return the species a run simulates, as a named tuple of `pool`, a `SpeciesPool` of every species the
envelopes give a niche and the records found in Africa; `unmatched`, the records' names that mean no
species of the pool, which are left out; and `nowidth`, the species whose records give no width of
their own on one of the two tolerance axes, which are kept on their relatives' width.

Both tables' names are standardised through `authority`, so a species the envelopes and the records
name differently is one species, under its accepted name; several envelope rows meaning one species
are merged by [`merge_envelopes`](@ref), several width rows by [`merge_widths`](@ref). Each species
holds the envelope's `tmin` (K), `tp` (m/day) and `ssr` (J m^-2 per day), its records' widths
`tmin_sd` and `tp_sd` with the records each rests on, `tmin_n` and `tp_n`, its `genus`, `family` and
`order` as the authority classifies it, and the widths [`africa_species`](@ref) takes, `tmin_width`
and `tp_width`.

The width across a species' records says little when the records are few - it grows with their
number, and is zero for records from one place - so each width is shrunk towards that of the
species' well-recorded relatives by [`shrink_width`](@ref), the prior from [`width_priors`](@ref)
over genus, family and order. A species with too few records to have a width at all takes the prior
as it stands.

  - `envelopes`: the published envelopes, with `species`, `numrecords`, `tmin`, `tp` (m/day) and
    `ssr`.
  - `widths`: the widths across each name's records, with `species`, `tmin_sd` (K) and `tp_sd`
    (m/day), `missing` where a name has too few records, and the records each rests on, `tmin_n`
    and `tp_n`.
  - `strength`: how many records' weight the relatives' width carries against a species' own.
  - `authority`: the name authority both tables' names are standardised through, by default
    [`wfo_authority`](@ref).
  - `provenance`: the record of the envelopes' file, kept among the pool's inputs.
  - `verbosity`: how much the pool reports of the names it matched, as for `SpeciesPool`.
"""
function species_pool(envelopes::DataFrame, widths::DataFrame;
                      strength::Real = 12.0, authority = wfo_authority(),
                      provenance = EcoSISTEM.ProvenanceRecord[],
                      verbosity::Symbol = :normal)
    pool = SpeciesPool(select(envelopes, :species, :numrecords, :tmin, :tp,
                              :ssr), authority = authority,
                       merge = MergeWith(merge_envelopes),
                       provenance = provenance, verbosity = verbosity)
    add_trait!(pool, select(widths, :species, :tmin_n, :tmin_sd, :tp_n, :tp_sd),
               merge = MergeWith(merge_widths), verbosity = verbosity)
    # A species with no row among the widths was never recorded in Africa.
    remove_species!(pool, verbosity = verbosity) do row
        return ismissing(row.tmin_n)
    end
    for rank in ("genus", "family", "order")
        add_trait!(pool, Symbol(rank)) do row
            return EcoSISTEM.lineage(authority, row.id, rank)
        end
    end
    table = pool.species
    taxonomy = collect(zip(table.genus, table.family, table.order))
    for (width, count, shrunk) in ((:tmin_sd, :tmin_n, :tmin_width),
        (:tp_sd, :tp_n, :tp_width))
        own, n = table[!, width], Int.(table[!, count])
        priors = width_priors(own, n, taxonomy)
        value = Dict(s => ismissing(w) ? p : shrink_width(w, c, p, strength)
                     for (s, w, c, p) in zip(table.name, own, n, priors.prior))
        add_trait!(pool, shrunk) do row
            return value[row.name]
        end
    end
    table = pool.species
    nowidth = sort(table.name[ismissing.(table.tmin_sd) .| ismissing.(table.tp_sd)])
    simulated = Set(table.name)
    matched = name_table(pool)
    recorded = Set(widths.species)
    unmatched = sort(unique(row.name
                            for row in eachrow(matched)
                            if row.name in recorded &&
                         (ismissing(row.species) ||
                          !(row.species in simulated))))
    return (pool = pool, unmatched = unmatched, nowidth = nowidth)
end

"""
    scaled_pool(pool)

Return `pool` with only the species a run at the scale `AFRICA_SCALE` names, the others removed: a
small run keeps the most-recorded species, which fill a coarse grid quickly, and a medium run keeps
species at even steps down the ranking by record count, so that it holds the rarely recorded in the
proportion the whole pool does; a large run keeps them all. A species' records are counted as the
records its temperature width rests on, `tmin_n`.

  - `pool`: a pool from [`species_pool`](@ref), changed in place.
"""
function scaled_pool(pool::SpeciesPool)
    (smallscale() || mediumscale()) || return pool
    table = pool.species
    # By record count and then by name, so that the choice does not turn on the order of ties.
    ranked = table.name[sortperm(collect(zip(-table.tmin_n, table.name)))]
    keep = smallscale() ? first(ranked, SCALED_SPECIES.small) :
           ranked[round.(Int,
                         range(1, length(ranked),
                               length = min(SCALED_SPECIES.medium,
                                            length(ranked))))]
    chosen = Set(keep)
    length(chosen) == length(ranked) && return pool
    remove_species!(pool, verbosity = :silent) do row
        return !(row.name in chosen)
    end
    return pool
end

"""
    accepted_names(pool, names)

Return the name of the species of `pool` each of `names` means, through the pool's name authority,
or `missing` for a name that means none of them: how occurrence records, named by their own
checklist, are matched to the species a run simulates.

  - `pool`: the species, a `SpeciesPool` with a name authority.
  - `names`: the names, `missing` allowed.
"""
function accepted_names(pool::SpeciesPool, names::AbstractVector)
    simulated = Set(pool.species.name)
    found = Dict{String, Union{Missing, String}}()
    return map(names) do name
        ismissing(name) && return missing
        return get!(found, name) do
            means = EcoSISTEM.resolve_name(pool.authority, name)
            return isnothing(means.name) || !(means.name in simulated) ?
                   missing : means.name
        end
    end
end

"""
    envelopes_record(path)

Return the [`ProvenanceRecord`](@ref) of the published climate envelopes at `path`, for a run's
provenance: the record `data/src/envelopes.jl` writes beside them, naming the dataset by its DOI
and the paper it was made for as its deposit, cited apart. Where there is none, one is written from
the dataset's DOI alone, which needs the network and names no paper.
"""
function envelopes_record(path::AbstractString)
    return EcoSISTEM.Provenancer.record_provenance(path, ENVELOPES_DOI,
                                                   role = :species)
end

"""
    africa_species(pool; density = 1.0 / m^2, water = nothing, survival = 0.2, seed = 1,
                   provenance = EcoSISTEM.ProvenanceRecord[], verbosity = :normal)

Build the [`SpeciesList`](@ref) of the species in `pool`, the `pool` of [`species_pool`](@ref), under
their accepted names. Where their individuals start is the placement the ecosystem is built with.

Each species is matched to temperature and precipitation by a Gaussian tolerance of the pool's mean
and shrunk width, and demands three resources per individual: `1 / density` of ground, its own mean
net solar radiation over that ground, and the rain falling on it at a rate that is the same for every
species. A common demand makes water limit how many plants a place holds without favouring one
species over another, which the precipitation tolerance already does. Birth and death are 0.15 a
year, longevity 1, and only the newly born disperse, by a Gaussian kernel whose mean distance each
species draws uniformly from 0.6 to 2.4 km; a seed aimed at a cell that is not simulated is
redistributed rather than lost.

# Arguments

  - `pool`: the species, as [`species_pool`](@ref) returns them.
  - `density`: plants per unit of available ground, which sets the area each individual occupies.
  - `water`: the rainfall each individual demands over the ground it occupies, as a depth a day;
    `nothing` takes the median of the pool's precipitation optima, the rain a typical species is
    found under, so that a cell holds its full complement of plants only where it is at least that
    wet.
  - `survival`: how strongly a poor niche fit raises deaths and lowers births.
  - `seed`: seeds the dispersal distances, each species' from a stream of its own, and the
    species' own random streams.
  - `provenance`: the records of anything the species were built from that the pool does not record.
  - `verbosity`: how much the build reports of the values it read and filled, as for
    `build_species`.
"""
function africa_species(pool::SpeciesPool;
                        density::Unitful.Quantity = 1.0 / m^2,
                        water::Union{Nothing, Unitful.Quantity} = nothing,
                        survival::Real = 0.2, seed::Integer = 1,
                        provenance = EcoSISTEM.ProvenanceRecord[],
                        verbosity::Symbol = :normal)
    area = uconvert(m^2, 1 / density)
    rate = m / Unitful.d
    rain = isnothing(water) ? median(pool.species.tp) * rate : water
    temperature = ToleranceSpec(AnnualMinimumTemperature,
                                μ = TraitColumn(:tmin, unit = K),
                                σ = TraitColumn(:tmin_width, unit = K))
    rainfall = ToleranceSpec(AnnualMeanPrecipitation,
                             μ = TraitColumn(:tp, unit = rate),
                             σ = TraitColumn(:tp_width, unit = rate))
    light = DemandSpec(SolarRadiation,
                       row -> row.ssr * (J / m^2) / Unitful.d * area)
    drink = DemandSpec(Precipitation,
                       uconvert(Unitful.L / Unitful.d, rain * area))
    dispersal = MovementSpec(SeedDispersal(GaussianKernel,
                                           disperse_safely = true),
                             meandist = DrawFrom(Uniform(0.6, 2.4), unit = km))
    return build_species(pool,
                         tolerance = (temperature = temperature,
                                      rainfall = rainfall),
                         demand = (space = DemandSpec(SurfaceArea, area),
                                   light = light, water = drink),
                         movement = dispersal, birth = 0.15 / year,
                         death = 0.15 / year, longevity = 1.0,
                         survival = survival, seed = seed,
                         provenance = provenance, verbosity = verbosity)
end
