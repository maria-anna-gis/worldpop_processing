# Inspired by https://rspatialdata.github.io/population.html

# Libraries
library(sf)
library(terra)       
library(tmap)
library(cartogram)
library(exactextractr)

# Configuration
project_config <- list(
  base_dir       = "C:/ETC",
  zip_file       = "ZMB_population_v1_0_admin.zip",
  extract_dir    = "admin_unzipped",
  pop_raster     = "ZMB_population_v1_0_mastergrid.tif",
  shapefile_path = "ZMB_population_v1_0_admin/ZMB_population_v1_0_admin_level2.shp",
  output_file    = "C:/ETC/zambia_population_map_norm.png",
  target_crs     = 32736,   # UTM Zone 36S for Zambia
  use_cartogram  = FALSE     # ← set to FALSE for standard map (no deformation) or TRUE for the cartogram
)

# Helper: safe path builder
get_path <- function(base, ...) file.path(base, ...)

# 1) Extract admin boundaries (if needed)
extract_admin_data <- function(config) {
  zip_path    <- get_path(config$base_dir, config$zip_file)
  extract_dir <- get_path(config$base_dir, config$extract_dir)
  shp_file    <- get_path(extract_dir, config$shapefile_path)
  
  if (!dir.exists(extract_dir)) dir.create(extract_dir, recursive = TRUE)
  
  if (!file.exists(shp_file)) {
    if (!file.exists(zip_path)) stop("Zip file not found: ", zip_path)
    unzip(zip_path, exdir = extract_dir)
    cat("✓ Admin boundaries extracted\n")
  } else {
    cat("✓ Admin boundaries already available\n")
  }
  shp_file
}

# 2) Load + prepare spatial data
load_and_prepare_data <- function(config) {
  shp_file <- extract_admin_data(config)
  
  cat("Loading admin boundaries...\n")
  admin_boundaries <- st_read(shp_file, quiet = TRUE)
  admin_boundaries <- st_transform(admin_boundaries, crs = config$target_crs)
  
  cat("Loading population raster...\n")
  pop_raster_path <- get_path(config$base_dir, config$pop_raster)
  if (!file.exists(pop_raster_path)) stop("Population raster not found: ", pop_raster_path)
  pop_raster <- rast(pop_raster_path)
  
  # Crop raster by admin bbox (in raster CRS)
  admin_in_raster_crs <- st_transform(admin_boundaries, st_crs(pop_raster))
  admin_bbox_rcrs <- st_bbox(admin_in_raster_crs)
  pop_raster_cropped <- crop(pop_raster, admin_bbox_rcrs)
  
  # Reproject raster to match admin CRS
  pop_raster_proj <- project(pop_raster_cropped, paste0("EPSG:", config$target_crs), method = "bilinear")
  
  cat("✓ Spatial data loaded and prepared\n")
  list(admin = admin_boundaries, population = pop_raster_proj)
}

# 3) Helper: attach population totals to polygons
attach_population <- function(admin_sf, pop_rast) {
  cat("Calculating population by admin unit...\n")
  pop_vals <- exact_extract(pop_rast, admin_sf, "sum", progress = FALSE)
  admin_sf$population <- pop_vals
  na_idx <- is.na(admin_sf$population)
  if (any(na_idx)) {
    warning("Some admin units had NA population; setting those to 0.")
    admin_sf$population[na_idx] <- 0
  }
  admin_sf
}

# 4) Make cartogram (contiguous)
create_cartogram <- function(admin_with_pop, max_iterations = 10) {
  cat("Creating cartogram (contiguous)...\n")
  cg <- cartogram_cont(admin_with_pop, "population", itermax = max_iterations)
  cat("✓ Cartogram created successfully\n")
  cg
}

# 5) Static map creation (no title, prints to Plot window and saves PNG)
create_map <- function(mapped_data, output_path) {
  cat("Creating visualization...\n")
  tmap_mode("plot")
  
  mapped_clean <- mapped_data[!is.na(mapped_data$population), ]
  
  main_map <- tm_shape(mapped_clean) +
    tm_polygons(
      col = "population",
      palette = "brewer.reds",
      border.col = "gray40",
      border.alpha = 0.8,
      title = "Population",   # legend title
      style = "cont"
    ) +
    tm_layout(
      legend.outside = TRUE,
      legend.outside.position = "right",
      legend.frame = FALSE,
      legend.bg.color = "transparent",
      legend.format = list(fun = function(x) format(x, big.mark = ",", scientific = FALSE)),
      frame = FALSE,
      outer.margins = c(0.02, 0.15, 0.02, 0.02)
    )
  
  # Show in RStudio Plots pane / R graphics device
  print(main_map)
  
  # Save PNG (hi-res)
  tmap_save(main_map, filename = output_path, width = 2400, height = 1500, dpi = 300)
  cat("✓ Main map saved to:", output_path, "\n")
  
  main_map
}

# 6) Main execution
main <- function(config = project_config) {
  cat("Starting Zambia Population mapping...\n")
  cat(paste(rep("=", 50), collapse = ""), "\n")
  
  tryCatch({
    spatial_data <- load_and_prepare_data(config)
    admin_with_pop <- attach_population(spatial_data$admin, spatial_data$population)
    
    if (isTRUE(config$use_cartogram)) {
      cat("Option selected: CARTOGRAM\n")
      mapped_data <- create_cartogram(admin_with_pop)
    } else {
      cat("Option selected: ORIGINAL BOUNDARIES (no cartogram)\n")
      mapped_data <- admin_with_pop
    }
    
    invisible(create_map(mapped_data, config$output_file))
    
    cat(paste(rep("=", 50), collapse = ""), "\n")
    cat("✓ Process completed successfully!\n")
    cat("✓ Static map:", config$output_file, "\n")
    rng <- range(mapped_data$population, na.rm = TRUE)
    cat("Population range:", round(rng[1]), "to", round(rng[2]), "\n")
    
    invisible(mapped_data)
    
  }, error = function(e) {
    cat("✗ Error occurred: ", e$message, "\n")
    stop(e)
  })
}

# 7) Run
zambia_result <- main()

# Optional: quick summary
#cat("\nSummary Statistics:\n")
#print(summary(zambia_result$population))
