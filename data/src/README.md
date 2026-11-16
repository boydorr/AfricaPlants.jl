# Data acquisition and preparation

Scripts that fetch and prepare every input the Africa runs need. They write under `data/`
(gitignored, or the directory named by `AFRICA_DATADIR`), and beside each output a
`*.provenance.toml` saying where it came from, when, and how big it is. EcoSISTEM writes those
records for the ERA5 and 20CRv3 downloads, which go through its `fetchfiles`, and for the GBIF
downloads and the climate envelopes, from the metadata their DOIs resolve to, so that a run's
account of its inputs carries them; the other scripts write their own. Each script is idempotent: a file already present is not fetched again, and a
table already built is rebuilt only with `--force`. Nothing in `data/` but these scripts is tracked:
each record is written with its file, and a pipeline run registers both.

Run them from the repository root in this order. Nothing here is run by the test suite except
the pure functions, which `test/runtests.jl` exercises on fabricated inputs.

| step | script | needs | writes |
| --- | --- | --- | --- |
| 1 | `era5_download.jl` | a CDS account: `~/.cdsapirc`, read by CDSAPI.jl | `era5/era5_<var>_<decade>s.nc`, one variable per decade file; a decade not yet complete is `era5_<var>_<first>-<last>.nc`; with `--through=<year>-<month>`, that year's months are `era5_<var>_<year>-<year>_m01-<month>.nc`, refused if any month is preliminary ERA5T |
| 1b | `twentycr_download.jl` | nothing: NOAA PSL serves 20CRv3 over plain HTTPS | `twentycr/SI-MO/`, five global monthly files spanning 1806 to 2015 (2 m temperature, precipitation rate, downward and upward shortwave, soil moisture by layer), for the extension before 1940 |
| 1c | `evi_download.jl` | a NASA Earthdata token: `EARTHDATA_TOKEN` in the environment, or `~/.earthdata_token` | `evi/MOD13C2.A<year><day>.061.<production>.hdf`, the MODIS/Terra monthly vegetation index files for 2001 to 2025, one per month, global at 0.05 degrees |
| 1d | `evi_mean.jl` | the MOD13C2 files | `evi/evi_mean_2001_2025.nc`: the mean EVI of good and marginal months at each cell, the stand-in for how many plants a cell holds: collection effort is records over EVI, so a record in a greener or less sampled cell seeds more individuals |
| 1e | `evi_reliable.jl` | the mean EVI layer | `evi/evi_reliable_2001_2025.tif`: over the Africa box at 0.05 degrees, each cell's mean EVI, missing below 36 good months, as a GeoTIFF the runs read as a layer; each record's seeding weight is its cell's EVI times land area, shared among the records made there |
| 2 | `inventory.jl` | the netCDF files | `inventory.csv`: every file's variables, unit strings, time axis, lattice |
| 3 | `gbif_download.jl` | nothing for the two downloads made already, fetched by their DOIs; a GBIF account for a new request (`--force`): `GBIF_USER`, `GBIF_PWD`, `GBIF_EMAIL` in the environment, or `user`, `pwd`, `email` in `~/.gbifrc` | two downloads, `gbif/era5/<key>.csv` (1940 onward, the ERA5 years) and `gbif/early/<key>.csv` (1806-1939, the years only 20CRv3 reaches), each with its DOI in its provenance |
| 3b | `centroids.jl` | nothing: GBIF's Catalogue of Centroids on GitHub, at a pinned commit | `centroids.csv`: country centroids, which `gbif_clean.jl` drops records near |
| 3c | `gardens.jl` | nothing: CoordinateCleaner's institutions gazetteer on GitHub, at a pinned commit | `gardens.csv`: botanic gardens, which `gbif_clean.jl` flags records near |
| 3d | `envelopes.jl` | the EIDC's climate envelopes, downloaded by hand and unpacked into `plant_trait/` | `plant_trait/data/global_plant_climate_envelopes.csv.provenance.toml`, the table's record, naming the dataset and the paper it was made for from their DOIs, so that a run looks nothing up |
| 4 | `gbif_clean.jl` | the GBIF CSVs | `records.csv` from the `era5` download and `records_early.csv` from `early`: one row per usable record, cleaned, with three flag columns |
| 5 | `species_traits.jl` | `records.csv`, a cached WorldClim layer to place the continent outline, the WFO Plant List release `AfricaPlants` names | `records_africa.csv`, the records the model seeds from, each with the WFO species its name means |
| 6 | `species_widths.jl` | `records_africa.csv`, the ERA5 `t2m` and `tp` files | `species_widths.csv`: per WFO species, the spread across its records of the twelve-month minimum temperature (records on the quarter-degree lattice left out) and mean precipitation (also records near or naming a botanic garden), missing below two records |

