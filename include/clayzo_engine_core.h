// C ABI of packages/engine-core-rs. Keep in step with the `#[no_mangle]`
// exports in src/lib.rs — there is no generator, this is the contract.
#ifndef CLAYZO_ENGINE_CORE_H
#define CLAYZO_ENGINE_CORE_H

#include <stddef.h>
#include <stdint.h>

// JSON protocol. `alloc`'s buffer is consumed by `process`; the result is a
// little-endian u32 length followed by that many UTF-8 bytes.
uint8_t *alloc(size_t len);
uint8_t *process(uint8_t *pointer, size_t len);
void free_result(uint8_t *pointer);

// Packed frame: word 0 is the packet length in f64 words. Null on failure.
double *render_frame(uint32_t handle, double tick, double scale_x, double scale_y, uint32_t bounds);
void free_frame(double *pointer);

// Interaction. Pointer and inputs are set between frames; the interactive
// frame folds them in and reports `events`, `settled` and `cursor` in its
// metadata. `set_input` kinds: 0 number, 1 boolean, 2 vec2, 3 colour, 4 trigger.
uint32_t is_interactive(uint32_t handle);
void set_pointer(uint32_t handle, double x, double y, uint32_t inside, uint32_t down);
void set_scroll(uint32_t handle, double x, double y);
uint32_t set_input(uint32_t handle, const uint8_t *name, size_t name_len, uint32_t kind, double a, double b, double c, double d);
double *render_frame_interactive(uint32_t handle, double tick, double scale_x, double scale_y, uint32_t bounds, double delta_seconds);

#endif
