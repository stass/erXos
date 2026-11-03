/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi_reader.h"
#include "erx/elf_plan.h"

static bool erx_elf_fail(erx_elf_error_t *, const char *, uint64_t);
static bool erx_elf_extent(uint64_t, uint64_t, uint64_t);
static bool erx_elf_round(uint64_t, uint64_t, uint64_t *);
static bool erx_elf_equal(const uint8_t *, const uint8_t *, size_t);
static bool erx_elf_note(const uint8_t *, size_t, uint64_t,
    uint32_t *, erx_elf_error_t *);
static bool erx_elf_dynamic(const uint8_t *, size_t, uint64_t,
    erx_elf_error_t *);
static bool erx_elf_load(erx_elf_plan_t *, const erx_elf64_phdr_t *,
    size_t, erx_elf_error_t *);
static bool erx_elf_phdr(const uint8_t *, size_t, const erx_elf64_ehdr_t *,
    uint16_t, erx_elf64_phdr_t *);
static bool erx_elf_place(erx_elf_plan_t *, const erx_elf64_ehdr_t *,
    const erx_elf64_phdr_t *, uint64_t, erx_elf_error_t *);
static bool erx_elf_phdr_address(const erx_elf_plan_t *, uint64_t,
    uint64_t, uint64_t, uint64_t *);
static bool erx_elf_memory_covered(const erx_elf_plan_t *, uint64_t, uint64_t);
static bool erx_elf_metadata_mapped(const erx_elf_plan_t *,
    const erx_elf64_phdr_t *, bool, erx_elf_error_t *);

static bool
erx_elf_fail(erx_elf_error_t *error, const char *reason, uint64_t offset)
{
	if (error != NULL) {
		error->reason = reason;
		error->offset = offset;
	}
	return (false);
}

static bool
erx_elf_extent(uint64_t offset, uint64_t length, uint64_t total)
{
	return (offset <= total && length <= total - offset);
}

static bool
erx_elf_round(uint64_t value, uint64_t alignment, uint64_t *result)
{
	uint64_t rounded;

	if (__builtin_add_overflow(value, alignment - 1, &rounded))
		return (false);
	*result = rounded & ~(alignment - 1);
	return (true);
}

static bool
erx_elf_equal(const uint8_t *left, const uint8_t *right, size_t length)
{
	for (size_t index = 0; index < length; index++) {
		if (left[index] != right[index])
			return (false);
	}
	return (true);
}

static bool
erx_elf_phdr(const uint8_t *bytes, size_t length,
    const erx_elf64_ehdr_t *header, uint16_t index, erx_elf64_phdr_t *result)
{
	uint64_t relative, offset;

	if (__builtin_mul_overflow((uint64_t)index,
	    (uint64_t)ERX_ELF64_PHDR_SIZE, &relative) ||
	    __builtin_add_overflow(header->e_phoff, relative, &offset) ||
	    !erx_elf_extent(offset, ERX_ELF64_PHDR_SIZE, length))
		return (false);
	return (erx_elf64_phdr_decode(bytes + (size_t)offset,
	    ERX_ELF64_PHDR_SIZE, result));
}

static bool
erx_elf_note(const uint8_t *bytes, size_t length, uint64_t file_offset,
    uint32_t *notes, erx_elf_error_t *error)
{
	static const uint8_t owner[] = ERX_ABI_NOTE_OWNER_BYTES;
	erx_elf64_nhdr_t header;
	erx_abi_note_t note;
	uint64_t cursor, name_offset, name_size, descriptor, descriptor_size, end;

	cursor = 0;
	while (cursor < length) {
		if (!erx_elf_extent(cursor, ERX_ELF64_NHDR_SIZE, length) ||
		    !erx_elf64_nhdr_decode(bytes + (size_t)cursor,
		    ERX_ELF64_NHDR_SIZE, &header) ||
		    !erx_elf_round(header.n_namesz, ERX_ELF64_NHDR_ALIGN,
		    &name_size) ||
		    !erx_elf_round(header.n_descsz, ERX_ELF64_NHDR_ALIGN,
		    &descriptor_size) ||
		    __builtin_add_overflow(cursor, (uint64_t)ERX_ELF64_NHDR_SIZE,
		    &name_offset) ||
		    __builtin_add_overflow(name_offset, name_size, &descriptor) ||
		    __builtin_add_overflow(descriptor, descriptor_size, &end) ||
		    end > length)
			return (erx_elf_fail(error, "note_extent", file_offset + cursor));
		if (header.n_namesz == sizeof(owner) &&
		    erx_elf_equal(bytes + (size_t)name_offset, owner, sizeof(owner)) &&
		    header.n_type == ERX_ABI_NOTE_TYPE) {
			if (header.n_descsz != sizeof(note.abi_version) ||
			    end - cursor != ERX_ABI_NOTE_SIZE ||
			    !erx_abi_note_decode(bytes + (size_t)cursor,
			    ERX_ABI_NOTE_SIZE, &note))
				return (erx_elf_fail(error, "abi_note_extent", file_offset + cursor));
			for (uint64_t index = name_offset + sizeof(owner);
			    index < descriptor; index++) {
				if (bytes[(size_t)index] != 0)
					return (erx_elf_fail(error, "abi_note_padding", file_offset + index));
			}
			if (note.abi_version != ERX_ABI_VERSION)
				return (erx_elf_fail(error, "abi_version", file_offset + descriptor));
			if (*notes != 0)
				return (erx_elf_fail(error, "duplicate_abi_note", file_offset + cursor));
			*notes = 1;
		}
		cursor = end;
	}
	return (true);
}