```sh
julia --project data/src/era5_download.jl    # hours, queued at the CDS; resumable; --dry-run lists
julia --project data/src/twentycr_download.jl # about 2 GB, no credentials; extension only
julia --project data/src/evi_download.jl     # about 29 GB, an Earthdata token; resumable
julia --project data/src/evi_mean.jl
julia --project data/src/evi_reliable.jl
julia --project data/src/inventory.jl
julia --project data/src/gbif_download.jl    # both downloads, by their DOIs; --force requests them afresh
julia --project data/src/centroids.jl
julia --project data/src/gardens.jl
julia --project data/src/envelopes.jl
julia --project data/src/gbif_clean.jl       # every download present; or name one
julia --project data/src/species_traits.jl
julia --project -t auto data/src/species_widths.jl
```

## Through the data pipeline

Every script also runs as a FAIR data pipeline run, and the paper's inputs are made that way. Run
plainly, a script registers nothing. Launched by `fair"run <config>"`, it takes the run's handle, reads its
inputs from the registry, and registers what it fetched or made. The files land where the plain
script puts them, so the two routes give the same files.

A fetch run registers one source: each of its files, with EcoSISTEM's provenance record of the file,
in the source's own namespace. The source's deposit is the run's one input. There is a config for
each source, `fetch-<source>.yaml`. `fetch.jl <source>` fetches the files EcoSISTEM keeps in its
asset cache: the WFO release, Natural Earth's outlines, WorldClim's annual mean temperature and
EarthEnv's land cover. Only the HPC's runs read EarthEnv, so its fetch run is made there. The MODIS
files and the centroids and gardens tables keep their own sidecar as `.provenance.toml`, so
EcoSISTEM's record of each is `<file>.record.toml`. A fetch run with everything registered already
stops before a code run exists.

A preparation run makes one table: `prepare-<step>.yaml` reads each input to where the plain script
reads it, rebuilds the table with `--force`, and registers it and its record as
`AfricaPlants:CaseStudy/Data/<Stem>/data/<file stem>` and `.../provenance/<file stem>`.

### Setting up a clone

The paper's inputs are made in a clean clone of a release. A pipeline run records the commit it
ran, and refuses a checkout with uncommitted changes. From a shell:

```sh
git clone https://github.com/boydorr/AfricaPlants.jl AfricaPlants
cd AfricaPlants
git checkout v0.3.1
julia --project -e 'using Pkg; Pkg.instantiate()'
```

Everything after that runs in Julia, started with `julia --project` in the root of the clone.
DataPipeline's `fair"..."` runs FAIR-CLI's `fair` command, which need not be on the path. Some steps
are needed once on each machine, one once in each clone, and the registry is started in each
session:

```julia
using DataPipeline
DataPipeline.install_cli!()   # once on each machine: `fair` 0.12.0 or later
fair"registry install"        # once on each machine, unless it has a local registry already
fair"registry start"          # in each session; fair"registry stop" at the end
fair"init"                    # once in each clone
```

`fair"init"` asks for what it needs: the remote registry, `https://data.fairdatapipeline.org/api/`;
a file holding your token for it, from your account there; who you are; and default namespaces,
which every config here sets for itself. `fair"init --using <file>"` takes the answers from a CLI
configuration file instead.

### What a clone needs first

Nothing in `data/` is tracked, so a new clone has none of it. **The envelopes must be put there by
hand**: download the EIDC's deposit and unpack it into `data/plant_trait/` (step 3d above). The
other fetch runs fetch what is missing: ERA5 with a CDS account, which takes hours; the MODIS files
with an Earthdata token, 29 GB; and the GBIF download by its DOI, about 10 GB.

