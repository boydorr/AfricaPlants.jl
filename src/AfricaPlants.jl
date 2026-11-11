# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Simulating the plant species of Africa with EcoSISTEM: case study 2 of the EcoSISTEM paper,
# rebuilt on the current package. The module holds what every run shares - the configuration
# read from the environment, the continent as a study area, and the choice of a resolution the
# machine can afford. The paper's experiment scripts under `examples/paper/` drive it.

module AfricaPlants

using EcoSISTEM
using RasterDataSources: EarthEnv, LandCover
using EcoSISTEM.Units
using Unitful
using Unitful.DefaultSymbols
using Rasters: EPSG
using MPI
using CSV
using DataFrames
using Distributions: Uniform
using Dates: Dates
using Diversity: Diversity
using Statistics: mean, median
using DimensionalData: DimensionalData
using NCDatasets: NCDatasets

# EcoSISTEM's memory guidance for large runs, shared with its HPC scripts rather than copied.
# It is an example file of that package, not its API, so the path is pinned by the EcoSISTEM
# commit this package depends on.
include(joinpath(pkgdir(EcoSISTEM), "examples", "HPC", "memory.jl"))

include("config.jl")
include("area.jl")
include("axes.jl")
include("landscape.jl")
include("species.jl")
include("seeding.jl")
include("run.jl")

export smallscale, mediumscale, SCALED_SPECIES, requested_cellsize,
       africa_within, AFRICA_CRS,
       CANDIDATE_CELLSIZES,
       perspecies_bytes, choose_cellsize, africa_area,
       AVAILABLE_CLASSES, CLIMATE_LAYERS, era5_dir, era5_last_month,
       available_ground,
       africa_layers,
       AbstractClimateTiming, ForwardClimate, ReversedClimate, HeldClimatology,
       FIRST_FULL_YEAR, HELD_DECADE,
       AbstractRegimeStatistic, MonthlyValue, TrailingMinimum, TrailingMean,
       AnnualMinimumTemperature, AnnualMeanPrecipitation,
       ENVELOPES_DOI, PRIOR_RECORDS, PRIOR_MEMBERS, WFO_RELEASE, shrink_width,
       width_priors, wfo_authority, merge_envelopes,
       species_pool, scaled_pool, envelopes_record,
       africa_species,
       MIN_EVI_MONTHS, seeding_layer, months_back, scale_to_total,
       positioning_layers, africa_ecosystem, gbif_record,
       DIVERSITY_ORDERS, METACOMMUNITY_MEASURES, record_diversity

end
