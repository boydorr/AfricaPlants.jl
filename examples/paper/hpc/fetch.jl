# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Fetch what a run downloads for itself rather than reads from `data/` - EarthEnv's land cover, which
# gives the available ground, Natural Earth's outline of Africa, and the WFO Plant List release species
# names are standardised through - into EcoSISTEM's asset cache in the depot. `setup.bash` runs it on
# a compute node; where that node cannot reach them, run it on a login node, then submit
# `setup.bash` again:
#
#     source examples/paper/hpc/env.sh
#     julia --project=examples/paper examples/paper/hpc/fetch.jl

using AfricaPlants
using EcoSISTEM

files = EcoSISTEM.fetchfiles((positioning_layers().supply, africa_within()))
println("Fetched or already held: ", length(files), " files")
# The release is fetched the first time a name is resolved through it.
EcoSISTEM.resolve_name(wfo_authority(), "Acacia senegal")
println("WFO Plant List ", WFO_RELEASE, " held")
