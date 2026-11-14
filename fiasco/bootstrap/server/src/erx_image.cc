// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The effects around erx_boot_load_plan: what the device tree and the first
// stage's own image say goes in, and the plan that comes out is applied in the
// order the design gives (docs/design-stopgap.md, "Boot handoff"). Where things
// go is decided by the plan, the device tree's copy and the handoff page
// included. What the plan cannot decide is still checked before any of the
// archive's or an image's bytes move: the magic of the kernel's two views and
// the options block's version, read in the archive where the loader left it,
// the device tree's copy, and a handoff record that does not fit. The boot CPU
// runs alone with translation off, so a physical address is a pointer.

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
static_assert(sizeof(l4_kernel_info_t::magic) == sizeof(l4_uint32_t)
              && sizeof(L4_kernel_options::Options::magic) == sizeof(l4_uint32_t)
              && sizeof(L4_kernel_options::Options::version) == sizeof(l4_uint32_t),
              "the views' checked fields are 32-bit words");

// No stack holds these; each serves the one call this boot makes.
static erx_boot_workspace_t workspace;
static erx_boot_load_plan_t plan;
// The handoff record, written whole before anything moves and copied into the
// kernel's options block once the kernel is copied.
alignas(8) static l4_uint8_t handoff_record[ERX_BOOT_HANDOFF_RECORD_SIZE];

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

// The archive's bytes to the place the plan leaves them, when an image that runs
// at its link addresses lands where the loader left them. The two ranges may
// overlap, so the bytes move as memmove moves them; nothing has read the archive
// at its new place yet, and nothing reads it at the old one again.
static void
move_archive(void)
{
  if (plan.archive.start == plan.archive_loaded.start)
    return;
  printf("erXos image: moving the archive from 0x%llx to 0x%llx\n",
         static_cast<unsigned long long>(plan.archive_loaded.start),
         static_cast<unsigned long long>(plan.archive.start));
  memmove(reinterpret_cast<void *>(plan.archive.start),
          reinterpret_cast<void const *>(plan.archive_loaded.start), plan.archive.size);
  if (Cache::Data::enabled())
    {
      Cache::Data::clean(plan.archive.start, plan.archive.size);
      Cache::Insn::inv();
    }
}

// A 32-bit field of a kernel view, read in the archive where the loader left it,
// whose alignment there the plan does not promise.
static l4_uint32_t
read_loaded_u32(l4_uint64_t address)
{
  l4_uint32_t value;
  memcpy(&value, reinterpret_cast<void const *>(address), sizeof(value));
  return value;
}

// What only the kernel's own bytes can show, read where the plan's copy will read
// them, so a kernel whose views are not Fiasco's is refused before anything moves.
static void
check_views(void)
{
  if (read_loaded_u32(plan.kip_loaded + offsetof(l4_kernel_info_t, magic))
      != L4_KERNEL_INFO_MAGIC)
    refuse("kernel information page", "magic");
  if (read_loaded_u32(plan.koptions_loaded + offsetof(L4_kernel_options::Options, magic))
      != L4_kernel_options::Magic)
    refuse("kernel options", "magic");
  if (read_loaded_u32(plan.koptions_loaded + offsetof(L4_kernel_options::Options, version))
      != L4_kernel_options::Version_current)
    refuse("kernel options", "version");
}

// Reserve the archive first, where the plan leaves it, never to be released, then
// the images. The archive is the root's to read and execute and never to write:
// the root maps an image entry's code from the archive's own pages into every task
// that runs it.
static void
reserve_plan(void)
{
  reserve(plan.archive, ".erxpack", Region::Root, Region::Root_section_rx);
  reserve({plan.kernel.start, plan.kernel.size}, ".kernel", Region::Kernel);
  reserve({plan.sigma0.start, plan.sigma0.size}, ".sigma0", Region::Sigma0);
  // A root region's subtype is what sigma0 may page to the root task. The root
  // runs its image through sigma0, and one range cannot tell its segments
  // apart, so it gets all rights over the whole range.
  if (plan.has_stand_in_root)
    reserve({plan.stand_in_root.start, plan.stand_in_root.size}, ".root",
            Region::Root, Region::Root_section_rwx);
}

