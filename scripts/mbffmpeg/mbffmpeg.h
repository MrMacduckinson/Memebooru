// In-process FFmpeg for iOS, where apps can't launch helper executables.
// Everything goes through one lock: fftools keeps global state, so runs are strictly one at a time.
#ifndef MBFFMPEG_H
#define MBFFMPEG_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Runs the ffmpeg command line (argv[0] is ignored, like a program name) inside this process.
/// Returns the exit code (0 = success). Error lines are copied into `err` (NUL-terminated).
int mb_ffmpeg_run(int argc, const char **argv, char *err, int errLength);

typedef struct {
    char container[32];
    char video[32];
    char audio[32];
    int width;
    int height;
    int64_t durationMs;
    int hasAlpha;
} mb_probe_result;

/// ffprobe's essentials: first video and audio stream codecs, size, duration, alpha. 0 = success.
int mb_probe(const char *path, mb_probe_result *out, char *err, int errLength);

/// Names of all encoders built in, newline-separated. Returns the length written.
int mb_encoders(char *buffer, int length);

#ifdef __cplusplus
}
#endif
#endif
