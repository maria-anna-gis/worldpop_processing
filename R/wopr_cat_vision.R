library(wopr)
library(dplyr)
library(stringr)

# If using the package(s) for the first time, run the line below in the console
#install.packages(c("dplyr", "readr", "stringr"))

# 1) Pulls the full WorldPop catalogue
cat <- getCatalogue()

# 2) Filters to the specific product (exact phrase first; fallback regex if needed)
needle <- fixed("Gridded population estimates (~100m) for specific age-sex groups",
                ignore_case = TRUE)
text_cols <- intersect(c("title","product","subcategory","category","description","tags"),
                       names(cat))

gp <- cat %>%
  filter(if_any(all_of(text_cols), ~ str_detect(.x, needle)))

if (nrow(gp) == 0) {
  gp <- cat %>%
    filter(if_any(all_of(text_cols),
                  ~ str_detect(.x, regex("gridded population.*age.?sex|age-?sex",
                                         ignore_case = TRUE))))
}

# 3) Pick the best-available country/version fields (catalogue schemas can vary)
country_col <- intersect(c("country", "country_name", "iso3", "ISO3"), names(gp))[1]
version_col <- intersect(c("version", "dataset_version", "release"), names(gp))[1]

if (length(country_col) == 0 || length(version_col) == 0) {
  stop("Could not find 'country' or 'version' columns in the catalogue.")
}

# 4) List unique Country–Version combos
country_versions <- gp %>%
  transmute(
    country = .data[[country_col]],
    version = as.character(.data[[version_col]])
  ) %>%
  distinct() %>%
  arrange(country, desc(version))

country_versions      # prints in console
#View(country_versions)  # in RStudio, opens catalogue table

# 5) Access data through woprVision interface - opens a new window in the browser.
# woprVision()
