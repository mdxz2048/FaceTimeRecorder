#ifndef FR_AUDIO_RING_H
#define FR_AUDIO_RING_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Lock-free single-producer / single-consumer rings used by FaceTime Recorder.
 *
 * Real-time rules for every producer function below:
 *   - no allocation, no locks, no file I/O, no logging, no Objective-C.
 *   - the producer must be exactly one thread (a HAL IOProc or an audio unit
 *     render callback).
 */

typedef struct FRSampleRing FRSampleRing;

FRSampleRing *fr_sample_ring_create(uint32_t capacity_frames, uint32_t channels);
void fr_sample_ring_destroy(FRSampleRing *ring);

/* Producer side. Returns frames actually written (may be 0 when full). */
uint32_t fr_sample_ring_write(FRSampleRing *ring, const float *interleaved,
                              uint32_t frames);

/* Consumer side. */
uint32_t fr_sample_ring_read(FRSampleRing *ring, float *interleaved,
                             uint32_t frames);
uint32_t fr_sample_ring_available(const FRSampleRing *ring);
uint32_t fr_sample_ring_capacity(const FRSampleRing *ring);
uint64_t fr_sample_ring_overflow_count(const FRSampleRing *ring);

/* Consumer-only random access used by the drift resampler. `offset` is
 * relative to the current read position. Copies up to `frames` frames and
 * returns the number copied. Does not advance the read position. */
uint32_t fr_sample_ring_peek(const FRSampleRing *ring, uint32_t offset,
                             float *interleaved, uint32_t frames);
void fr_sample_ring_advance(FRSampleRing *ring, uint32_t frames);
void fr_sample_ring_clear(FRSampleRing *ring);

typedef struct {
    uint32_t frames;
    uint32_t channels;
    uint32_t timestamp_flags;
    uint64_t host_time;
    double sample_time;
    uint64_t sequence;
    uint64_t dropped_before;
} FRBlockMeta;

typedef struct FRBlockRing FRBlockRing;

FRBlockRing *fr_block_ring_create(uint32_t slots, uint32_t max_frames,
                                  uint32_t channels);
void fr_block_ring_destroy(FRBlockRing *ring);

/* Producer side. `channels` must be <= the channel count given at creation. */
int fr_block_ring_push(FRBlockRing *ring, const float *interleaved,
                       uint32_t frames, uint32_t channels,
                       uint32_t timestamp_flags, uint64_t host_time,
                       double sample_time);

/* Consumer side. Returns 1 on success, 0 when empty, -1 on layout error. */
int fr_block_ring_pop(FRBlockRing *ring, float *interleaved,
                      uint32_t capacity_frames, FRBlockMeta *meta);

uint64_t fr_block_ring_dropped(const FRBlockRing *ring);
uint32_t fr_block_ring_max_frames(const FRBlockRing *ring);
uint32_t fr_block_ring_channels(const FRBlockRing *ring);
uint32_t fr_block_ring_count(const FRBlockRing *ring);

#ifdef __cplusplus
}
#endif

#endif /* FR_AUDIO_RING_H */
