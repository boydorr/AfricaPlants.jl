# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The provenance of the tables this package's data scripts make from their sources: the facts each
# table's record is written from, where a run finds the record, and the names a data pipeline files
# the table and its record under.

"""
    TABLES

The tables the data scripts make that a run or another script reads, by the name each is known by
here: the cleaned GBIF records (`:records`), those in Africa with their WFO species
(`:records_africa`), the niche widths per WFO species (`:species_widths`), the mean EVI
(`:evi_mean`), its reliable cells over the Africa box (`:evi_reliable`), and the hold-out
experiment's scores (`:width_holdout`). Each value is the table's `title`, the data `role` its
record gives it, its `licence`, its `stem` in the data pipeline's names and the works its record
cites, by DOI.
"""
const TABLES = (records = (title = "Cleaned GBIF plant records over the Africa box",
                           role = :abundance, licence = "cc-by-nc-4.0",
                           stem = "Records",
                           cites = ["10.15468/dl.n4a2sa"]),
                records_africa = (title = "Plant records within Africa's outline, each with its WFO species",
                                  role = :abundance, licence = "cc-by-nc-4.0",
                                  stem = "RecordsAfrica",
                                  cites = ["10.15468/dl.n4a2sa",
                                      "10.5281/zenodo.20782718",
                                      "10.1002/joc.5086"]),
                species_widths = (title = "Niche widths of the plant species recorded in Africa",
                                  role = :species, licence = "cc-by-nc-4.0",
                                  stem = "SpeciesWidths",
                                  cites = ["10.15468/dl.n4a2sa",
                                      "10.5281/zenodo.20782718",
                                      "10.24381/cds.f17050d7"]),
                evi_mean = (title = "Mean MODIS EVI of good and marginal months, 2001 to 2025",
                            role = :abundance, licence = nothing,
                            stem = "EVIMean",
                            cites = ["10.5067/MODIS/MOD13C2.061"]),
                evi_reliable = (title = "Mean MODIS EVI over the Africa box where it rests on enough months",
                                role = :abundance, licence = nothing,
                                stem = "EVIReliable",
                                cites = ["10.5067/MODIS/MOD13C2.061"]),
                width_holdout = (title = "Scores of niche width rules against species cut down to few records",
                                 role = :species, licence = "cc-by-nc-4.0",
                                 stem = "WidthHoldout",
                                 cites = ["10.15468/dl.n4a2sa",
                                     "10.24381/cds.f17050d7"]))

"""
    table_facts(table)

Return the [`SourceFacts`](@ref EcoSISTEM.Provenancer.SourceFacts) a record of the table named
`table`, one of [`TABLES`](@ref), is written from: this package as its source, under a citation key
of its own in the `AfricaPlants` namespace, citing the works the table was made from.

  - `table`: the table's name, a key of `TABLES`.
"""
function table_facts(table::Symbol)
    t = TABLES[table]
    return EcoSISTEM.Provenancer.SourceFacts(source = "AfricaPlants $table",
                                             title = t.title,
                                             url = "https://github.com/boydorr/AfricaPlants.jl",
                                             licence = t.licence,
                                             identifies = :data,
                                             key = "AfricaPlants_$table",
                                             namespace = "AfricaPlants",
                                             references = [(doi = d, text = "")
                                                           for d in t.cites])
end

"""
    table_root(table)

Return the root a data pipeline files the table named `table` under, in the `AfricaPlants`
namespace: `CaseStudy/Data/<Stem>`, the table being `<root>/data/<file stem>` and its record
`<root>/provenance/<file stem>`, as EcoSISTEM's `Track` names them.

  - `table`: the table's name, a key of [`TABLES`](@ref).
"""
table_root(table::Symbol) = "CaseStudy/Data/" * TABLES[table].stem

"""
    table_sidecar(path)

Return where the record of the table at `path` is kept: beside it as `<file>.record.toml`, since
`<file>.provenance.toml` is the data script's own sidecar.

  - `path`: the table.
"""
table_sidecar(path::AbstractString) = path * ".record.toml"