Where another clone holds these already, copy each download with its `.provenance.toml` rather than
fetch it again. The record says when those bytes were fetched, so it stays true. On macOS, `cp -c`
makes each copy an APFS clone, which takes no space; drop the `-c` elsewhere:

```sh
src=<the other clone>/data
cp -cR $src/plant_trait data/
cp -cR $src/era5 data/
mkdir -p data/evi && cp -c $src/evi/MOD13C2.* data/evi/
mkdir -p data/gbif && cp -cR $src/gbif/era5 data/gbif/
```

Nothing else needs copying. The centroids and gardens come from pinned commits on GitHub, and WFO,
Natural Earth and WorldClim from EcoSISTEM's cache, which `fetch.jl` fills. The tables made from
the downloads are rebuilt by the preparation runs.

### The runs

Each run is `fair"pull --local <config>"`, which registers the config's namespace, then
`fair"run <config>"`. The ERA5 config names the last month of final ERA5 the runs use. `fair"..."`
throws if the command fails, so each loop stops at the first failure:

```julia
for source in ["envelopes", "centroids", "gardens", "wfo", "naturalearth", "worldclim", "era5", "gbif", "modis"]
    println("Pulling from $source")
    fair"pull --local data/src/fetch-$source.yaml"
    fair"run data/src/fetch-$source.yaml"
end
for step in ["clean", "africa", "widths", "evimean", "evireliable", "holdout"]
    println("Preparing $step")
    fair"pull --local data/src/prepare-$step.yaml"
    fair"run data/src/prepare-$step.yaml"
end
```

The `africa`, `widths` and `holdout` runs take their threads from `JULIA_NUM_THREADS`, or every
core when it is not set.

The GBIF download, the MODIS files, the gardens and WorldClim's file are registered but not public:
a push sends their records and not the files. Their licences or size forbid more, and only the
preparation runs read them.

### Pushing the runs

Once every run has passed, register the release they were made from, stage it and every finished
run the remote lacks, and push them to the remote registry:

```julia
release = DataPipeline.register_release!()   # the checked-out release
product = release.data_product
fair"add $(product.namespace):$(product.name)@v$(product.version)"
foreach(println, DataPipeline.code_runs())   # every run, finished, staged and on the remote or not
fair"add --all"                              # this project's finished runs the remote lacks
fair"push"
```

`register_release!` takes the release's DOI from Zenodo, which archives each GitHub release.
`DataPipeline.code_runs()` lists every run of the local registry; read the list before staging. A
push sends, with each data product, every finished run that read it, staged or not, so a run that
must not reach the remote is deleted from the local registry first, with `fair"rm <UUID> --yes"`. A
push that stops part way can be run again: what reached the remote is found there, not sent twice.
The listing, `fair add --all` and `fair rm` need `fair` 0.12.0 or later and DataPipeline 0.59.4 or
later. The HPC's runs read what these runs registered, so they are pushed first:
[`examples/paper/hpc/README.md`](../../examples/paper/hpc/README.md) goes on from there.

## Credentials

Never in the repository. The CDS key lives in `~/.cdsapirc` as the `cdsapi` client expects; the
GBIF username, password and the email GBIF notifies come from the environment or from
`~/.gbifrc`, a TOML file with `user`, `pwd` and `email` lines. The NASA Earthdata token for the EVI
files comes from `EARTHDATA_TOKEN` or from `~/.earthdata_token`, a file holding only the token and
readable only by its owner; tokens expire after about 60 days. A script reads its credentials only
when it has something to fetch. One that cannot find them says which are missing and stops before
touching the network.

## What each output is

- **`era5/`**: ERA5 monthly means on single levels, 0.25 degrees, over the Africa box, netCDF,
  one variable per file per decade: `t2m` (2 m temperature, K), `tp` (total precipitation,
  m/day as the monthly mean of the daily accumulation), `swvl1` (volumetric soil water, layer 1,
  m^3/m^3), `ssr` (surface net solar radiation, J/m^2/day). The request each file came from,
  and the CDS job that served it, are in its provenance record.
