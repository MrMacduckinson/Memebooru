#include "mbffmpeg.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>

/// Defined by the patched fftools/ffmpeg.c (resets its globals, then runs the original main).
extern int mb_ffmpeg_main(int argc, char **argv);

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static char *capture;
static int captureLength;
static int captureUsed;

static void capture_log(void *avcl, int level, const char *fmt, va_list vl) {
    (void)avcl;
    if (level > av_log_get_level() || level > AV_LOG_WARNING || !capture || captureUsed >= captureLength - 1) return;
    int n = vsnprintf(capture + captureUsed, (size_t)(captureLength - captureUsed), fmt, vl);
    if (n > 0) captureUsed += n < captureLength - captureUsed ? n : captureLength - captureUsed - 1;
}

static void begin_capture(char *err, int errLength) {
    capture = err; captureLength = errLength; captureUsed = 0;
    if (err && errLength > 0) err[0] = 0;
    av_log_set_callback(capture_log);
}

static void end_capture(void) {
    av_log_set_callback(av_log_default_callback);
    capture = NULL; captureLength = 0; captureUsed = 0;
}

int mb_ffmpeg_run(int argc, const char **argv, char *err, int errLength) {
    pthread_mutex_lock(&lock);
    begin_capture(err, errLength);
    int ret = mb_ffmpeg_main(argc, (char **)argv);
    end_capture();
    pthread_mutex_unlock(&lock);
    return ret;
}

static void copy_name(char *dst, const char *src) {
    if (!src) { dst[0] = 0; return; }
    strncpy(dst, src, 31); dst[31] = 0;
}

int mb_probe(const char *path, mb_probe_result *out, char *err, int errLength) {
    memset(out, 0, sizeof(*out));
    pthread_mutex_lock(&lock);
    begin_capture(err, errLength);
    AVFormatContext *fmt = NULL;
    int ret = avformat_open_input(&fmt, path, NULL, NULL);
    if (ret >= 0) ret = avformat_find_stream_info(fmt, NULL);
    if (ret >= 0) {
        if (fmt->iformat && fmt->iformat->name) {
            // "matroska,webm" → "matroska"
            const char *comma = strchr(fmt->iformat->name, ',');
            size_t n = comma ? (size_t)(comma - fmt->iformat->name) : strlen(fmt->iformat->name);
            if (n > 31) n = 31;
            memcpy(out->container, fmt->iformat->name, n); out->container[n] = 0;
        }
        for (unsigned i = 0; i < fmt->nb_streams; i++) {
            AVStream *st = fmt->streams[i];
            AVCodecParameters *par = st->codecpar;
            if (par->codec_type == AVMEDIA_TYPE_VIDEO && !out->video[0]) {
                copy_name(out->video, avcodec_get_name(par->codec_id));
                out->width = par->width; out->height = par->height;
                const AVPixFmtDescriptor *d = av_pix_fmt_desc_get((enum AVPixelFormat)par->format);
                if (d && (d->flags & AV_PIX_FMT_FLAG_ALPHA)) out->hasAlpha = 1;
                AVDictionaryEntry *a = av_dict_get(st->metadata, "alpha_mode", NULL, AV_DICT_IGNORE_SUFFIX);
                if (a && strcmp(a->value, "1") == 0) out->hasAlpha = 1;
            } else if (par->codec_type == AVMEDIA_TYPE_AUDIO && !out->audio[0]) {
                copy_name(out->audio, avcodec_get_name(par->codec_id));
            }
        }
        if (fmt->duration > 0) out->durationMs = fmt->duration / 1000;
    } else if (err && errLength > 0 && !err[0]) {
        av_strerror(ret, err, (size_t)errLength);
    }
    avformat_close_input(&fmt);
    end_capture();
    pthread_mutex_unlock(&lock);
    return ret < 0 ? ret : 0;
}

int mb_encoders(char *buffer, int length) {
    int used = 0;
    void *it = NULL;
    const AVCodec *c;
    if (length > 0) buffer[0] = 0;
    while ((c = av_codec_iterate(&it))) {
        if (!av_codec_is_encoder(c)) continue;
        int n = snprintf(buffer + used, (size_t)(length - used), "%s\n", c->name);
        if (n < 0 || n >= length - used) break;
        used += n;
    }
    return used;
}
