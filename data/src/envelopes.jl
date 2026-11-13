# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Record where the published climate envelopes came from, in the provenance sidecar beside the
# table: the dataset by its DOI, and the paper it was made for as its deposit, cited apart, both
# from the metadata their DOIs resolve to, so that a run's account cites the two. The table is the
# EIDC's, downloaded by hand and unpacked into `plant_trait/`; its sidecar is tracked, so a run
# reads it (`envelopes_record`) and looks nothing up.
#
#     julia --project data/src/envelopes.jl [--force] [path]
#
# `path` is the table, by default `AFRICA_ENVELOPES` or `plant_trait/data/` in the data directory.
# A table recorded already is left as it is; `--force` records it afresh. Launched by `fair run` from
# `fetch-envelopes.yaml`, it also registers the table and its record under `envelopes`.

module Envelopes

using AfricaPlants: ENVELOPES_DOI, ENVELOPES_PAPER_DOI, envelopes_record
using EcoSISTEM.Provenancer: SourceFacts, DepositCitedApart, lookup_doi,
                             record_provenance, sidecarpath

include("common.jl")

"""
    envelopes_facts()

Return what is known of the published climate envelopes, from the metadata their DOI resolves to,
with the paper they were made for, from its own DOI's, as the deposit cited apart.
"""
function envelopes_facts()
    return SourceFacts(lookup_doi(ENVELOPES_DOI),
                       deposit = DepositCitedApart(lookup_doi(ENVELOPES_PAPER_DOI)))
end

function main(argv)
    given = filter(a -> !startswith(a, "--"), argv)
    path = isempty(given) ?
           get(ENV, "AFRICA_ENVELOPES",
               joinpath(datadir(), "plant_trait", "data",
                        "global_plant_climate_envelopes.csv")) : only(given)
    forced(argv) && rm(sidecarpath(path), force = true)
    # A table recorded already is read back, with nothing looked up.
    record = isfile(sidecarpath(path)) ? envelopes_record(path) :
             record_provenance(path, envelopes_facts(), role = :species)
    show(stdout, MIME"text/plain"(), record)
    println()
    pipeline_register([path], :envelopes)
    return record
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    Envelopes.main(ARGS)
end