static bool
erx_elf_dynamic(const uint8_t *bytes, size_t length, uint64_t file_offset,
    erx_elf_error_t *error)
{
	erx_elf64_dyn_t dynamic;

	if (length % ERX_ELF64_DYN_SIZE != 0)
		return (erx_elf_fail(error, "dynamic_extent", file_offset));
	for (size_t offset = 0; offset < length; offset += ERX_ELF64_DYN_SIZE) {
		if (!erx_elf64_dyn_decode(bytes + offset,
		    ERX_ELF64_DYN_SIZE, &dynamic))
			return (erx_elf_fail(error, "dynamic_extent", file_offset + offset));
		if (dynamic.d_tag == ERX_ELF_DT_NULL)
			return (true);
		if (dynamic.d_tag == ERX_ELF_DT_NEEDED)
			return (erx_elf_fail(error, "dynamic_dependency", file_offset + offset));
		if (dynamic.d_tag == ERX_ELF_DT_TEXTREL ||
		    (dynamic.d_tag == ERX_ELF_DT_FLAGS &&
		    (dynamic.d_value & ERX_ELF_DF_TEXTREL) != 0))
			return (erx_elf_fail(error, "text_relocation", file_offset + offset));
	}
	return (erx_elf_fail(error, "dynamic_terminator", file_offset));
}

static bool
erx_elf_load(erx_elf_plan_t *plan, const erx_elf64_phdr_t *program,
    size_t length, erx_elf_error_t *error)
{
	erx_elf_load_t load;
	uint64_t end;
	uint32_t position;

	if (program->p_filesz > program->p_memsz ||
	    !erx_elf_extent(program->p_offset, program->p_filesz, length))
		return (erx_elf_fail(error, "load_file_extent", program->p_offset));
	if (program->p_memsz == 0)
		return (true);
	if (plan->nloads == ERX_ELF_SEGMENTS_MAX)
		return (erx_elf_fail(error, "load_count", program->p_offset));
	if (program->p_offset % ERX_PAGE_SIZE != 0 ||
	    program->p_vaddr % ERX_PAGE_SIZE != 0 ||
	    (program->p_align > 1 &&
	    ((program->p_align & (program->p_align - 1)) != 0 ||
	    program->p_offset % program->p_align !=
	    program->p_vaddr % program->p_align)) ||
	    program->p_align > UINT32_MAX)
		return (erx_elf_fail(error, "load_alignment", program->p_offset));
	if ((program->p_flags & ~(ERX_ELF_PF_R | ERX_ELF_PF_W | ERX_ELF_PF_X)) != 0 ||
	    (program->p_flags & ERX_ELF_PF_R) == 0 ||
	    (program->p_flags & (ERX_ELF_PF_W | ERX_ELF_PF_X)) ==
	    (ERX_ELF_PF_W | ERX_ELF_PF_X) ||
	    ((program->p_flags & ERX_ELF_PF_W) != 0 &&
	    program->p_memsz > ERX_IMAGE_WRITABLE_MAX) ||
	    __builtin_add_overflow(program->p_vaddr, program->p_memsz, &end))
		return (erx_elf_fail(error, "load_protection_or_size", program->p_offset));
	/* Absolute virtual addresses are sorted here, then normalized once. */
	load = (erx_elf_load_t){ .source_offset = program->p_offset,
	    .segment = { .mem_offset = program->p_vaddr,
	    .file_size = program->p_filesz, .mem_size = program->p_memsz,
	    .prot = (program->p_flags & ERX_ELF_PF_X) != 0 ? ERX_PROT_RX :
	    ((program->p_flags & ERX_ELF_PF_W) != 0 ? ERX_PROT_RW : ERX_PROT_R) } };
	if (program->p_align > plan->base_alignment)
		plan->base_alignment = (uint32_t)program->p_align;
	position = plan->nloads;
	/* At most sixteen values: stable insertion keeps virtual order explicit. */
	while (position > 0 &&
	    plan->loads[position - 1].segment.mem_offset > load.segment.mem_offset) {
		plan->loads[position] = plan->loads[position - 1];
		position--;
	}
	plan->loads[position] = load;
	plan->nloads++;
	return (true);
}

