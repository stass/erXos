// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The effects around erx_boot_load_plan: what the device tree and the first
// stage's own image say goes in, and the plan that comes out is applied in the
// order the design gives (docs/design-stopgap.md, "Boot handoff"). Where things
// go is decided by the plan; what is left to refuse after the copy is what only
// the copied kernel can show: the magic of its two views, the options block's
// version, and a handoff record that does not fit; and no free page for the
// record's copy, which the plan does not choose. The boot CPU runs alone with
// translation off, so a physical address is a pointer.

#include <libfdt.h>
#include <stdio.h>
#include <string.h>

#include <l4/sys/consts.h>
#include <l4/util/util.h>

#include "erx/core/boot_handoff.h"
#include "erx/core/boot_place.h"

#include "arch/arm/mem.h"
#include "erx_image.h"
#include "memcpy_aligned.h"
#include "memory.h"
#include "platform_dt-arm.h"
#include "support.h"

extern char _start[], _end[];
extern "C" char const erx_boot_locator[];
extern "C" l4_uint64_t const erx_boot_declared_size;

enum { Memory_ranges_max = 16, Reservations_max = 32 };

static_assert(offsetof(L4_kernel_options::Options, erx_handoff) % 8 == 0,
              "the handoff record lies on its alignment inside the options");
static_assert(sizeof(L4_kernel_options::Options::erx_handoff)
              == ERX_BOOT_HANDOFF_RECORD_SIZE,
              "the options block embeds the whole handoff record");
static_assert(ERX_BOOT_HANDOFF_RECORD_SIZE <= L4_PAGESIZE,
              "the handoff page holds the whole handoff record");

// No stack holds these; each serves the one call this boot makes.
static erx_boot_workspace_t workspace;
static erx_boot_load_plan_t plan;

// The boot stops here, on the console, naming the check; the operator's harness
// or the machine's watchdog ends it.
[[noreturn]] static void
refuse(erx_boot_error_t const &error)
{
  if (error.path)
    printf("erXos image: %s: %s\n", error.path, error.reason);
  else if (error.entry != ERX_BOOT_NO_ENTRY)
    printf("erXos image: entry %u: %s\n", error.entry, error.reason);
  else if (!strcmp(error.reason, "version"))
    printf("erXos image: header: version %llu, expected %u\n",
           static_cast<unsigned long long>(error.found), ERX_BOOT_IMAGE_VERSION);
  else
    printf("erXos image: header: %s\n", error.reason);
  l4_infinite_loop();
}

[[noreturn]] static void
refuse(char const *path, char const *reason)
{
  erx_boot_error_t error = {};
  error.reason = reason;
  error.path = path;
  error.entry = ERX_BOOT_NO_ENTRY;
  refuse(error);
}

static l4_uint64_t
read_cell(void const *prop, int size)
{
  if (size == 8)
    return fdt64_to_cpu(*static_cast<fdt64_t const *>(prop));
  if (size == 4)
    return fdt32_to_cpu(*static_cast<fdt32_t const *>(prop));
  refuse("device tree", "initrd_cell_size");
}

// /chosen's initrd range, which the two-file form's loader sets.
static bool
chosen_initrd(void const *fdt, erx_boot_range_t *initrd)
{
  int chosen = fdt_path_offset(fdt, "/chosen");
  if (chosen < 0)
    return false;
  int start_size, end_size;
  void const *start = fdt_getprop(fdt, chosen, "linux,initrd-start", &start_size);
  void const *end = fdt_getprop(fdt, chosen, "linux,initrd-end", &end_size);
  if (!start || !end)
    return false;
  // QEMU's alignment of a property is only 4, and strict alignment holds here.
  l4_uint64_t first = 0, last = 0;
  if (start_size == 8 || end_size == 8)
    {
      fdt64_t s, e;
      if (start_size != 8 || end_size != 8)
        refuse("device tree", "initrd_cell_size");
      memcpy(&s, start, sizeof(s));
      memcpy(&e, end, sizeof(e));
      first = read_cell(&s, 8);
      last = read_cell(&e, 8);
    }
  else
    {
      first = read_cell(start, start_size);
      last = read_cell(end, end_size);
    }
  if (last < first)
    refuse("device tree", "initrd_range");
  *initrd = erx_boot_range_t{first, last - first};
  return true;
}

