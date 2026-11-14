/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The effects harness's stand-in for the generated erx/hw/device_access.h: found before it on
 * the include path by test/host/erx_device_queue_test.rb, so every access erx_device.c makes
 * to a register window goes to test/fixtures/erx_device_dma_harness.c, which plays a
 * virtio-mmio device's side of its registers: a reset, banked feature words and a refusal.
 */

#ifndef ERX_HW_DEVICE_ACCESS_H
#define ERX_HW_DEVICE_ACCESS_H

#include <stdint.h>

uint8_t		erx_device_access_load8(volatile uint8_t *window, uint64_t offset);
void		erx_device_access_store8(volatile uint8_t *window, uint64_t offset, uint8_t value);
uint16_t	erx_device_access_load16(volatile uint8_t *window, uint64_t offset);
void		erx_device_access_store16(volatile uint8_t *window, uint64_t offset, uint16_t value);
uint32_t	erx_device_access_load32(volatile uint8_t *window, uint64_t offset);
void		erx_device_access_store32(volatile uint8_t *window, uint64_t offset, uint32_t value);
uint64_t	erx_device_access_load64(volatile uint8_t *window, uint64_t offset);
void		erx_device_access_store64(volatile uint8_t *window, uint64_t offset, uint64_t value);

#endif /* ERX_HW_DEVICE_ACCESS_H */