- **`twentycr/SI-MO/`**: 20CRv3 monthly means from NOAA PSL, global, PSL's own file names,
  each file 1806-01 to 2015-12, fetched from the URLs in EcoSISTEM's `TwentyCR` catalogue. PSL's
  `SI` directory serves byte-identical files, so it is not fetched; the quality boundaries (1836
  and 1981) lie inside each file. Not cut to Africa here.
- **`evi/`**: MOD13C2 v061 (MODIS/Terra Vegetation Indices Monthly L3 Global 0.05Deg CMG,
  doi:10.5067/MODIS/MOD13C2.061), one HDF4 file per month from January 2001 to December 2025, with
  a provenance sidecar holding its URL and checksum; where the catalogue lists a month twice the
  newer production is kept. `evi_mean_2001_2025.nc` averages each cell's EVI over the months the
  product's pixel reliability rates good (0) or marginal (1), leaving out snow or ice, cloud,
  estimated values and fill, and records how many months went into each cell.
- **`inventory.csv`**: what the files actually say, recorded before anything trusts them:
  variable names, `units` attributes verbatim, time axis calendar, first and last dates,
  spacing and whether it is even, latitude and longitude ranges and spacing and whether the
  latitude lattice is regular, grid-mapping attributes, `scale_factor`, `add_offset`,
  `_FillValue`.
- **`gbif/era5/`, `gbif/early/`**: two GBIF occurrence downloads of Plantae with coordinates in
  the Africa box, 1940 onward and 1806 to 1939, as the simple tab-separated CSV GBIF produces.
  `AfricaPlants.GBIF_DOWNLOADS` names each by its DOI, by which it is fetched with no account, and
  its key, which names its CSV. Each has its provenance record: the file's checksum, its DOI and GBIF's
  dated citation, the request's filter and years, and GBIF.org as the deposit it is cut from. Two
  rather than one so that a paper built on the ERA5 years alone has exactly the dataset it used to
  cite.
- **`records.csv`** (from `era5`) and **`records_early.csv`** (from `early`): `gbifID,
  speciesKey, species, decimalLatitude, decimalLongitude, year, month, on_lattice, near_garden,
  garden_named` for every record with a species-level name, coordinates, a month and a year, an
  accepted basis of record and coordinate uncertainty below the threshold, that is not within
  1 km of a country centroid in `data/centroids.csv` and whose locality does not mention a
  greenhouse, glasshouse, hothouse or shade house. The flags mark what one use may exclude and
  another keep: `on_lattice` (both coordinates whole multiples of a quarter degree, a position
  set to a coarse grid or rounded; quarter-degree square centres, the unit southern African
  herbaria georeference to, are not flagged), `near_garden` (within 1 km of a botanic garden in
  `data/gardens.csv`) and `garden_named` (the locality names a botanic garden, Hort., a nursery or
  cultivation). The provenance counts the records dropped and flagged.
- **`centroids.csv`**: `iso2, name, source, latitude, longitude` for the country-level entries
  of GBIF's Catalogue of Centroids at the commit named in `centroids.jl`. Regenerated rather
  than committed, since the catalogue states no licence.
- **`gardens.csv`**: `name, type, country, source, latitude, longitude` for every botanic garden
  in CoordinateCleaner's `institutions` gazetteer at the commit named in `gardens.jl`: the rows
  typed as gardens and those of other types (mostly herbaria) whose name says botanic garden or
  arboretum. Regenerated rather than committed, since CoordinateCleaner is GPL-3.
- **`records_africa.csv`**: the records of `records.csv` that fall in an active cell of a
  geographic grid cut to Natural Earth's continent-level Africa (land inside the outline), flags
  included. `wfo_species` and `wfo_id` name the species GBIF's `species` means in the WFO Plant List,
  resolved as the run's species pool resolves names, `missing` where WFO does not recognise it. This is the seeding dataset: every flagged record is kept for seeding, since a garden
  plant grows where it is recorded and a lattice point is close enough to place a seed in a grid
  cell. They are placed on the run's own grid at run time, since that grid is chosen then, and
  the effort raster is counted from them at the same point.