// The full path of the node /chosen/stdout-path names, written into path, and its
// length (Devicetree Specification v0.4, section 3.6: the value ends at the first
// ":", where the UART's options begin, and is a full path or an alias, which
// libfdt resolves through /aliases). 0 when the property is absent, is no string,
// names no node, or resolves to a path longer than ERX_BOOT_STDOUT_MAX; the
// root then refuses the boot and says the tree names no console.
static size_t
chosen_stdout_path(void const *fdt, int chosen, char (&path)[ERX_BOOT_STDOUT_MAX + 1])
{
  if (chosen < 0)
    return 0;
  int size = 0;
  char const *value = static_cast<char const *>(fdt_getprop(fdt, chosen, "stdout-path", &size));
  if (!value || size <= 0)
    return 0;
  size_t length = strnlen(value, size);
  if (length == static_cast<size_t>(size))
    return 0;
  char const *colon = static_cast<char const *>(memchr(value, ':', length));
  int node = fdt_path_offset_namelen(fdt, value, static_cast<int>(colon ? colon - value : length));
  if (node < 0 || fdt_get_path(fdt, node, path, sizeof(path)) != 0)
    return 0;
  return strnlen(path, sizeof(path));
}

// The boot pair from /chosen/bootloader's partition and tryboot, which firmware
// that boots one of two slots writes, and the QEMU harness writes as it does
// (docs/design-platforms.md, "What the loader hands over"). The core decides;
// a missing node or property reaches it as an absent one, and gives unknown.
static erx_boot_pair_t
chosen_boot_pair(void const *fdt, int chosen)
{
  int bootloader = chosen < 0 ? chosen : fdt_subnode_offset(fdt, chosen, "bootloader");
  int partition_size = 0, tryboot_size = 0;
  void const *partition = bootloader < 0 ? nullptr
    : fdt_getprop(fdt, bootloader, "partition", &partition_size);
  void const *tryboot = bootloader < 0 ? nullptr
    : fdt_getprop(fdt, bootloader, "tryboot", &tryboot_size);
  return erx_boot_pair_derive(partition, partition ? static_cast<size_t>(partition_size) : 0,
                              tryboot, tryboot ? static_cast<size_t>(tryboot_size) : 0);
}

// The device tree's reservation block and every region inherited code has
// reserved so far, its device-tree nodes and the device tree's own included.
static size_t
reservations(void const *fdt, erx_boot_range_t *reserved)
{
  int count = fdt_num_mem_rsv(fdt);
  if (count < 0 || count > Reservations_max)
    refuse("device tree", "reservations");
  for (int index = 0; index < count; index++)
    if (fdt_get_mem_rsv(fdt, index, &reserved[index].start,
                        &reserved[index].size) < 0)
      refuse("device tree", "reservations");
  size_t used = static_cast<size_t>(count);
  // bootstrap's own image is in the list, and the plan holds it apart anyway.
  for (Region const &region : *mem_manager->regions)
    {
      if (region.begin() == reinterpret_cast<l4_addr_t>(_start))
        continue;
      if (used == Reservations_max)
        refuse("device tree", "reservations");
      reserved[used++] = erx_boot_range_t{region.begin(), region.size()};
    }
  return used;
}

static void
reserve(erx_boot_range_t range, char const *name, Region::Type type,
        Region::Subtype_info rights = Region::No_subtype)
{
  mem_manager->regions->add(Region::start_size(range.start, range.size, name, type, rights));
}

// Reserve the archive first, never to be released, then the images, then copy.
static void
apply(void)
{
  reserve(plan.archive, ".erxpack", Region::Root, Region::Root_section_ro);
  reserve({plan.kernel.start, plan.kernel.size}, ".kernel", Region::Kernel);
  reserve({plan.sigma0.start, plan.sigma0.size}, ".sigma0", Region::Sigma0);
  // A root region's subtype is what sigma0 may page to the root task. The root
  // runs its image through sigma0, and one range cannot tell its segments
  // apart, so it gets all rights over the whole range.
  if (plan.has_stand_in_root)
    reserve({plan.stand_in_root.start, plan.stand_in_root.size}, ".root",
            Region::Root, Region::Root_section_rwx);

  for (unsigned index = 0; index < plan.ncopies; index++)
    {
      erx_boot_copy_t const &copy = plan.copies[index];
      char *target = reinterpret_cast<char *>(copy.target);
      char const *source = reinterpret_cast<char const *>(copy.source);
      if ((copy.source | copy.target) % 8)
        memcpy(target, source, copy.file_size);
      else
        memcpy_aligned(target, source, copy.file_size);
      if (Cache::Data::enabled())
        {
          Cache::Data::clean(copy.target, copy.file_size);
          Cache::Insn::inv();
        }
      memset(target + copy.file_size, 0, copy.mem_size - copy.file_size);
    }
}