// Move the archive and only then copy, since every copy reads the archive at its
// new place and may land on its old one. Nothing past this point refuses the boot.
static void
move_and_copy(void)
{
  move_archive();
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
// a page of its own, at the plan's handoff page, which sigma0 pages to it
// read-only. The kernel information page's user_ptr names it (init_kip_infos).
static l4_addr_t
write_handoff_page(l4_uint8_t const *record)
{
  l4_addr_t page = plan.handoff_page;
  reserve({page, L4_PAGESIZE}, ".erxhandoff", Region::Root, Region::Root_section_ro);

  char *target = reinterpret_cast<char *>(page);
  memset(target, 0, L4_PAGESIZE);
  memcpy(target, record, ERX_BOOT_HANDOFF_RECORD_SIZE);
  if (Cache::Data::enabled())
    Cache::Data::clean(page, L4_PAGESIZE);
  return page;
}

// The copy names no initrd. The loader's linux,initrd-start and linux,initrd-end
// give where it left the two-file form's archive, which holds an image or free
// RAM once the plan moves the archive; the root learns the archive's place from
// the handoff record alone. False when libfdt fails other than by an absence.
static bool
drop_initrd(void *tree)
{
  static char const *const names[] = { "linux,initrd-start", "linux,initrd-end" };
  for (char const *name : names)
    {
      // Deleting a property moves what follows it, so the node is found again.
      int chosen = fdt_path_offset(tree, "/chosen");
      if (chosen == -FDT_ERR_NOTFOUND)
        return true;
      if (chosen < 0)
        return false;
      int result = fdt_delprop(tree, chosen, name);
      if (result != 0 && result != -FDT_ERR_NOTFOUND)
        return false;
    }
  return true;
}

// The root's read-only copy of the firmware's device tree
// (docs/design-device-tree.md, "On the stopgap"): opened into the room the plan
// chose, of the tree's declared size, without the initrd's properties, packed so
// it holds no free space, and its whole pages reserved for the root to read and
// never write. The root, not bootstrap, checks the copy's contents with
// erx_dt_accept; this only moves the bytes.
static erx_boot_range_t
copy_device_tree(void const *fdt)
{
  l4_addr_t copy = plan.tree_copy.start;
  void *target = reinterpret_cast<void *>(copy);
  // erx_image_load bounded the declared size, and so the room, below 2 GiB.
  if (fdt_open_into(fdt, target, static_cast<int>(plan.tree_copy.size)) != 0
      || !drop_initrd(target) || fdt_pack(target) != 0)
    refuse("device tree", "copy");
  unsigned long size = fdt_totalsize(target);
  if (size == 0 || size > ERX_BOOT_TREE_COPY_MAX)
    refuse("device tree", "too_long");
  unsigned long pages = l4_round_page(size);
  reserve({copy, pages}, ".erxtree", Region::Root, Region::Root_section_ro);
  memset(static_cast<char *>(target) + size, 0, pages - size);
  if (Cache::Data::enabled())
    Cache::Data::clean(copy, pages);
  return erx_boot_range_t{copy, size};
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
  // fdt_open_into takes the copy's room as an int.
  unsigned long declared = fdt_totalsize(fdt);
  if (declared == 0 || declared > 0x7fffffffUL - L4_PAGESIZE)
    refuse("device tree", "size");
  request.device_tree = erx_boot_range_t{reinterpret_cast<l4_addr_t>(fdt), declared};
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

  check_views();

  int chosen = fdt_path_offset(fdt, "/chosen");
  int args_size = 0;
  char const *args = chosen < 0 ? nullptr
    : static_cast<char const *>(fdt_getprop(fdt, chosen, "bootargs", &args_size));
  size_t args_length = 0;
  if (args && args_size > 0)
    args_length = erx_boot_args_cut(args, strnlen(args, args_size), ERX_BOOT_ARGS_MAX);
  static char stdout_path[ERX_BOOT_STDOUT_MAX + 1];
  size_t stdout_length = chosen_stdout_path(fdt, chosen, stdout_path);
  // The boot CPU's identification registers, which only kernel mode reads.
  uint64_t cpu_id[ERX_BOOT_CPU_ID_COUNT];
  erx_boot_cpu_id_read(cpu_id);

  // The last refusals, before anything moves: the tree's copy and the record go
  // where the plan keeps them clear of the archive, at both its places, and of
  // every image.
  reserve_plan();
  erx_boot_range_t tree = copy_device_tree(fdt);
  if (!erx_boot_handoff_write(&plan, args, args_length, stdout_path, stdout_length,
                              chosen_boot_pair(fdt, chosen), tree, cpu_id, handoff_record,
                              sizeof(handoff_record)))
    refuse("handoff record", "write");
  l4_addr_t handoff_page = write_handoff_page(handoff_record);

  move_and_copy();
  auto *kip = reinterpret_cast<l4_kernel_info_t *>(plan.kip.start);
  auto *options = reinterpret_cast<L4_kernel_options::Options *>(plan.koptions.start);
  memcpy(options->erx_handoff, handoff_record, sizeof(options->erx_handoff));

  printf("erXos image: index ");
  print_hex(plan.index_hash, sizeof(plan.index_hash));
  printf(" at 0x%llx+0x%llx\n", static_cast<unsigned long long>(plan.archive.start),
         static_cast<unsigned long long>(plan.archive.size));

  Erx_image_loaded loaded = {};
  loaded.boot_info.handoff_page = handoff_page;
  loaded.boot_info.kernel_start = plan.kernel.entry;
  loaded.boot_info.sigma0_start = plan.sigma0.entry;
  loaded.boot_info.roottask_start
    = plan.has_stand_in_root ? plan.stand_in_root.entry : 0;
  loaded.kip = kip;
  loaded.options = options;
  return loaded;
}