"""
    table_record(path, table; handle = nothing)

Return the [`ProvenanceRecord`](@ref) of the table named `table` at `path`, writing it at
[`table_sidecar`](@ref) the first time from [`table_facts`](@ref) and the file itself, its size and
checksum. Given the `handle` of a data pipeline run that reads the table, the run's copy of the table
and its record are first put in place at `path` from the run's store.

  - `path`: the table, which must be there unless a run puts it there.
  - `table`: its name, a key of [`TABLES`](@ref).
  - `handle`: the data pipeline run reading it, or `nothing`, the default, for none.
"""
function table_record(path::AbstractString, table::Symbol; handle = nothing)
    return EcoSISTEM.Provenancer.record_provenance(path, table_facts(table),
                                                   role = TABLES[table].role,
                                                   route = EcoSISTEM.Provenancer.OtherOrigin(),
                                                   sidecar = table_sidecar(path),
                                                   track = EcoSISTEM.Track(handle,
                                                                           table_root(table)))
end

"""
    SOURCE_ROOTS

The root each source's files are filed under in a data pipeline, by the name the source is known by
here. EcoSISTEM's `Track` files a file as `<root>/data/<stem>` and its record as
`<root>/provenance/<stem>`. The run's config gives the namespace, which is the source's own, such as
`ECMWF` for ERA5.
"""
const SOURCE_ROOTS = (era5 = "era5", earthenv = "earthenv",
                      naturalearth = "naturalearth", wfo = "wfo",
                      envelopes = "envelopes", worldclim = "worldclim",
                      gbif = "gbif", modis = "modis", centroids = "centroids",
                      gardens = "gardens")

"""
    source_track(handle, source)

Return the `Track` that files the source named `source`, a key of [`SOURCE_ROOTS`](@ref), through the
data pipeline run `handle`; with a `handle` of `nothing` it tracks nothing, so whatever takes it
reads its files as it would without a pipeline.

  - `handle`: the run, or `nothing`.
  - `source`: the source's name.
"""
function source_track(handle, source::Symbol)
    return EcoSISTEM.Track(handle,
                           SOURCE_ROOTS[source])
end

"""
    provide_file(handle, source, path; sidecar = EcoSISTEM.Provenancer.sidecarpath(path))

Return `path`, where the data pipeline run `handle` has first put its copy of the source's file and
of EcoSISTEM's record of it at `sidecar`, from its store. They are `<root>/data/<stem>` and
`<root>/provenance/<stem>`, as EcoSISTEM's `Track` names them, the root the source's in
[`SOURCE_ROOTS`](@ref) and the stem the file's name without its extension. A file there already
must have the same bytes; a record there is replaced. With a `handle` of `nothing`, return `path`
as it is.

  - `handle`: the run, or `nothing`.
  - `source`: the source's name, a key of `SOURCE_ROOTS`.
  - `path`: where the file goes.
  - `sidecar`: where its record goes.
"""
function provide_file(handle, source::Symbol, path::AbstractString;
                      sidecar::AbstractString = EcoSISTEM.Provenancer.sidecarpath(path))
    isnothing(handle) && return path
    root = SOURCE_ROOTS[source]
    stem = first(splitext(basename(path)))
    DataPipeline.link_read!(handle, "$root/data/$stem", path = path)
    DataPipeline.link_read!(handle, "$root/provenance/$stem", path = sidecar,
                            force = true)
    return path
end

"""
    provide_files(handle, source, dir; sidecar = EcoSISTEM.Provenancer.sidecarpath)

Return `dir`, where the data pipeline run `handle` has first put every file of the source its
config reads, each with EcoSISTEM's record of it, as [`provide_file`](@ref) puts one: so a script
that reads a whole directory, as ERA5's monthly files are read, finds them there. The run's config
reads them as `<root>/data/*` and `<root>/provenance/*`. With a `handle` of `nothing`, return `dir`
as it is.

  - `handle`: the run, or `nothing`.
  - `source`: the source's name, a key of [`SOURCE_ROOTS`](@ref).
  - `dir`: where the files go.
  - `sidecar`: where a file's record goes, given the file's path.
"""
function provide_files(handle, source::Symbol, dir::AbstractString;
                       sidecar::Function = EcoSISTEM.Provenancer.sidecarpath)
    isnothing(handle) && return dir
    root = SOURCE_ROOTS[source]
    # A pattern gives a directory of links, each named after its data product with `/` as `_`,
    # which is how the files' own names are found.
    linked = DataPipeline.link_read!(handle, "$root/data/*")
    prefix = replace(root, "/" => "_") * "_data_"
    for link in readdir(linked)
        path = joinpath(dir, chopprefix(link, prefix))
        provide_file(handle, source, path, sidecar = sidecar(path))
    end
    return dir
end
