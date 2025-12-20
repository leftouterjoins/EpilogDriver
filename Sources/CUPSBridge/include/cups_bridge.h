/*
 * cups_bridge.h - C bridging header for CUPS APIs
 *
 * This header exposes CUPS raster and printing APIs to Swift code.
 * Part of the Epilog Zing macOS printer driver.
 */

#ifndef CUPS_BRIDGE_H
#define CUPS_BRIDGE_H

#include <cups/cups.h>
#include <cups/raster.h>
#include <cups/ppd.h>

/*
 * Re-export CUPS types for Swift visibility.
 * The module.modulemap will make these available to Swift.
 */

/* Raster stream handle */
typedef cups_raster_t* CupsRasterHandle;

/* Page header structure - contains resolution, dimensions, color info */
typedef cups_page_header2_t CupsPageHeader;

/* Options parsing */
typedef cups_option_t CupsOption;

/*
 * Helper functions for Swift interop.
 * These wrap CUPS functions that may have complex signatures.
 */

/* Open stdin as a CUPS raster stream for reading */
static inline CupsRasterHandle cups_raster_open_stdin(void) {
    return cupsRasterOpen(0, CUPS_RASTER_READ);
}

/* Read the next page header from a raster stream */
static inline int cups_raster_read_header(CupsRasterHandle ras, CupsPageHeader* header) {
    return cupsRasterReadHeader2(ras, header);
}

/* Read pixel data for one line */
static inline unsigned cups_raster_read_line(CupsRasterHandle ras, unsigned char* buffer, unsigned len) {
    return cupsRasterReadPixels(ras, buffer, len);
}

/* Close the raster stream */
static inline void cups_raster_close(CupsRasterHandle ras) {
    cupsRasterClose(ras);
}

/* Parse CUPS options string into key-value pairs */
static inline int cups_parse_options(const char* options, int num_existing, CupsOption** opts) {
    return cupsParseOptions(options, num_existing, opts);
}

/* Get a specific option value */
static inline const char* cups_get_option(const char* name, int num_options, CupsOption* options) {
    return cupsGetOption(name, num_options, options);
}

/* Free options array */
static inline void cups_free_options(int num_options, CupsOption* options) {
    cupsFreeOptions(num_options, options);
}

#endif /* CUPS_BRIDGE_H */