// The options block is mapped into no task, so the root reads the record from
// a page of its own, which sigma0 pages to it read-only. The kernel information
// page's user_ptr names it (init_kip_infos).
static l4_addr_t
write_handoff_page(l4_uint8_t const *record)
{
  l4_addr_t page = mem_manager->find_free_ram(L4_PAGESIZE);
  if (!page)
    refuse("handoff page", "no_free_page");
  reserve({page, L4_PAGESIZE}, ".erxhandoff", Region::Root, Region::Root_section_ro);

  char *target = reinterpret_cast<char *>(page);
  memset(target, 0, L4_PAGESIZE);
  memcpy(target, record, ERX_BOOT_HANDOFF_RECORD_SIZE);
  if (Cache::Data::enabled())
    Cache::Data::clean(page, L4_PAGESIZE);
  return page;
}

static void
print_hex(l4_uint8_t const *bytes, unsigned length)
{
  for (unsigned index = 0; index < length; index++)
    printf("%02x", bytes[index]);
}

Erx_image_loaded
erx_image_load(Platform_base *plat)
{
  auto *dt_platform = static_cast<Platform_dt_arm *>(plat);
  void const *fdt = dt_platform->dt.have_fdt() ? dt_platform->dt.fdt() : nullptr;
  if (!fdt)
    refuse("device tree", "no_device_tree");

  static erx_boot_range_t memory[Memory_ranges_max];
  static erx_boot_range_t reserved[Reservations_max];
  size_t nmemory = 0;
  for (Region const &range : *mem_manager->ram)
    {
      if (nmemory == Memory_ranges_max)
        refuse("device tree", "memory_ranges");
      memory[nmemory++] = erx_boot_range_t{range.begin(), range.size()};
    }

  erx_boot_load_request_t request = {};
  request.locator = reinterpret_cast<l4_uint8_t const *>(erx_boot_locator);
  request.load = reinterpret_cast<l4_addr_t>(_start);
  request.linked_end = reinterpret_cast<l4_addr_t>(_end) - request.load;
  request.declared_size = erx_boot_declared_size;
  request.has_initrd = chosen_initrd(fdt, &request.initrd);
  request.device_tree = erx_boot_range_t{reinterpret_cast<l4_addr_t>(fdt),
                                         fdt_totalsize(fdt)};
  request.memory = memory;
  request.nmemory = nmemory;
  request.reserved = reserved;
  request.nreserved = reservations(fdt, reserved);
  request.koptions_min = sizeof(L4_kernel_options::Options);
  request.window = nullptr;
  request.window_start = 0;
  request.window_size = ~l4_uint64_t{0};

  erx_boot_error_t error = {};
  if (!erx_boot_load_plan(&request, &workspace, &plan, &error))
    refuse(error);

  apply();

  auto *kip = reinterpret_cast<l4_kernel_info_t *>(plan.kip.start);
  if (kip->magic != L4_KERNEL_INFO_MAGIC)
    refuse("kernel information page", "magic");
  auto *options = reinterpret_cast<L4_kernel_options::Options *>(plan.koptions.start);
  if (options->magic != L4_kernel_options::Magic)
    refuse("kernel options", "magic");
  if (options->version != L4_kernel_options::Version_current)
    refuse("kernel options", "version");

  int chosen = fdt_path_offset(fdt, "/chosen");
  int args_size = 0;
  char const *args = chosen < 0 ? nullptr
    : static_cast<char const *>(fdt_getprop(fdt, chosen, "bootargs", &args_size));
  size_t args_length = 0;
  if (args && args_size > 0)
    args_length = erx_boot_args_cut(args, strnlen(args, args_size), ERX_BOOT_ARGS_MAX);
  static char stdout_path[ERX_BOOT_STDOUT_MAX + 1];
  size_t stdout_length = chosen_stdout_path(fdt, chosen, stdout_path);
  if (!erx_boot_handoff_write(&plan, args, args_length, stdout_path, stdout_length,
                              chosen_boot_pair(fdt, chosen), options->erx_handoff,
                              sizeof(options->erx_handoff)))
    refuse("handoff record", "write");

  printf("erXos image: index ");
  print_hex(plan.index_hash, sizeof(plan.index_hash));
  printf(" at 0x%llx+0x%llx\n", static_cast<unsigned long long>(plan.archive.start),
         static_cast<unsigned long long>(plan.archive.size));

  Erx_image_loaded loaded = {};
  loaded.boot_info.handoff_page = write_handoff_page(options->erx_handoff);
  loaded.boot_info.kernel_start = plan.kernel.entry;
  loaded.boot_info.sigma0_start = plan.sigma0.entry;
  loaded.boot_info.roottask_start
    = plan.has_stand_in_root ? plan.stand_in_root.entry : 0;
  loaded.kip = kip;
  loaded.options = options;
  return loaded;
}
