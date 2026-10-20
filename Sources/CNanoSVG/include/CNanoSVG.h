#ifndef CNANOSVG_H
#define CNANOSVG_H

/// SVG where the OS has no public SVG reader (iOS): nanosvg parses and rasterizes basic SVG —
/// shapes, paths, gradients; no text, filters or CSS.

/// The SVG's own size in px (width/height, else viewBox). Returns 0 on success.
int cnanosvg_size(const char *path, float *width, float *height);

/// Rasterizes so the longer side is `maxSide` px (0 = own size). Returns malloc'd straight-alpha
/// RGBA (free with `free`), or NULL.
unsigned char *cnanosvg_render(const char *path, int maxSide, int *width, int *height);

#endif