static bool
erx_elf_phdr_address(const erx_elf_plan_t *plan, uint64_t file_offset,
    uint64_t size, uint64_t preferred, uint64_t *address)
{
	const erx_elf_load_t *load;
	uint64_t cursor, current, remaining, available;

	for (uint32_t first = 0; first < plan->nloads; first++) {
		load = &plan->loads[first];
		if (file_offset < load->source_offset ||
		    file_offset - load->source_offset >= load->segment.file_size)
			continue;
		current = load->segment.mem_offset +
		    (file_offset - load->source_offset);
		if (preferred != UINT64_MAX && current != preferred)
			continue;
		*address = current;
		cursor = file_offset;
		remaining = size;
		for (uint32_t index = first; index < plan->nloads && remaining != 0; index++) {
			load = &plan->loads[index];
			if (current < load->segment.mem_offset ||
			    current - load->segment.mem_offset >= load->segment.file_size ||
			    load->source_offset +
			    (current - load->segment.mem_offset) != cursor)
				break;
			available = load->segment.file_size -
			    (current - load->segment.mem_offset);
			if (available > remaining)
				available = remaining;
			current += available;
			cursor += available;
			remaining -= available;
		}
		if (remaining == 0)
			return (true);
	}
	return (false);
}

static bool
erx_elf_memory_covered(const erx_elf_plan_t *plan, uint64_t address,
    uint64_t length)
{
	const erx_image_segment_t *segment;
	uint64_t cursor, end, segment_end;

	if (__builtin_add_overflow(address, length, &end))
		return (false);
	cursor = address;
	for (uint32_t index = 0; index < plan->nloads && cursor < end; index++) {
		segment = &plan->loads[index].segment;
		segment_end = segment->mem_offset + segment->mem_size;
		if (cursor >= segment_end)
			continue;
		if (cursor < segment->mem_offset)
			return (false);
		cursor = segment_end < end ? segment_end : end;
	}
	return (cursor == end);
}

static bool
erx_elf_metadata_mapped(const erx_elf_plan_t *plan,
    const erx_elf64_phdr_t *program, bool tls, erx_elf_error_t *error)
{
	uint64_t address, source_address, end, allocation;

	if (program->p_filesz > program->p_memsz ||
	    __builtin_add_overflow(program->p_vaddr, program->p_memsz, &end) ||
	    program->p_memsz > ERX_ARCH_USER_LIMIT - ERX_USER_BASE_MIN)
		return (erx_elf_fail(error, tls ? "tls_range" : "dynamic_range", program->p_offset));
	if (program->p_align > 1 &&
	    ((program->p_align & (program->p_align - 1)) != 0 ||
	    program->p_align > ERX_ARCH_USER_LIMIT - ERX_USER_BASE_MIN ||
	    program->p_offset % program->p_align !=
	    program->p_vaddr % program->p_align ||
	    __builtin_add_overflow(program->p_memsz,
	    program->p_align - 1, &allocation)))
		return (erx_elf_fail(error, tls ? "tls_alignment" : "dynamic_alignment", program->p_offset));
	/* An empty TLS initializer reads no source byte; its private BSS is not
	 * part of the image's LOAD memory extent. Nonempty templates must have
	 * identical file and virtual views, as the libc startup follows vaddr.
	 */
	if (tls && program->p_filesz == 0)
		return (true);
	if (program->p_vaddr < plan->virtual_origin)
		return (erx_elf_fail(error, tls ? "tls_mapping" : "dynamic_mapping", program->p_offset));
	address = program->p_vaddr - plan->virtual_origin;
	if (!erx_elf_phdr_address(plan, program->p_offset,
	    program->p_filesz, address, &source_address) ||
	    (!tls && !erx_elf_memory_covered(plan, address, program->p_memsz)))
		return (erx_elf_fail(error, tls ? "tls_mapping" : "dynamic_mapping", program->p_offset));
	return (true);
}

