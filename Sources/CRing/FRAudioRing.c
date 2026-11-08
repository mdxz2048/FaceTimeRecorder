#include "FRAudioRing.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct FRSampleRing {
    uint32_t capacity_frames;
    uint32_t channels;
    uint64_t total_frames;
    float *storage;
    _Atomic uint64_t write_frame;
    _Atomic uint64_t read_frame;
    _Atomic uint64_t overflows;
};

FRSampleRing *fr_sample_ring_create(uint32_t capacity_frames, uint32_t channels) {
    if (capacity_frames < 1024 || capacity_frames > (1u << 22) ||
        channels < 1 || channels > 8) {
        return NULL;
    }
    FRSampleRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->capacity_frames = capacity_frames;
    ring->channels = channels;
    ring->total_frames = (uint64_t)capacity_frames * channels;
    if (ring->total_frames > (1ull << 26)) {
        free(ring);
        return NULL;
    }
    ring->storage = calloc((size_t)ring->total_frames, sizeof(float));
    if (!ring->storage || !atomic_is_lock_free(&ring->write_frame) ||
        !atomic_is_lock_free(&ring->read_frame)) {
        free(ring->storage);
        free(ring);
        return NULL;
    }
    atomic_init(&ring->write_frame, 0);
    atomic_init(&ring->read_frame, 0);
    atomic_init(&ring->overflows, 0);
    return ring;
}

void fr_sample_ring_destroy(FRSampleRing *ring) {
    if (!ring) return;
    free(ring->storage);
    free(ring);
}

uint32_t fr_sample_ring_write(FRSampleRing *ring, const float *src,
                              uint32_t frames) {
    if (!ring || !src || !frames) return 0;
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_acquire);
    uint64_t used = write - read;
    if (used >= ring->capacity_frames) {
        atomic_fetch_add_explicit(&ring->overflows, 1, memory_order_relaxed);
        return 0;
    }
    uint64_t room = ring->capacity_frames - used;
    uint32_t count = frames < room ? frames : (uint32_t)room;
    uint32_t ch = ring->channels;
    uint64_t start = write % ring->capacity_frames;
    uint64_t first = ring->capacity_frames - start;
    if (first > count) first = count;
    memcpy(ring->storage + start * ch, src, (size_t)first * ch * sizeof(float));
    if (count > first) {
        memcpy(ring->storage,
               src + first * ch,
               (size_t)(count - first) * ch * sizeof(float));
    }
    atomic_store_explicit(&ring->write_frame, write + count, memory_order_release);
    return count;
}

uint32_t fr_sample_ring_read(FRSampleRing *ring, float *dst, uint32_t frames) {
    if (!ring || !dst || !frames) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_acquire);
    uint64_t available = write - read;
    uint32_t count = frames < available ? frames : (uint32_t)available;
    if (!count) return 0;
    uint32_t ch = ring->channels;
    uint64_t start = read % ring->capacity_frames;
    uint64_t first = ring->capacity_frames - start;
    if (first > count) first = count;
    memcpy(dst, ring->storage + start * ch, (size_t)first * ch * sizeof(float));
    if (count > first) {
        memcpy(dst + first * ch, ring->storage,
               (size_t)(count - first) * ch * sizeof(float));
    }
    atomic_store_explicit(&ring->read_frame, read + count, memory_order_release);
    return count;
}

uint32_t fr_sample_ring_available(const FRSampleRing *ring) {
    if (!ring) return 0;
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_relaxed);
    uint64_t available = write - read;
    return available > ring->capacity_frames ? ring->capacity_frames
                                             : (uint32_t)available;
}

uint32_t fr_sample_ring_capacity(const FRSampleRing *ring) {
    return ring ? ring->capacity_frames : 0;
}

uint64_t fr_sample_ring_overflow_count(const FRSampleRing *ring) {
    return ring ? atomic_load_explicit(&ring->overflows, memory_order_relaxed) : 0;
}

uint32_t fr_sample_ring_peek(const FRSampleRing *ring, uint32_t offset,
                             float *dst, uint32_t frames) {
    if (!ring || !dst || !frames) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_acquire);
    uint64_t available = write - read;
    if (offset >= available) return 0;
    uint64_t room = available - offset;
    uint32_t count = frames < room ? frames : (uint32_t)room;
    if (!count) return 0;
    uint32_t ch = ring->channels;
    uint64_t start = (read + offset) % ring->capacity_frames;
    uint64_t first = ring->capacity_frames - start;
    if (first > count) first = count;
    memcpy(dst, ring->storage + start * ch, (size_t)first * ch * sizeof(float));
    if (count > first) {
        memcpy(dst + first * ch, ring->storage,
               (size_t)(count - first) * ch * sizeof(float));
    }
    return count;
}

