# Imports
import os
import re
import sys
import numpy as np
import xarray as xr
import rasterio
import dask.array as da
from pyproj import CRS

# User configurations

INPUT_FOLDER = r"C:\ETC\input_rasters"
OUTPUT_PATH  = r"C:\ETC\test.nc"

YEAR_FILTER = "2025"   # or None to auto-pick the latest year

# Filename pattern: tcd_f_00_2025_CN_100m_R2024B_v1.tif
STRICT_REGEX = re.compile(
    r"^(?P<country>[a-z]{3})[_-](?P<gender>[fmt])[_-](?P<age>\d{2})[_-](?P<year>\d{4})(?:[_-].+)?\.tif$",
    re.IGNORECASE
)

def log(msg): print(msg, flush=True)

def compute_coords(transform, h, w):
    a,b,c,d,e,f = transform.a, transform.b, transform.c, transform.d, transform.e, transform.f
    eps = 1e-12
    north_up = abs(b) < eps and abs(d) < eps
    if not north_up:
        log("⚠️  WARNING: grid is rotated/sheared; ArcGIS prefers north-up.")
    x = c + (np.arange(w) + 0.5) * a + 0.5 * b
    y = f + (np.arange(h) + 0.5) * e + 0.5 * d
    return x.astype("float64"), y.astype("float64")

def main():
    # 1) Scan folder
    log("[1/9] Scanning input folder …")
    files = [f for f in os.listdir(INPUT_FOLDER) if f.lower().endswith(".tif")]
    log(f"  → Found {len(files)} tif files")
    if not files:
        sys.exit("❌ No TIFFs found")

    # 2) Parse filenames
    recs = []
    for fn in files:
        m = STRICT_REGEX.match(fn)
        if m:
            recs.append({
                "filename": fn,
                "gender": m.group("gender").lower(),
                "age": m.group("age"),
                "year": m.group("year")
            })
    if not recs:
        sys.exit("No files matched regex")

    years = sorted({r["year"] for r in recs})
    year = str(YEAR_FILTER) if YEAR_FILTER else years[-1]
    recs = [r for r in recs if r["year"] == year]
    log(f"  → Using year={year}, files={len(recs)}")

    genders = sorted({r["gender"] for r in recs})
    ages    = sorted({r["age"] for r in recs}, key=int)
    log(f"  → Genders={genders}")
    log(f"  → Ages={ages}")

    # 3) Inspect sample raster
    sample_path = os.path.join(INPUT_FOLDER, recs[0]["filename"])
    log(f"[3/9] Inspecting sample raster {os.path.basename(sample_path)} …")
    with rasterio.open(sample_path) as s:
        h, w = s.height, s.width
        crs = s.crs
        transform = s.transform
        dtype = s.dtypes[0]
        nodata = s.nodatavals[0]
        log(f"  → Shape={h}x{w}, CRS={crs}, EPSG={crs.to_epsg()}, dtype={dtype}, nodata={nodata}")

    # 4) Consistency check
    log("[4/9] Checking consistency …")
    for i, r in enumerate(recs, 1):
        with rasterio.open(os.path.join(INPUT_FOLDER, r["filename"])) as s:
            if s.crs != crs: sys.exit(f"CRS mismatch {r['filename']}")
            if s.transform != transform: sys.exit(f"Transform mismatch {r['filename']}")
            if (s.height, s.width) != (h, w): sys.exit(f"Shape mismatch {r['filename']}")
        if i % 10 == 0 or i == len(recs):
            log(f"    …checked {i}/{len(recs)}")

    # 5) Build lazy dask array
    log("[5/9] Building dask array (lazy) …")
    mat = {(r["gender"], r["age"]): r["filename"] for r in recs}

    tiles = []
    for gi,g in enumerate(genders):
        row = []
        for ai,a in enumerate(ages):
            fn = mat.get((g,a))
            if not fn:
                log(f"    MISSING tile gender={g}, age={a}")
                arr = da.zeros((h,w), dtype=dtype, chunks=(1024,1024))
            else:
                fpath = os.path.join(INPUT_FOLDER, fn)
                # rasterio open context inside a function for lazy load
                def reader(fp=fpath):
                    with rasterio.open(fp) as src:
                        return src.read(1)
                arr = da.from_delayed(
                    dask.delayed(reader)(),
                    shape=(h,w),
                    dtype=dtype
                ).rechunk((1024,1024))
            row.append(arr)
        tiles.append(da.stack(row, axis=0))
    data = da.stack(tiles, axis=0)  # (gender, age, y, x)

    log(f"  → Dask array shape={data.shape}, chunks={data.chunksize}")

    # 6) Build coords
    log("[6/9] Building coordinates …")
    x, y = compute_coords(transform, h, w)

    gender_ids = np.arange(len(genders), dtype="i1")
    age_ids    = np.array([int(a) for a in ages], dtype="i2")

    ds = xr.Dataset(
        {"population": (["gender","age_group","y","x"], data)},
        coords={
            "gender": ("gender", gender_ids),
            "age_group": ("age_group", age_ids),
            "x": ("x", x),
            "y": ("y", y),
        },
        attrs={"Conventions":"CF-1.8","year":year}
    )
    ds["population"].attrs["units"]="people"

    proj = CRS.from_user_input(crs)
    cf = proj.to_cf(); cf.pop("name",None)
    ds["spatial_ref"] = xr.DataArray(0, attrs=cf)
    ds["spatial_ref"].attrs["spatial_ref"] = proj.to_wkt()
    ds["spatial_ref"].attrs["GeoTransform"] = " ".join(map(str, transform.to_gdal()))
    ds["population"].attrs["grid_mapping"]="spatial_ref"

    # 7) Write NetCDF
    log("[7/9] Writing NetCDF (streamed with dask) …")
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    ds.to_netcdf(
        OUTPUT_PATH,
        engine="h5netcdf",     # works well with dask
        encoding={
            "population": {
                "zlib": True,
                "complevel": 4,
                "chunksizes": (1,1,1024,1024)  # tune chunking for ArcGIS
            }
        }
    )

    log(f"Done. NetCDF written: {OUTPUT_PATH}")

if __name__=="__main__":
    import dask
    main()