static bool
erx_elf_place(erx_elf_plan_t *plan, const erx_elf64_ehdr_t *header,
    const erx_elf64_phdr_t *phdr_hint, uint64_t output_budget,
    erx_elf_error_t *error)
{
	erx_elf_load_t *load;
	uint64_t origin, previous, end, rounded, storage, cursor, phdr_bytes, preferred;
	bool entry_found;

	if (plan->nloads == 0)
		return (erx_elf_fail(error, "no_loads", header->e_phoff));
	origin = plan->loads[0].segment.mem_offset;
	if (header->e_type == ERX_ELF_ET_EXEC) {
		plan->fixed_base = origin;
		plan->flags = ERX_IMAGE_FIXED;
		plan->base_alignment = ERX_PAGE_SIZE;
	} else {
		origin &= ~((uint64_t)plan->base_alignment - 1);
	}
	plan->virtual_origin = origin;
	previous = 0;
	cursor = ERX_PAGE_SIZE;
	entry_found = false;
	for (uint32_t index = 0; index < plan->nloads; index++) {
		load = &plan->loads[index];
		load->segment.mem_offset -= origin;
		if (__builtin_add_overflow(load->segment.mem_offset,
		    load->segment.mem_size, &end) ||
		    !erx_elf_round(end, ERX_PAGE_SIZE, &rounded) ||
		    load->segment.mem_offset < previous || rounded > ERX_IMAGE_SPAN_MAX)
			return (erx_elf_fail(error, "load_memory_overlap_or_span", load->source_offset));
		if (header->e_entry >= origin &&
		    header->e_entry - origin >= load->segment.mem_offset &&
		    header->e_entry - origin < end && load->segment.prot == ERX_PROT_RX)
			entry_found = true;
		load->segment.file_offset = cursor;
		storage = load->segment.prot == ERX_PROT_RW ?
		    load->segment.file_size : load->segment.mem_size;
		if (!erx_elf_round(storage, ERX_PAGE_SIZE, &storage) ||
		    __builtin_add_overflow(cursor, storage, &cursor) || cursor > output_budget)
			return (erx_elf_fail(error, "output_budget", load->source_offset));
		previous = rounded;
	}
	plan->span = previous;
	plan->output_size = cursor;
	if (!entry_found)
		return (erx_elf_fail(error, "entry_not_executable", header->e_entry));
	plan->entry = header->e_entry - origin;
	if (header->e_type == ERX_ELF_ET_EXEC &&
	    (origin < ERX_USER_BASE_MIN ||
	    !erx_elf_extent(origin, plan->span, ERX_ARCH_USER_LIMIT)))
		return (erx_elf_fail(error, "fixed_user_range", origin));
	phdr_bytes = (uint64_t)header->e_phnum * ERX_ELF64_PHDR_SIZE;
	preferred = UINT64_MAX;
	if (phdr_hint != NULL) {
		if (phdr_hint->p_offset != header->e_phoff ||
		    phdr_hint->p_filesz != phdr_bytes ||
		    phdr_hint->p_memsz != phdr_bytes ||
		    phdr_hint->p_vaddr < origin)
			return (erx_elf_fail(error, "phdr_descriptor", header->e_phoff));
		preferred = phdr_hint->p_vaddr - origin;
	}
	if (!erx_elf_phdr_address(plan, header->e_phoff,
	    phdr_bytes, preferred, &plan->phdr_offset))
		return (erx_elf_fail(error, "phdr_not_mapped", header->e_phoff));
	return (true);
}

