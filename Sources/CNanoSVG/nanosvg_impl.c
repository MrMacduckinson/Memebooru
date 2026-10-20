#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NANOSVG_IMPLEMENTATION
#include "nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvgrast.h"

#include "CNanoSVG.h"

int cnanosvg_size(const char *path, float *width, float *height) {
    NSVGimage *img = nsvgParseFromFile(path, "px", 96.0f);
    if (!img) return -1;
    *width = img->width; *height = img->height;
    nsvgDelete(img);
    return (*width > 0 && *height > 0) ? 0 : -1;
}

unsigned char *cnanosvg_render(const char *path, int maxSide, int *width, int *height) {
    NSVGimage *img = nsvgParseFromFile(path, "px", 96.0f);
    if (!img) return NULL;
    if (img->width <= 0 || img->height <= 0) { nsvgDelete(img); return NULL; }
    float longer = img->width > img->height ? img->width : img->height;
    float scale = maxSide > 0 ? (float)maxSide / longer : 1.0f;
    int w = (int)fmaxf(1.0f, roundf(img->width * scale)), h = (int)fmaxf(1.0f, roundf(img->height * scale));
    unsigned char *pixels = calloc((size_t)w * (size_t)h, 4);
    NSVGrasterizer *rast = nsvgCreateRasterizer();
    if (pixels && rast) nsvgRasterize(rast, img, 0, 0, scale, pixels, w, h, w * 4);
    if (rast) nsvgDeleteRasterizer(rast);
    nsvgDelete(img);
    if (!pixels || !rast) { free(pixels); return NULL; }
    *width = w; *height = h;
    return pixels;
}
