// ytm-dec: m4a (AAC, формат 140 YouTube) со stdin -> S16LE 44,1 кГц стерео на stdout.
// Собирается на тех же статических ffmpeg, что и shairport-sync (build/ffout: только
// demuxer mov, decoder aac/alac, без сети и программ) — вместо ffmpeg из Entware (~25 МБ).
// Поток не перематывается: фрагментированный mp4 YouTube читается подряд.
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <stdio.h>
#include <unistd.h>

#define RATE 44100
#define IOBUF 65536

static int read_stdin(void *opaque, uint8_t *buf, int size) {
  (void)opaque;
  ssize_t n = read(0, buf, (size_t)size);
  return n > 0 ? (int)n : AVERROR_EOF;
}

static int write_all(const uint8_t *p, size_t n) {
  while (n) {
    ssize_t w = write(1, p, n);
    if (w <= 0) return -1;
    p += w;
    n -= (size_t)w;
  }
  return 0;
}

int main(void) {
  av_log_set_level(AV_LOG_ERROR);
  uint8_t *iobuf = av_malloc(IOBUF);
  AVIOContext *io = avio_alloc_context(iobuf, IOBUF, 0, NULL, read_stdin, NULL, NULL);
  AVFormatContext *fmt = avformat_alloc_context();
  if (!io || !fmt) return 1;
  io->seekable = 0;
  fmt->pb = io;
  if (avformat_open_input(&fmt, NULL, NULL, NULL) < 0 || avformat_find_stream_info(fmt, NULL) < 0) {
    fprintf(stderr, "ytm-dec: не разобрал поток\n");
    return 1;
  }
  int si = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  if (si < 0) {
    fprintf(stderr, "ytm-dec: нет звука в потоке\n");
    return 1;
  }
  AVCodecParameters *par = fmt->streams[si]->codecpar;
  const AVCodec *codec = avcodec_find_decoder(par->codec_id);
  AVCodecContext *dec = codec ? avcodec_alloc_context3(codec) : NULL;
  if (!dec || avcodec_parameters_to_context(dec, par) < 0 || avcodec_open2(dec, codec, NULL) < 0) {
    fprintf(stderr, "ytm-dec: нет декодера\n");
    return 1;
  }

  AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
  SwrContext *swr = NULL;
  if (swr_alloc_set_opts2(&swr, &stereo, AV_SAMPLE_FMT_S16, RATE, &dec->ch_layout, dec->sample_fmt,
                          dec->sample_rate, 0, NULL) < 0 ||
      swr_init(swr) < 0) {
    fprintf(stderr, "ytm-dec: не настроился пересчёт\n");
    return 1;
  }

  AVPacket *pkt = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  uint8_t *out = NULL;
  int out_cap = 0;
  int eof = 0;
  while (!eof) {
    if (av_read_frame(fmt, pkt) < 0) {
      eof = 1;
      avcodec_send_packet(dec, NULL);
    } else {
      if (pkt->stream_index == si) avcodec_send_packet(dec, pkt);
      av_packet_unref(pkt);
    }
    while (avcodec_receive_frame(dec, frame) == 0) {
      int want = swr_get_out_samples(swr, frame->nb_samples);
      if (want > out_cap) {
        av_freep(&out);
        if (av_samples_alloc(&out, NULL, 2, want, AV_SAMPLE_FMT_S16, 0) < 0) return 1;
        out_cap = want;
      }
      int got = swr_convert(swr, &out, out_cap, (const uint8_t **)frame->extended_data,
                            frame->nb_samples);
      if (got > 0 && write_all(out, (size_t)got * 4)) return 0; // плеер закрыл канал
      av_frame_unref(frame);
    }
  }
  return 0;
}