bool
erx_elf_plan(const uint8_t *bytes, size_t length, uint64_t output_budget,
    erx_elf_plan_t *result, erx_elf_error_t *error)
{
	static const uint8_t magic[] = ERX_ELF_MAGIC_BYTES;
	erx_elf_plan_t plan;
	erx_elf64_ehdr_t header;
	erx_elf64_phdr_t program;
	erx_elf64_phdr_t phdr_hint;
	erx_elf64_phdr_t dynamic, tls;
	uint64_t table_bytes, metadata_work;
	uint32_t notes;
	bool has_phdr_hint, has_dynamic, has_tls;

	if (bytes == NULL || result == NULL ||
	    !erx_elf64_ehdr_decode(bytes, length, &header) ||
	    !erx_elf_equal(header.e_ident, magic, sizeof(magic)) ||
	    header.e_ident[ERX_ELF_EI_CLASS] != ERX_ELF_CLASS64 ||
	    header.e_ident[ERX_ELF_EI_DATA] != ERX_ELF_DATA_LSB ||
	    header.e_ident[ERX_ELF_EI_VERSION] != ERX_ELF_VERSION_CURRENT ||
	    header.e_version != ERX_ELF_VERSION_CURRENT ||
	    header.e_machine != ERX_ARCH_ELF_MACHINE ||
	    (header.e_type != ERX_ELF_ET_EXEC && header.e_type != ERX_ELF_ET_DYN) ||
	    header.e_ehsize != ERX_ELF64_EHDR_SIZE ||
	    header.e_phentsize != ERX_ELF64_PHDR_SIZE ||
	    header.e_phnum == 0 || header.e_phnum == ERX_ELF_PN_XNUM ||
	    __builtin_mul_overflow((uint64_t)header.e_phnum,
	    (uint64_t)ERX_ELF64_PHDR_SIZE, &table_bytes) ||
	    !erx_elf_extent(header.e_phoff, table_bytes, length))
		return (erx_elf_fail(error, "elf_header", 0));
	plan = (erx_elf_plan_t){ .base_alignment = ERX_PAGE_SIZE,
	    .phnum = header.e_phnum };
	notes = 0;
	has_phdr_hint = false;
	has_dynamic = false;
	has_tls = false;
	metadata_work = 0;
	for (uint16_t index = 0; index < header.e_phnum; index++) {
		if (!erx_elf_phdr(bytes, length, &header, index, &program))
			return (erx_elf_fail(error, "program_header", header.e_phoff));
		if (program.p_type == ERX_ELF_PT_INTERP)
			return (erx_elf_fail(error, "interpreter", program.p_offset));
		if (program.p_type == ERX_ELF_PT_PHDR) {
			if (has_phdr_hint)
				return (erx_elf_fail(error, "duplicate_phdr", program.p_offset));
			phdr_hint = program;
			has_phdr_hint = true;
		}
		if (program.p_type == ERX_ELF_PT_TLS) {
			if (has_tls)
				return (erx_elf_fail(error, "duplicate_tls", program.p_offset));
			if (!erx_elf_extent(program.p_offset, program.p_filesz, length))
				return (erx_elf_fail(error, "tls_range", program.p_offset));
			tls = program;
			has_tls = true;
		}
		if (program.p_type == ERX_ELF_PT_LOAD) {
			if (!erx_elf_load(&plan, &program, length, error))
				return (false);
		} else if (program.p_type == ERX_ELF_PT_NOTE ||
		    program.p_type == ERX_ELF_PT_DYNAMIC) {
			if (!erx_elf_extent(program.p_offset, program.p_filesz, length))
				return (erx_elf_fail(error, "metadata_extent", program.p_offset));
			/* Repeated overlapping metadata cannot multiply parser work.
			 * The complete scan consumes at most one source file's bytes.
			 */
			if (__builtin_add_overflow(metadata_work, program.p_filesz,
			    &metadata_work) || metadata_work > length)
				return (erx_elf_fail(error, "metadata_work", program.p_offset));
			if (program.p_type == ERX_ELF_PT_DYNAMIC) {
				if (has_dynamic)
					return (erx_elf_fail(error, "duplicate_dynamic", program.p_offset));
				dynamic = program;
				has_dynamic = true;
			}
			if (program.p_type == ERX_ELF_PT_NOTE &&
			    !erx_elf_note(bytes + (size_t)program.p_offset,
			    (size_t)program.p_filesz, program.p_offset, &notes, error))
				return (false);
			if (program.p_type == ERX_ELF_PT_DYNAMIC &&
			    !erx_elf_dynamic(bytes + (size_t)program.p_offset,
			    (size_t)program.p_filesz, program.p_offset, error))
				return (false);
		}
	}
	if (notes != 1)
		return (erx_elf_fail(error, "missing_abi_note", 0));
	if (!erx_elf_place(&plan, &header,
	    has_phdr_hint ? &phdr_hint : NULL, output_budget, error))
		return (false);
	if ((has_dynamic && !erx_elf_metadata_mapped(&plan, &dynamic, false, error)) ||
	    (has_tls && !erx_elf_metadata_mapped(&plan, &tls, true, error)))
		return (false);
	*result = plan;
	return (true);
}