void fr_sample_ring_advance(FRSampleRing *ring, uint32_t frames) {
    if (!ring || !frames) return;
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_acquire);
    uint64_t available = write - read;
    if (frames > available) frames = (uint32_t)available;
    atomic_store_explicit(&ring->read_frame, read + frames, memory_order_release);
}

void fr_sample_ring_clear(FRSampleRing *ring) {
    if (!ring) return;
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_relaxed);
    atomic_store_explicit(&ring->read_frame, write, memory_order_release);
}

typedef struct {
    FRBlockMeta meta;
    float *samples;
} FRBlockSlot;

struct FRBlockRing {
    uint32_t slots;
    uint32_t max_frames;
    uint32_t channels;
    FRBlockSlot *slot;
    float *storage;
    _Atomic uint32_t write_index;
    _Atomic uint32_t read_index;
    _Atomic uint64_t dropped;
    uint64_t sequence;
};

FRBlockRing *fr_block_ring_create(uint32_t slots, uint32_t max_frames,
                                  uint32_t channels) {
    if (slots < 2 || slots > 256 || (slots & (slots - 1)) ||
        max_frames < 64 || max_frames > 16384 ||
        channels < 1 || channels > 8) {
        return NULL;
    }
    FRBlockRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->slots = slots;
    ring->max_frames = max_frames;
    ring->channels = channels;
    ring->slot = calloc(slots, sizeof(FRBlockSlot));
    ring->storage = calloc((size_t)slots * max_frames * channels, sizeof(float));
    if (!ring->slot || !ring->storage || !atomic_is_lock_free(&ring->write_index)) {
        free(ring->slot);
        free(ring->storage);
        free(ring);
        return NULL;
    }
    for (uint32_t i = 0; i < slots; ++i) {
        ring->slot[i].samples = ring->storage + (size_t)i * max_frames * channels;
    }
    atomic_init(&ring->write_index, 0);
    atomic_init(&ring->read_index, 0);
    atomic_init(&ring->dropped, 0);
    return ring;
}

void fr_block_ring_destroy(FRBlockRing *ring) {
    if (!ring) return;
    free(ring->slot);
    free(ring->storage);
    free(ring);
}

int fr_block_ring_push(FRBlockRing *ring, const float *src, uint32_t frames,
                       uint32_t channels, uint32_t timestamp_flags,
                       uint64_t host_time, double sample_time) {
    if (!ring || !src || !frames) return -1;
    if (channels != ring->channels) return -1;
    uint32_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    if ((uint32_t)(write - read) >= ring->slots) {
        atomic_fetch_add_explicit(&ring->dropped, 1, memory_order_relaxed);
        return 0;
    }
    uint32_t copy = frames > ring->max_frames ? ring->max_frames : frames;
    FRBlockSlot *slot = &ring->slot[write % ring->slots];
    slot->meta = (FRBlockMeta){
        .frames = copy,
        .channels = channels,
        .timestamp_flags = timestamp_flags,
        .host_time = host_time,
        .sample_time = sample_time,
        .sequence = ring->sequence++,
        .dropped_before = atomic_load_explicit(&ring->dropped, memory_order_relaxed),
    };
    memcpy(slot->samples, src, (size_t)copy * channels * sizeof(float));
    atomic_store_explicit(&ring->write_index, write + 1, memory_order_release);
    return 1;
}

int fr_block_ring_pop(FRBlockRing *ring, float *dst, uint32_t capacity_frames,
                      FRBlockMeta *meta) {
    if (!ring || !dst || !meta) return -1;
    uint32_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    if (read == write) return 0;
    FRBlockSlot *slot = &ring->slot[read % ring->slots];
    if (slot->meta.frames > capacity_frames) return -1;
    memcpy(dst, slot->samples,
           (size_t)slot->meta.frames * slot->meta.channels * sizeof(float));
    *meta = slot->meta;
    atomic_store_explicit(&ring->read_index, read + 1, memory_order_release);
    return 1;
}

uint64_t fr_block_ring_dropped(const FRBlockRing *ring) {
    return ring ? atomic_load_explicit(&ring->dropped, memory_order_relaxed) : 0;
}

uint32_t fr_block_ring_max_frames(const FRBlockRing *ring) {
    return ring ? ring->max_frames : 0;
}

uint32_t fr_block_ring_channels(const FRBlockRing *ring) {
    return ring ? ring->channels : 0;
}

uint32_t fr_block_ring_count(const FRBlockRing *ring) {
    return ring ? ring->slots : 0;
}
