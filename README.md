# AfricaPlants

[![CI](https://github.com/boydorr/AfricaPlants.jl/actions/workflows/testing.yaml/badge.svg?branch=main)](https://github.com/boydorr/AfricaPlants.jl/actions/workflows/testing.yaml)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.24183323.svg)](https://doi.org/10.5281/zenodo.24183323)

The code behind the second case study of the [EcoSISTEM paper](https://arxiv.org/abs/1911.12257),
*"EcoSISTEM: simulating species-rich plant biodiversity over large scales in Julia"* (Harris, Brummitt,
Cobbold and Reeve). It simulates the plant species recorded in Africa, about 45,800 of them, competing for
ground, sunlight and rainfall across the continent. The grid is 50 km cells on an equal-area projection
(EPSG:10592), and the climate is ERA5 reanalysis from 1941 to 2025. It is a small Julia package on
[EcoSISTEM](https://github.com/EcoJulia/EcoSISTEM.jl), with the scripts that run the experiment and draw its
figures.

The model draws on:

- plant occurrence records from the Global Biodiversity Information Facility ([GBIF](https://www.gbif.org)),
  named by the [WFO Plant List](https://doi.org/10.5281/zenodo.20782718);
- each species' climate envelope, from [Bioclimatic envelopes for global plant
  species](https://doi.org/10.5285/ca339c86-3674-4030-b891-35326e71141e), described in [Harris et al.
  (2022)](https://doi.org/10.1111/geb.13564);
- [ERA5](https://doi.org/10.24381/cds.f17050d7) monthly means from the European Centre for Medium-Range
  Weather Forecasts ([ECMWF](https://www.ecmwf.int));
- the vegetation index of [MODIS](https://doi.org/10.5067/MODIS/MOD13C2.061), which weighs each record as it
  seeds the landscape;
- [EarthEnv](https://www.earthenv.org/landcover)'s land cover and [Natural
  Earth](https://www.naturalearthdata.com)'s outline of Africa.

## Running the case study

It needs Julia 1.11 or later. Everything runs in one environment, `examples/paper/`. From the root of the
repository:

```sh
julia --project=examples/paper -e 'using Pkg; Pkg.instantiate()'
```

1. **The data.** [`data/src/README.md`](data/src/README.md) lists every input, the order to fetch and
   prepare them in, and the accounts the downloads need: a Copernicus Climate Data Store key for ERA5, a
   GBIF account and a NASA Earthdata token. The climate envelopes are downloaded by hand from the EIDC into
   `data/plant_trait/`. Everything goes under `data/`, which git ignores.
2. **A trial at small scale**, 200 species and a few months, in minutes:

   ```sh
   AFRICA_SCALE=small julia -t 4 --project=examples/paper examples/paper.jl
   ```

   `AFRICA_SCALE=medium` runs 3,000 species over the whole span: the three stages below take about an hour
   on eight threads.
3. **The full experiment.** A replicate is three stages sharing one `AFRICA_SEED`:
   - the backwards burn-in and the years that settle it, `examples/paper/burnin.jl`;
   - the forward run through the climate, `examples/paper/forward.jl`;
   - its control under the 1941-1950 average year held, `forward.jl` again with `AFRICA_NEUTRAL=true`.

   [`examples/paper.jl`](examples/paper.jl) runs the first two in one process on threads, and
   [`examples/mpi.jl`](examples/mpi.jl) across MPI ranks. At full scale a stage holds tens of gigabytes for
   many hours, so the paper's runs are made one stage a job on an HPC:
   [`examples/paper/hpc/README.md`](examples/paper/hpc/README.md) sets them up and submits them.

Each script's header lists the settings it reads from the environment. The ones most runs use:

| variable          | meaning                                                                            |
| ----------------- | ---------------------------------------------------------------------------------- |
| `AFRICA_SCALE`    | `small` or `medium` for a trial; unset for the full experiment                     |
| `AFRICA_CELLSIZE` | the grid, `50km` for the paper's runs                                              |
| `AFRICA_SEED`     | the replicate, `1` by default                                                      |
| `AFRICA_NEUTRAL`  | `true` for the control                                                             |
| `AFRICA_SAVEDIR`  | where the runs write, and the figures read; `./Africa_run` by default              |

## Building the paper's figures

The figure scripts read what the runs wrote in `AFRICA_SAVEDIR` and write their figures beside it. They
average over every replicate they find there.

```sh
julia --project=examples/paper examples/paper/plots.jl      # richness.pdf, abundance.pdf, climate_effect.pdf
julia --project=examples/paper examples/paper/series.jl     # timeseries.pdf
julia --project=examples/paper examples/paper/recorded.jl   # recorded.pdf
```

- [`plots.jl`](examples/paper/plots.jl) draws `richness.pdf`, the paper's map of species richness
  (`AfricaChangeNew` in its source). With controls present it also draws `abundance.pdf` and
  `climate_effect.pdf`, the individuals each cell holds with and without the changing climate.
- [`series.jl`](examples/paper/series.jl) draws `timeseries.pdf`, the paper's time series of the whole
  landscape against its control (`ClimateAbun` in its source), for the replicate `AFRICA_SEED` names.
- [`recorded.jl`](examples/paper/recorded.jl) draws `recorded.pdf`, the species each cell ends with against
  those ever recorded in it.

The maps need the forward runs, and the controls for the abundance maps. The time series needs the yearly
`diversity_*.csv` of one replicate, and `recorded.pdf` the `recorded_richness.csv` the burn-in writes.

## Through the FAIR data pipeline

Every step also runs as a [FAIR data pipeline](https://www.fairdatapipeline.org) run, which registers each
input and output with its provenance, so that every figure can be traced back to its sources. Run plainly,
nothing is registered, and the files are the same. The `fair` command is FAIR-CLI's, which
`DataPipeline.install_cli!()` installs.

- The data: fetch and preparation runs, one config each in `data/src/`, as
  [`data/src/README.md`](data/src/README.md) describes.
- The stages: [`examples/paper/pipeline.jl`](examples/paper/pipeline.jl) with `burnin.yaml` and
  `forward.yaml`, which read every input from the registry.
- The figures: `examples/paper/figures.yaml`, drawn from every replicate the registry holds.

```sh
fair pull --local examples/paper/figures.yaml && fair run examples/paper/figures.yaml
```

[`examples/paper/hpc/README.md`](examples/paper/hpc/README.md) gives the order on an HPC.

## Tests

```sh
julia --project -e 'using Pkg; Pkg.test()'                                  # the smoke test
julia --project -e 'using Pkg; Pkg.test(test_args = ["canonical"])'         # the blessing test
```

The smoke test runs a small synthetic pool on the real grid for a year. The blessing test runs one
replicate's small-scale chain on the real data and checks every yearly total and diversity against the
values in `test/canonical/reference.toml`; it skips itself where the data is absent.

## Layout

| path              | what                                                                                |
| ----------------- | ----------------------------------------------------------------------------------- |
| `src/`            | the package: the study area, the layers, the species pool, the seeding, the runs     |
| `examples/paper/` | the paper's stages, its figure scripts, their pipeline configs and the HPC jobs     |
| `data/src/`       | the scripts and configs that fetch and prepare the data                              |
| `test/`           | the smoke test, and the blessing test in `test/canonical/`                          |

## Licence

LGPL-3.0-or-later. The data each source provides carries its own licence, which its provenance record
names.
