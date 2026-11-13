# Source origin

Repository: https://github.com/kernkonzept/fiasco

Revision: 50bbe8a981199e17865e8553a4eb02c387b339cf

The inventory records the imported bytes and their license evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/kernkonzept/fiasco",
  "revision": "50bbe8a981199e17865e8553a4eb02c387b339cf",
  "archive_sha256": "80cb4b4db43f18521b859012cb16201d62b3b541c69cdfb2f36f6fa726a8aea5",
  "exclusions": [
    {
      "path": "src/kern/arm/bsp/qcom/Kconfig",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/Modules",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/config-arm-qcom.cpp",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/context-arm-hyp-qcom.cpp",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/iommu-arm-smmu-500-qcom.cpp",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/mem_layout-arm-qcom.cpp",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/pic-arm-qcom.cpp",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/platform_control-arm-qcom.cpp",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/reset-arm-qcom.cpp",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/kern/arm/bsp/qcom/timer-arm-generic-qcom.cpp",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfiling.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfiling.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfilingBuffer.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfilingInternal.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfilingInternal.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfilingPlatformLinux.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfilingPort.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfilingUtil.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfilingVersionVar.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/InstrProfilingWriter.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/profile/InstrProfData.inc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-17/profile/MemProfData.inc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfiling.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfiling.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfilingBuffer.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfilingInternal.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfilingInternal.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfilingPlatformLinux.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfilingPort.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfilingUtil.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfilingVersionVar.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/InstrProfilingWriter.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/profile/InstrProfData.inc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-18/profile/MemProfData.inc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfiling.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfiling.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfilingBuffer.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfilingInternal.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfilingInternal.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfilingPlatformLinux.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfilingPort.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfilingUtil.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfilingVersionVar.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/InstrProfilingWriter.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/profile/InstrProfData.inc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/profile/MemProfData.inc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-19/profile/instr_prof_interface.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfiling.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfiling.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfilingBuffer.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfilingInternal.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfilingInternal.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfilingPlatformLinux.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfilingPort.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfilingUtil.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfilingVersionVar.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/InstrProfilingWriter.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/profile/InstrProfData.inc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/profile/MemProfData.inc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/contrib/llvm_compiler-rt_profile/llvm-20/profile/instr_prof_interface.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/include/elf.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/include/inttypes.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/include/link.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/include/unistd.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/base64.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/base64.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/gcov-plain.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/gcov-zstd.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/gcov.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/gcov.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/llvmcov-plain.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/llvmcov-zstd.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/llvmcov.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/llvmcov.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/output-arm-semihosting.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/output-membuf.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/output-serial.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/output.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/output.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/plain.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/zstd-ds.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/zstd-static.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/zstd.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/gcov/src/zstd.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/event_set.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/event_set_amd.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/event_set_arm.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/event_set_centaur.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/event_set_p4.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/event_set_p5.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/event_set_p6.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/event_set_x86.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/libperfctr.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/perfctr/perfctr.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/regex/README",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/regex/regex.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/regex/rx.c",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/simple_malloc/simple_malloc.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "src/lib/simple_malloc/simple_malloc.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    }
  ],
  "files": {
    ".github/workflows/check_build_arm.yml": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "09f9e0546c1bde68b5b5e80028f3f9df206d831a84f620a25b46a8817390227d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    ".github/workflows/check_build_mips.yml": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0a3f0e249030e4671fd09c9b80123b5ae57a7f592c7c30c4ba1c3ff2b8a67f44",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    ".github/workflows/check_build_riscv.yml": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a8321cc9bc8a786bfc8c3e43efd6f191e40a7f7431e331c55627672d5bd3cb3a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    ".github/workflows/check_build_x86.yml": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5b17aa3abd041a3fd3f5dd50048b23b2ac39e73c4e37078f22be4fbae5c40f78",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "BENCHMARKING": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "198a781982a63135b8a0b82b97d92cd407d73844d78a0493fc33c75906355ae5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "LICENSE.spdx": {
      "license": "CC0-1.0",
      "evidence": "LICENSE.spdx DataLicense: CC0-1.0",
      "reviewed": true,
      "sha256": "e37cecd652b8236b0f13f789e4039d25be28b0d28c04a12f2ad45f0380dcf301",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3e21aae8c943e92a18b2d71351d5ed973959d428e0339be845398070b40cfbe7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "README.md": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "13676d0c25990979405d4c8b002ba14ddb31e0f9da3e3842df2bca9ed4360472",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "SECURITY.md": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8e6279a7a655c39617fd89ec987cab177c694364f6bda1a961003ee698a72173",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "capdb.yml": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1795f2ad1ca2a169057a0d0d2d898063db321183e74f7ba23a0abf656751f7db",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "data/fonts/vgafont.psf": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "81b96aa138e90f541e42862c63d8c1b14e5b6ff7787aae458f7319f469d2b9b9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "doc/jdb_manual.rst": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d94359f36cc0db0e5b5131f193830b4601823bf933405e8dde9b1ca0076350bd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Circular.max.amd64": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "78bb40e66622f3d6eb953631a6a4797286a8e46f9be88a3254467d739c163792",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Circular.max.arm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2ef84c6c62edae8fb65e202e967674ad3f033325dd7ebd72bb665d97bf3f6278",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Circular.max.ia32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "78bb40e66622f3d6eb953631a6a4797286a8e46f9be88a3254467d739c163792",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Circular.max.mips": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "506ad0bcbe0c6e7a78d7a035e3bd65cf4cd1c08f51502d3e053a8f683a4fcb51",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Circular.max.riscv": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2ef84c6c62edae8fb65e202e967674ad3f033325dd7ebd72bb665d97bf3f6278",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/DEPS.blacklist": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8b5680406c49698782f236262081f894b39d2fca050143f0f1964798905f8c92",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ebef345ec650ad12b444767b696e07492d6232d9cf02464b3c59a3f626659f4a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makeconf": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "51f2d9a216f73ee85a86bcece9f4921a29e37b0c7609d908317065cbbb8ed86a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makeconf.amd64": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c92e02cd98ece56ab374a4e683b6e53781cd22cdce1ca9128a4e2a36db4ba2a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makeconf.arm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "88b433480ecac434e1b2a782a4d11f3bb10796c76fef46cbbdadd92c5e1c4f4e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makeconf.ia32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1cd32cf0fab1572835c61a49f0b3d1013d655d398d3b049465c11c6e00c98bb7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makeconf.mips": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b0207d0812f44ba1194f9afa63a0c2d50c3c42f0bc93df1c089c06982bd91a11",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makeconf.riscv": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3ab1c714be4ea7250d4e3abbc5c38b6a8bbcf5d75ef7370c548632ba2cdb70e5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "945a0189969c7d57817a9ef340c850f8aa2035d0a8cfcbc9a37dc39f1bc1f3db",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makefile.sub1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a7ab2a6b1f5c04f88ad6ba39af3b231c62df41fac0c7cd68b390f5e6ecc7f137",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makefile.sub2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a717a2f669e4a5af1ad7fade3b3a6e6316b209002def978d06bad4157e1dd359",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.ABI": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ccf8a7d559d61c0839fed3d6e1a5c8b1d510ebe5d141bbcc6654448712731fa3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.BOOT": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f307b291f4693e48ab27989718ffecde322924d217dbf1653b578b9108821fb7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.CHECKSUM": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6c89acc49ee89e316480649d5d1f553eb83136b67ea9fad3329e10aafd36a40c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.CODERULES": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "790a6a4e44cfd4a62fe7c3d198b2af4988692a33e8e18f28373e71eafd3ad143",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.CRT0": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "290b2e02c30fb75cb4222d2bdd2be2b13810217d338852f73bd30cfc65cb7d6d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.CXXLIB": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bee582141bfdef936b04c47e2fc4b1033d0f9a0e4483f6bdc299b2e95d25f54c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.DRIVERS": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2cdad07dfe421d178d1c9414922cb1f96a1bc2edea0924e05c9fce12fff47863",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.FONTS": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e73c5cdb050dd1603fadbdccba272e086d8c0343f6bfe557715121a6b8cffb7e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.GBLCFG": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aa3c7c14b92c3db8fb60c6eca60437dab499d82dde63eade62834111cfaae397",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.JABI": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0b8add5135cbb4c3c69886214d5145e5c1e9e9e2b02bc9e06aaa75da61838bac",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.JDB": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8b57dcdfc68256f68d013804535402cbe9a19d7415110006f3e1d0cbb711a4c8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.KERNEL": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3a3ad2a336d082a28abf2b8c1cf27865c6417de6cf3a9126f5d90d2bb8c4ba26",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBC": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0739ff9cb516023c6eee747d94cea865b213a32ee58449103ea4cb249ceb6d1a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBCOV": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "12c94d84e67baac2cb4cd634e8e60b0128662efd238d091935815b648cd56fb2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBDISASM": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e4f5c610fc4d94dea8f1851348e157bed625092dc1bbaa5b530754a27bf58898",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBFDT": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eff315b6d68a8a13e1677bb8adc13e5c363335b79a2f67e5639587a6cb4cd4d5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBGZIP": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b0e9c76c64c9ee44a657ee25c188f30be2c0e1293040af171d3c9ef068632e78",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBK": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e85dfeda7589f8ab4bf7364d2e34ff35d01179e6c94a6d5c2e66d446a931d2f9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBPERFCTR": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8a89e4719d914ee3debc4955d70d35fca980b2c5c603425044b572ebc43221cb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBREGEX": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d9edae4976a346e796a3a5ac292cd629811053925d2d00366593c99dfc602557",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.LIBUART": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "24f5107d85b0e2701804fd6d3300c1b85d50056cb00d3c9134eefb3e8f57ad49",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.SIMPLEMALLOC": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7977e49cd38c191b1caa35df0a2ed7591d761788dbc517854c4dd91e69fd5f1f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.TCBOFFSET": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3925981e6c0c4781b29d2dae04d8af728785ef7f3f8e888d508c358916e84487",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.TYPES": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bd5f6f8f4fca2754c4650be3b83f58eda41c4709c8a754242ea6e240487c7f91",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.UTEST": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "014c54b60af9837cc61d8aa4e36d0bd178f407c5d36de65929587018e3283e16",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.VERSION": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "da58b8087505d7abfd20720ba523c20de38518d444c146dd3faee4d8788f78ef",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Makerules.global": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6d6bee8db641658f6d6e63c8a2cda54359cc4915b526ba6056296712ee8702ba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Modules.amd64": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d78f8647a34f928750f945cd0532b25efe41810f2f26e7f26f2704d552e8e768",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Modules.arm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f9479932e011c2de1dd93a30027a412592aca639ff9dcfb49560c0b722351f88",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Modules.generic": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b04932811171ad458c6e82990369884d68f32713691ff095493a2c6f75fcdf11",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Modules.ia32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "50bae6b8979fdcc72e45bb52617fd146273bd4f9d71ddc3469a17d29265ad645",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Modules.mips": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1f0ab6c8b8a3425b278c81d8b6a5f17073f88899b63d1a59cfc1de38067bee7d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/Modules.riscv": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "04f85a81a15972ed46a93e85f4a117750083b87fad275d3298c16e2a0e408711",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/README.buildsystem.md": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "67d181dd8ffa9ca830476c49331745c27d50c1697186141d9227e6868a3e7766",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/README.style.md": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7cf59856f84008d8f9cc7fd272746ea6fa36c540638494b912900cfd7dc9f178",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/amd64/kip-amd64-debug.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "666e20d2a9b2d0ea95d816304175291a3dc219cad16f14ac474f96be2acfdaae",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/amd64/kip-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6d35379c1fb9dc6a9b49a95f78b984aed4ae7db027c4b17e221987b5848dc553",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/arm/kip-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "afcd27842186124a9d6b2c020e09290cbf89ec467baca9e09192c0da78dbe291",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/ia32/kip-ia32-debug.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "84df65a93f82dc164f9199446343504f7858c6e61ecefd7cb82dd54dc5d85d91",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/ia32/kip-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "41ba56cf5c2e85d1a63590a3dfe25a1375c4ba897d5b804667ce82769c5b462d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/kip-debug.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2b1a7bf8f756f719a2f5595e2919c7bf5af89dd8f1587bfcceed0b7250182986",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/kip.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ff0bc7cf5a200f1a7d2b6545c069dc15dea679951f522d6d06c30ee7d1dbc7aa",
      "kind": "file",
      "non_ascii_lines": [
        "fe6fc75bc31ac368b4af2e465d71ea0d2110720d4631e7becf27d4c208c72cb9"
      ]
    },
    "src/abi/l4_buf_desc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0575c4e306913675f77a21a3b497a419c6886ee64358ab1988af9dbfc2f48b95",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/l4_error.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "50d3c5f3886dfa8d1156cc37aa9f41e4db815a82702dfacbd926a562a1b39b40",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/l4_fpage.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d5ba1797c6bd8e5383adbe41d11bcadf08e00ddcc25d3199bb3071e1c98cd13d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/l4_msg_item.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c7f073adb2f60b25905e6e4f852cee05806c323851a9f35b680baf1f5a726693",
      "kind": "file",
      "non_ascii_lines": [
        "db9e8944b90334d5a97ba5b2bed7dff5e3906a623ad41535875f461d7b5d1627",
        "00b2e0125311c0b5a16245d014f1f629d4fa79ca400e289eca146e5001fbcc2a",
        "40c68acf8164caddec0b3f12c3bc247a6eeec64e4fdf58188cd4cd36a0a45e6b",
        "c38a6f7376b9730e399a08f6d73cae98883c1786afe86ada6bf63b1f1ed42d63",
        "4ea6d1ad09e8522fb4ac35e070e948d4bbd8e0c48c0295cb780f04c0555412a0",
        "a9e778d01fb8f8a73f8de359464966e0ed55e9a193530eed620020317ab41d27",
        "7dc6b325e9e363d70a6672fa040552a834786abfc780eec8f870114570bf9ab6",
        "4d658c4cc56e39903d3af257d4d5a0c206c0daff63793046792e05e97a8c9cc3",
        "f5e88fb0f0d6db4a7928a087faff4a4ac43fab80ef80c5c19bed2e34bd22cb38",
        "f79f0b686632f1e981b77613bc04ac740ab7f9a1b2a920fc8329610870cfd23f",
        "e9b82ecb4a96fab098357a5f7c05805bdc7fdee09335114352e1dbf1bd3b76b6",
        "9db8d0c3c8c4efed8f1b29cb43b71ed5c696684deca9adc740892f41dbb41192",
        "f79f0b686632f1e981b77613bc04ac740ab7f9a1b2a920fc8329610870cfd23f",
        "15398d33f8b9b57694e2d48a90ef201889806a832fff06b91fb5f64c9a8135e7",
        "9db8d0c3c8c4efed8f1b29cb43b71ed5c696684deca9adc740892f41dbb41192",
        "01ef2879b7d26dc952df7e32e164ab332f0064607eef9fe5b1009efc2530a75f",
        "899dccb6d3b408ae71be99b54309a91bf5d40766e017cd48a70bb83e75c1de1a",
        "0bbcd814b92f40efaf2aa8d96c09c4d3865a15e9517c4f41c418f9bdf692db8a",
        "5e58f78698d1444b771d02a5e47ccffe74c2de335fac699e7866cb814deaed3e",
        "0a38f8748e521f43efdfa0096e3fe535bf08ba950e84c5620a883bee9c523724",
        "0a31f27cb454a9c2760ab95ac4a9c9c5fb8955e300f9c1955ccf590634e9a1a5",
        "7faecd205bd108b253379405710a8cf829febbb293c10ba4b0bcaa3a1c2abc48",
        "f97b3641d16c2cbad3071c634285ef7243e2d85959459fb42f6c9958f3a6eca0",
        "baf8a51ad25166bc6b64c97726670b705aeabe24c1521f586eb656fd8fe0fc8e",
        "97db7b8206a0b8a94791ed79deacddb9662616c48f3f4b40ca9d1ba52fc4519d",
        "d430d93767ac9c19117f0ca148fa8ee10d3c52a3e0c5df06299122de2c1d1322",
        "e5e6d5eefd7070a261e52961568a5b18534b655f377f76fdf682fb1c161e8354",
        "cb67986fd6aa5870108b3f769f9c273b6834dc1ec6e255691bf7c41c4da1c0ad",
        "c414ffa0d8dfdaf09d7235fd327a57bddcd3d44ac37ee52d8e4721fa44d6f18b",
        "7db764c32f480ece7184a2728864676146e15ffa53a416254bac7d8abd75b2fd",
        "7b32cab9711e296c17f2de7a32b6e6c58ec7651f59bb1f5049eb44138eef270a",
        "4b7cb3a308018f561719313023e03b6eecaf2e9984682db7e6fe2adb134af336",
        "f490b64de8ec637cfd59f802201e967128ea8d9b54922b3b7cfc1929a0277afb",
        "d891c9d02a0538a7fcd9ec255ceb1c3ced9ade0f8ce049cf1cd9da9d5f6b7ace",
        "67f22435ae441fa9c732057b4a4a28cd4bd2cffa95b7804d4092ebc0a32318fd",
        "66bb4881bbc594e64edf5bfad0d4199294bc122009337a8b5a4e3bcd5ccb4286",
        "4e9105227dbdee957fae714f9de822983381a7c7d67eb2d49665b95da70b4a52",
        "891d3dfb779866361a8e861590dafd62edae87f69c4f0aa2e3568cf92446c592",
        "024c97c0f823947dc95bd6009cea1b4d22a11da278d1a994959e6ec491ca9af6",
        "f1a24782d454a69a6a1cc66d1095112bc49eabdd71e53791c67a4786de86bf1a",
        "902df8b8dcc95989d1b490080011bf441355c31e217250b58293d39911e481f1",
        "f3ced74ff1cbdf83d20ce9b3a9381103a16ee76e8bd717a59aab301634d710e3",
        "40d6e0871b8dc16df3afcc26c2adce0273f2c61536a4ed9dfd963103f7c594f6",
        "5d7ac714388d32141f31fc11bf34926d247a56bdaff7f6e9e362aa5ef71a64f5",
        "67f22435ae441fa9c732057b4a4a28cd4bd2cffa95b7804d4092ebc0a32318fd",
        "ec3e5da472d7a52e2bc5bb7f815bf2fe98fc68093ba1d8482e8185ca410d9d12",
        "4e9105227dbdee957fae714f9de822983381a7c7d67eb2d49665b95da70b4a52",
        "be3184a6d370c76f8c2407e89ca84fdf3a542a5db26a3239d6196abac9d2c89a",
        "67f22435ae441fa9c732057b4a4a28cd4bd2cffa95b7804d4092ebc0a32318fd",
        "246bd85fbb6e9d70c6595de3245640b645ae126ca4f01a66f1d526221d9e752d",
        "4e9105227dbdee957fae714f9de822983381a7c7d67eb2d49665b95da70b4a52",
        "56f5cb2f18e7e80d526cd538373785aadcaa2525335a4a1492c0e37488889e0e",
        "d99c3424e7a12d3c4e0b0ab14e163d240d4d7f14664f7e8ee85f66b5bed65f02",
        "c0d36b3c38846d0c43a2b013daafd3c54dce0b5e1f0a67be506d93566b47a1dd",
        "d42bbcdeea76f4712fd75f18a567872e5af82bd87296be48367bd5db95efc57a",
        "6f3fc3dcf319ecd819bdcfb66858fd140c5392cdc851661c733338cf48bb5dc3",
        "eec78431a5c51be672ff1ab6f79a778f73046589a5cf182666ebae5a3fb26b17",
        "e386c99af5be13da9c585697aa93f279236010540d084d1dff2b0cf56bd4b381",
        "67f22435ae441fa9c732057b4a4a28cd4bd2cffa95b7804d4092ebc0a32318fd",
        "68e94ae37481b113829c6d1f792c9f4193a4570d90da73b60c9cb1d4ae637891",
        "4e9105227dbdee957fae714f9de822983381a7c7d67eb2d49665b95da70b4a52",
        "0a89235727203ae227af58ecda3867364201f770598801da6ba474f40c0824bb",
        "0a89235727203ae227af58ecda3867364201f770598801da6ba474f40c0824bb",
        "0a89235727203ae227af58ecda3867364201f770598801da6ba474f40c0824bb"
      ]
    },
    "src/abi/l4_types-debug.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3ad7ca2a1ae7a1f7f603da0767233d9c881d3eca0b4ea016acbf4a605f1f4e13",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/l4_types.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2f9a7549aba42191713cdca773acfd47f8b9b902fe6f3ac43404181c04ebd324",
      "kind": "file",
      "non_ascii_lines": [
        "6d87691861b1376c5b3ef1f05270d48396aaa757373055a2a31041849dfc0907"
      ]
    },
    "src/abi/mips/kip-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e14d884b3d5ff943cad8cf1117be21b74c6ad8fc4be974d6c6f9faa740f28b5d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/mips/l4_types-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1a4d98b53e3ff340944c8ebb8becb954369db74c0ab9f76ef54d3425f66ce335",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/pf_trampoline.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d08e488fbe7ebcd06e8777f0cea3b594fb315ba6056c8f8456a41a976ce8a11",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/riscv/kip-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "322e2c5d507b84924a380a73bbf680d197b866f023830da483694bfa6dc5d24e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/riscv/l4_types-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a988c5728de2e7477eeb515090cd1b50da6ca773ce1e428faf7b65201fecad96",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/abi/virt-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a4080dba6d85f05f7899b1f99c222847d63ff47c5271d12e2cae4fc4e619e941",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/amd64/Makerules.BOOT.amd64": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "89a02ff28437d3feaceb67afbab794063296b34622ac282ceadab5ce973e147f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/amd64/boot.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d43bb795a3987b4c74beb37ab9fa4e4f8f829645efd163ed083fe82feff9722b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/amd64/boot_cpu.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e624cef460b66048f51260558e6b0fd2db6a4023a8490dc88767634c7a9236e3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/amd64/boot_idt.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f9e64098f2d4d08fb139b304a2dac7205064d44fa60ff971216be0c453cb8298",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/amd64/boot_paging.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fd8812721af0d45e3003643254eb0a4fdef147b9cf57e34fa1de3a35515f5232",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/amd64/bootstrap.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3b0e06fff964e0aafee493f34c8b27a6efe40a928bd92eb6563955e71e80c066",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/boot_cpu.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fc846271e8f51664c9f81176a52fb2b1f4a519dbce4bc4b686848893d23dfea4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/boot_direct_cons.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2dffa07de24fd856c27a6e8ec9bb7ca4c89dada5a4757f56b692b745f02a5350",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/boot_libc_glue.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "511bc4598e83c0015bc55631122b42461e035742b477bce348dfdfaaa4a09a87",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/bootstrap.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9247718b3dfd32f0be5a4a756587d637dab6738a0f4c41e5ab72a9073ae8595d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/direct_cons_putchar.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b41f72322199e5145260a2691f7be51d0e93116a134dae41ec1816708af1926c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/ia32/Makerules.BOOT.ia32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8df2831079dcbd14e0f791e81de738ce36f6ee192b36b30d0318a6c667aff78d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/ia32/boot.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "735847ba694e005d8bbea0e1d4574ca0d7cdefacfca244adb759ca5d2af2a77c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/ia32/boot_cpu.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "14da8f556ae7a57292803086462d899118702f5bd0b7f40f54b9091b380f05c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/ia32/boot_idt.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d727138c3ba5b625549c2a110cd90b28aa4e8e9a9633cfeb87f4c204e381cee5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/ia32/boot_paging.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bddf78772b1ced8b12cd90c93443927ee19aef43c98a67e1f4d165272e6deef8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/boot/ia32/bootstrap.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3b0e06fff964e0aafee493f34c8b27a6efe40a928bd92eb6563955e71e80c066",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/doxygen.conf": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cafe272508f18575ef06d3f095f839bdf01d75e592daafb08ea8a443e9f2f692",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/amd64/asm_access.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "945eb3bdc5415e87ee4fc874d80525f8e830b2d54898ac2a7a548c5b7f4f7ce6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/amd64/io-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2c23ca2ad15810f7f04e4fc6e7034d5707227d88b9fd8372565ebf310a35185d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/amd64/reset-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0b1eecd1d1d6c711348e1b670ac5e3e88e0d0c0e1bd61bbcb1111efc447e14b8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/32/asm_access.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1bde2057f09f36a14eae53033eae13b1f6051397370a354309a4797aac8a997e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/32/mmu-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c3efa949d23ebc0ac31be7a74b737feb9320ca46befb333b736a1ab80045d5a1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/64/asm_access.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8cb852566a044da2d68d42b3c225db2e143fb81112e92e8700121e6b25709fa8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/64/mmu-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "30e9ac170ddeb2c3666c5816499e6916e2eba3f63c004b49fb39dbb3b42b9b4a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/cache_func_gen.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b730aff9448b4fa3dcedb214b0ecd787409e08f414ebbff23b71f504c261c279",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/io-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "387e619109eaf572eab9a2f355b2be07d075b67b6ff4c5f628e8fe5cff6f29fa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/mmu-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "274eceb38cee2ce52856714bd1c9106b056a6d8f639e5f0a3f4e805d5809fbc4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/mru.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7805e55ec8b65a692445a79feeeafcb4fa30131c6efa103c723b8f182fd27c35",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/semihosting.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3e478612945fec37858d39d5707c515a46bd69c2d737a20255d4c92a607a3a10",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/arm/ve_sysregs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8d58250a87cc78bfd528f2881884dffab9c23e0f01bcfb9fdc1cd5e361473461",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/asm_access_gen.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "271010716d6376f0e867eb9aabafb2109c9719247a08e5cb920720ef814fd521",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/console.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "371bdd477428514c805835b6ff42296a11a40d94c6cdbad8d00fbf383fc9a628",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/delayloop.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "63fe64c31367d8c703489c0656965d0cd91d7483bbe66f9316c7b1ed05a89ea0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/fb_console.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "912a7c3326faab04c08d966f3f0257e64004d4a49428207574819c0e08dd425c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/filter_console.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e71a27d811841ee6acbedce5198836c529e1f1ba293350e66b748b3717a4f10f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/glue_libc.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8fb29999b4d150a50b8aeefbd68d90ecd4f35df51d81d72ab0f3cb0440d6951e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/ia32/asm_access.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3834f2909fd53762882ab3579e518c851e20fd42c60467e1975ebbd8bca4e46e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/ia32/io-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "89f3d4351a5ae78b44fdb5314162241bec119ca1068520f753092b421e3c93ef",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/ia32/reset-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b7ad3b7851c749eddda858812cc9e74f40f329015bdd94f1bf40a1ed0cede1d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/io.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "421822959f826d714a5d5bcbf168a2fb4f22d4c67a1d68d6f81cff7b01435929",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/keyb-pc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "777cb2be994ce19af0e44a11e97329ec0277e844293b1a8cd9f65d99817106b4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/keyb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ac41652eeb6b8b176e5009d239470354e939a7076ef10713c675391654becbce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/keycodes.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "854ed9093071d3c85061f3aa47668d79efd12a2d7fd811c32dcd4ff0b7441558",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/libc_backend.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1e942c030b0dff1a919f195f77a2108ea74d3a69c7be0dceae6e3f9c2e53669d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/mips/asm_access.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5ecb66271e324d810c5dbf66579ae7ab679dd99cef4745635bfe87d9d7250975",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/mmio_register_block.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "979f32e85f0bda836eecc56cc42b22e184b6b23a42e2d80cc3e63f64ff9c879b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/mmu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0f448d7bce8d24ba80fbe6ba53655d26eea9848d34cc67bbc2c8a0889bc2c4bb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/mux_console.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7d6e273da3035b5ab5167d368dd6e9df6c5a91b7f6ce266caab03a1d4df66f68",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/pci.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "348a2f9aea70804a8fb22c88bf2531be11e6f8bd1f11b52d3c1c1e4ff811ac5d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/riscv/asm_access.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0be6ca8a86df48d76a2387e7efdf4d590c99aa4d48205257d52caff6a82daed7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/riscv/reset-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "24cc13a04e60f67f4b87d86a14f70e7647e2ca811e2b88c1d31c4b9690353317",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/riscv/sbi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6c79617f80b4b8d120f59937372d86a3ad11f101fbf527547a6e1a9a60b5160c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/stream_crc32.cpp": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "c74ef60354af0ba016ec7b5dba81075090e6c307f1717518d125474027dc1a84",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/uart-libuart.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "406f23e48804876b8b5c17dca4fd9f3accd48d583db6eac6174509e1910985ec",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/uart.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "62eeac8a32653dcfbd1c18a64b816761498c11d5b714a70cb19acc633d2bc436",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/drivers/vga_console.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "95246f911df4132b1844c6f0b61e5f531566c0ff2d9a87e28b54c923b4d244cf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jabi/jdb_ktrace.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "314542d7588709ec04ce91d670a5445b4f082d8c9ab8a2e633d3a473f6fefd8c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jabi/jdb_obj_info.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ea52415a4c26c492e5e1b110ca59c401709df0b7f62220bb9c18a444fc3ae6ce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/32/jdb_tbuf-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b26de516f31b4b3dcffb2e81789dd93ac7bde8d9410f4fc52c4ec71ebb2bbe64",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/32/jdb_tcb-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ffe679ef0cda047063b81ad68ef9f482e0113fcd035000303e79b1e1e4f747bf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/32/jdb_trace_set-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6c4a291f4a9a0c94ff6ffd8e43b3cf6dbafe03f61b30a68628b9bf6fa53b7cf5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/64/jdb_tbuf-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a95eeb8ec01728a4effc6ea25d6ee2b12a7b9425c08dd12833c9b4bbc4ce6c07",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/64/jdb_tcb-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f11fa84bcb379a8322b903ccaa06b17884f170d187244a6f769f3a5591b5124d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/64/jdb_trace_set-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6c4a291f4a9a0c94ff6ffd8e43b3cf6dbafe03f61b30a68628b9bf6fa53b7cf5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "71ffca2317c59452f5e12cb7d07dcb6a535e69a010e974ffc592ca5e6308f31e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_bp-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "167804d90ef64e6494837ce20f9c595034b290998190e32c3242274bb0d7389b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_dump_entry_frame-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "365002c945dbe9051b42f1df10bbaf5ae9471a5c6efadf81dc7ff11658e4a7c0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_entry_frame-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "84da622ca81b4a5fc5bbfd62f892098fc2b5b4dad36b652e3b1e61901237c31c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_kern_info-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c9a401673de3ba4806d7f7f70506ef1234aa68b6b6d04907d752fab079f42f47",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_kern_info-bench-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d54b651b728bb92899efbdac651a7c8f5ea45819001efa3c4e4136a3e3d7a03f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_kern_info-cpu-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f7e17e3171a95135e678b281abdda91ef851adfdf319ba0a242a20e619f20580",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_mem_dump.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cffab195f0a80e45588af928bbe78026366f4fdd6cb03ea749ec0195dd9fe88d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_perf.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2103182581bf2e45e7e1b5a453c912da041a6075356d42d275344fffc96f8710",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_ptab-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fcb3d061319d7837cb6be510fd3a420d2f891ad6b4789dc9106c12486492b376",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_reg_dump.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d5eb66b0811a6ab280c7cf387d8115551f49b745dad6c12f871f5524aca95185",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_tbuf_fe-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3b8ea5eaa3055a9b81a0f051e12e4f7c794be3128a16bd2e6fecb15d779cdd2f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_trace_set-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6f96427f56fd52366640a75dadd8c525de08d6a47da821dfced2917ee47ca21d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/arm/jdb_vm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2219278a794c4bae7130bddc74b026b8b9cac12f4b4f95fef1d505b4c6eced8b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/32/jdb_bp-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "466c5dbe9066928fa66e776ba9092c9901a58b408a4e258a70a65e4f33741a85",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/32/jdb_kern_info-bench-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0cbd8babb4a178c40558b2bfac42de4bf5b4be509f9cab938ea26c57cb00e039",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/32/jdb_kern_info-bench.txt": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a672a861ea3dc438b91fc28a4da1b0d1c5853de1c94a938c16a82e22050fed82",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/32/jdb_ptab-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5cd57baba34fcdacb33bffa4747eb901e36add5d4dc7c4001d653c26fa77359a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/32/jdb_tbuf-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6392b4db37335398debd86ba3052777400eef09782c4b81ee6db15d0fdb79377",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/32/jdb_tcb-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f43640388d625ebaa4c67052617b52f523a9802ddd705c73c00b18a14da67cc1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/64/jdb_bp-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "86cb25bcc19caf48b7b106f215e213c3e03d7d51cdc73344ce23d54d91cd5a50",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/64/jdb_kern_info-bench-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "acc69619fe283288787cf53ac4a60ce99299c700e148348d1b85a762a455a310",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/64/jdb_ptab-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c5aa03bebaa723fa644c0b9168ed5b94a514edff161a08b0caddb4b20befc2d5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/64/jdb_tbuf-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7bf24667796493689b676b563e7865d90c79a980c33bac0c2476483159cfb8d8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/64/jdb_tcb-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8af022a654222e7751873117f689b4cf94bd557957b190f7a6b4b153feb6d9a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "18a077f7475809130782e3d6d96759f9fd99af815093a718c7bb775ea490ff5b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_bp-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aee1b411d196b44dd88f1d99ac1f34c84ea6df61c57b2454ceaf2cc764082612",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_bt-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dca71766a58ae04f62799db12de50058be74e52e1c67aacc6e8f287150d31b4e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_entry_frame-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8e9312d25db96c5aca774d6ad6d8004b3e8d256e243a0bb1268c65f85d5ac3f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_io_ports.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "afea62e1583d087f015a4f44a902339fd86252a013fbec2fa94f5044a3f68190",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_iomap.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "919d3a45fc49eb9d1467ded92599761da0cf82dda44fa3cfa7240594c04ede45",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_kern_info-dr.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c1ab4df7e9eba888004379a12432138e7ab76124c71459550731237e715c5483",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_kern_info-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "122fa4df3cbfc85bc7c175c4b6faf92730f7043ec40ce3fbfa2cabc53cf1ea03",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_kern_info-mtrr.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3497d90f7906c6df89c1e6f14a2d68201ddca50f07d3c2cbb3fa20bdada9707c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_kern_info-pci.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4328324f58411d06645cad1c8821c36d5a4b632d5410ed593821ba94b8878a9d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_misc-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "30cd12c01432aa6f0d7a422382ce89e358b92e568c57f5d4f616f76a88779a21",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_screen-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "46bf7d21bc19e54a29e5ea86081e501c1c12455cc16a895af5f01d03bebf0bfa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_tbuf_fe-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5a88075353046e55c410f321307776c7af19580b7b76aa482220d5fb55abae48",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/ia32/jdb_trace_set-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "772b59f147ede103dc8ddbc4f54ae9c3fc0b95ee187053ab5b0976661bcabb38",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb-ansi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "00fa798a86ddd6e12f5796fe04f3f872eacf08784fbd76a1c21b1e03db56bdaf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb-thread.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "533edc67062be014368bd3e2486672e53cdc135c7507ee286b88f40c44a1e8c4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ba320b89dc49a75f34c1c21e8fd4e5fed6b1bb43db227cebb098df0f033604a6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_attach_irq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6c036c77ac0b90a1f68da3afd8799e0b98ad45cf3138c3ddadc4995253026965",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_bp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3f10b931eac34cec5fae55b1f301f974ca053543a8897f2eea02b4f9fbdef0c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_bts.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "90f3de3dd632fc7babf6adc2dcf660e74a246267df1f9669d432ea153a174d17",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_console_buffer.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ae3eb1a81d3159aba6bbaf83f5419c1c21ab506d28c26242c6a1778e2d560a7d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_core.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0e17703a247747079287d895785dc9494fa2de0a3195f8c0d220ebdd8ef5d125",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_counters.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "874e1eb3d5b9055d66a4d2d390d0d68cfa2dd77695313d70cb267eb505dccbe3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_cov_module.cpp": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "5a405e10590d366cf130fe365b56ebbc54737703c6a1c83709b32b5345b91a3e",
      "kind": "file",
      "non_ascii_lines": [
        "749da954a61d0aefe96b14bb642e4c1972f01131fbf0d10fadee84c62d9110a5"
      ]
    },
    "src/jdb/jdb_cpu_call.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ad2058ef8872ee936155480dfcf11fea63312e3b3fc8be294d61c5cbbf332b4f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_disasm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e35dc74224c24a0415f5b2c8a5e16791a5732bff766f39785bd83b2bb419506f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_dump.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "36855577b9c9cb4f98481ffd4ebfe7cf686a9ccad9e97d3709650cb28853475b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_exit_module.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "15f7f57faee83202384115c32ecef5f567dde388d2433f4fa00a295e4185d1ad",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_factory.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "069dbf19882eae2b0fbd531356c4e95ca21934bdcaa4440a08dc61da854c5075",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_gzip.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ad31a56e3f00d640a41c9cf72f8c3ee3f26cfc2130438ba1ad6ba1e6b49a38a5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_halt_thread.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2c0f400b8b2e34703964086841cc562d825feab22752d05e78452f473a094a7f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_handler_queue.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bf7d15741ef9b507db1ed0828380eff9619657b9a9a59ef9082b42226fac1ac2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_idle_stats.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0b1867f38728a7b832c0d5ed90116b1654983e1b21a7e37da47587b8e2eb0a79",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_input.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8cea2dfc6a6534a57c237ee1748830ae030a39cb2a1cc8c5c5ae6b07f1448166",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_input_task.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eac27c15e1678a9563f3d4d5b32f8b4a014e90e16bd2fac0718454da449fdd1c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_io_apic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7b9e47448d6ced024e9b4effd9e5ab351f895e68a7ccb2d8bd2dfad153ebdb8b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_ipc_gate.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ae4de773e102ff567757d9137f8e09bd9fcc2030b1205b10336d7903eaf0af70",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_ipi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f377fc4be0970fdd2320e0666dc299da15886ee09cc25c9264f286e478a09c85",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kern_info-apic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c446a1086fdf6de52187fce508875a02abaebdf9e9e03d8568c811a3b398eedf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kern_info-bench.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bfddf854db3a68ea2856bd581ca937417860cec3034230f0f8fc27a4a33b98fa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kern_info.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "78e76c38ff9658adfd013620104959387b8bbc9531201b37c9ae5835322aee9b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kern_info_config.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "398ab04e31a37ebe4c66c1f06c3c0984e20c49c96b3a3b8befee464b0be7bd21",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kern_info_data.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "130458f17adc5a285663c842e54184c03dac6903f0653a439a3629c7ce02537c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kern_info_kip.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c7c7f76696645f0f7a0b958c8457ed3e552bf0cfbe0015bc639425cc44b30dbf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kern_info_kmem_alloc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9624d04298352c965f098d2dd1584bd089f4386ebca78e15ae774b0a25fb2c62",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kern_info_region.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6039f32b412cd7fff60c843c58cf68b1c506f0847ee31629e9dd7ca8bc727740",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kobject.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "959713da202b399a554c51e95ac6813eb3c93eff3f3183e8fe02ea48d770fd87",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_kobject_names.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9a48d5deb67d2902bd55f60bf7019c2d03762ea01aca25d91fc0069d81371071",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_list.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "36bd154ad97c42cb1b2ac7a9b37df69b849057197a82612c59faba4ecf9d37bc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_log.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e3e8df17a2cdb49e43542007ccf51d58da56be4a28125b5bf25da79de8b10373",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_mapdb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8e20d1238028c445f4ad83cb1868b90d9463a9b2ba81ef03d81cf3d9d373192d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_module.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b64c3368d0016ed677bb5d1e8ed66250f53f68b3e81d66821524ddfe7e1c02bb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_obj_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "332b8c3da0f2bc1587efa3977988ae4912de1151a578f32c3037043ac88edd7f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_pic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "365ad4d591589d3115f34add65d8d7779e07d925cc5d332f3e66c6a238f38f28",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_prompt_ext.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "10eb7e132af78c19d6482ee56b58b0e0b8e1d9f1ea88ca42af636503e0255b47",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_prompt_module.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "09d21d0a46618af03fba7aebf1b0eaeffdcc653193d3a5f5313576d08af84aa2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_ptab.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "54125244b776d89af9d13d2efcbece936131984404ecab4e90d4acd73d150578",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_rcupdate.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bc316e9005de6236c722bf28fed50957cca824d0cc85a0bfe9a2572543eaa9c2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_regex.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d6133195588c6af175a584a32484e79632f493e14f4ec04c4d9de8df90ce3968",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_report.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5ca7e5765c6bbfaa4832d6cbda1e8ccf176e3a2f848b139100c115d3a04513e4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_screen.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "108a3b98f167b635253a923e973725cd28e594be243d38aba687174529dfcada",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_sender_list.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d651ba4d9bd55e7b6e86346964b6f8f946e0c88ac76a24f58eebd21541d6bccc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8a4a014de1e9fc1d332d8ed84db3e43b946f5ed76acc62ebb3f6d53ddeced0fe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_table.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3321c9798427c1ae2bfec828a39c8dc896cfdb14f244dbdd49a6dd886e6370bb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_tbuf.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "628565987c13531a798f4d0a413a9230754c545521e9146b2c7386088eae7e4c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_tbuf_fe.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2a396ae84ff3821de98770c3853ef5d0b7f8eaba2c0b930c7ca0d5323c88502d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_tbuf_init.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "31092ff0167f03b7228a01b1c3313485eca833d674bd49a210943df618938323",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_tbuf_output.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4bee2dec25ed277f1483ad99e2c0e23828a9bdcb4bec898455b7836c6f4b7520",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_tbuf_show.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aad354d31809d48a6ebe29c97cdc9c81f32df53f3bc6b302f8532752822b16f9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_tcb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "73758727612d9d785b4176251017fc1f46322966388ad326c491d3e994af7dd9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_thread.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aa5d1c604cc6e6a9bfd61343d40618e99c9562eefdd0a0cc523a153ebf50171a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_thread_list.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4c4037c9f46dde802afad51ec8ecfe93ac2a294e286cdf8011ca33e169119443",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_timeout.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7ced159e944a5c17d685cea12eb74b017f17d3b927bdce26afe5d095d03c3f9d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_trace.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b01e1377d0cc04120b60641fd49b6a2212c0859429636f86d379b4c329dda77f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_trace_set.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d0148d0ef05b1aa774869a9f512541dd274cb34ed35d0eeaad8f3938dd2f6909",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_trap_state.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c1a19b4db8155072d11085492313a69d35739bc625cce2d4c30b9b754f651176",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_types.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "164f7cf901e5d096c064613502c4c9c79239716bd811ba062613aa6d58c89a03",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_utcb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f36631471a16c196d97722bbd3ac321ab6735683c0813bc989874347e4313c30",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/jdb_util.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "83512624063e95c240f9256124d1d852d0047c3069b86ef7ae29c83681f63760",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/mips/jdb-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f7e9982cf38a373d8c039e9d6cb297de13475b6f63cddbc672c3f0be934a8b6a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/mips/jdb_entry_frame-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e02ca3b3d7e3da0df6c85905280df6a67592bbc7197f8592e184960658797fb2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/mips/jdb_mips_tlb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4823b45097086bfd671ca8e00021cf1a28a0b0b7d22498cc9605c580b37fef32",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/mips/jdb_ptab-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8ef3c68fd36f288cfb7ee73d84b5b0fbefea9c021e9e362ac456150ae326d189",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/mips/jdb_tbuf-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aff4efceae2eca9b963ee39636fe55862f585104df473ff8db12f379ca3b5d8a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/mips/jdb_tbuf_init-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f1cf8376b08076cf9477f7bcdaafba460d1e4a21976d32953c42c20d5d988215",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/mips/jdb_tcb-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "18e8722ca35626b6e20bb927691a109e39a106e67554c42d1e80e338c485cf1b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/mips/jdb_trace_set-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8d449f56237b9ecb7c627a8c0e1e9733e3847cdc45c2b0b8790e473c88992fb6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/riscv/jdb-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "38e428668b6e8b8d07911d85f3f0dc5d6ee479c64a4a9a40e1d85266aa96388d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/riscv/jdb_entry_frame-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "53bb88cd963672252ad6b628d58818bed2b89aac0a52ff7583a3175a4521557a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/riscv/jdb_ptab-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b025b381b4a60dead24a171c47a24321172a73e0be3e72f7ca8363d526ef9b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/riscv/jdb_tbuf-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ce509b2820efdf61dc228214d8e3f7ac89b845e1d384097c7ce798e3ef55fa3e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/riscv/jdb_tbuf_fe-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "db326e3205d95f182a6db78897ee384c56d95049a00cff595637ab5943b9f4dd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/riscv/jdb_tcb-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "114c352b601242d11c213027851992197181a481a26a17499feee85a151d26ff",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/jdb/riscv/jdb_trace_set-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9a43df3593854da558c2a82585e8941573590e29a1d5e690c1bdabfa7c24acff",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/acpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a42caa37b186d9e534e26e311d619eea3c718060c651a16ac145d3aa04e32ec1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/acpi_dmar.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dfef38f9d357dd55dcb3e5ff5cb0d453f0511519c762abdb178387772fdf4621",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/acpi_fadt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "502d98754c35dc616701e6fc8e914925792866467fbea5114c7dcf28ca4636f9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/alternatives.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4b694c51735501543c2451bfe7658432bc20603775c92ac40f801ca8caacf3eb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/alternatives_init.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a15003640b2cf28db563b49db5356a96bf068324ffdb6dda09944266db0296f9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/amd64/Makerules.KERNEL.amd64": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bc6730ab6b14c7c8ec746d5e9ffc380c5c982545a3cd671ada7c037df018d39d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/amp_node.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "347c7f1e16abc364b846681ef173b7a93533372be97414443743a67b572e7e81",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/app_cpu_thread.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "436fb1023d8c68ef26848c86a6ae84f4a1f51c00e5f3abd68fdcfdb8202982d6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/asm_arm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "165e0b82bc6f35d1eabccb754dd418db5e5c1e04c009ada66eda39cea3c07b25",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/asm_entry.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7e448a4f085c5b338f486638256075f69f09cd384ea5f626be94689e7f16c127",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/boot_infos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "058bb85d0b8a64d51e458e866da09da7c0724cd7ce271ddfd43825949551c136",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/bootstrap-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f048dccf416d9fc1dae1c1f48baf65f70d3ba346b42b30ca1c564f12bf5fea8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/context-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "995b86423cfc0d4fa42716fb733a2b7ee8204007fc458ec093e4afeffdb2bc51",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/context-arm-hyp-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e8e27c5d9cefb0972463ab16cc858707263dbcebfcb978cab158b5a48ed23642",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/continuation-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "876597fd52f94b823c7cf691f2a2a82d567ca719db9e416f7d76e04c587dce38",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/cpu-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "107d54745acd265ade1fd68d2ded3f5f89edb367f3f4bdc9fcc69b92c0270499",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/cpubits-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0d8c40f5207881fc4e21c6ee6cbaa32e39745cad866a7ab5db9ac87d01a35830",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/crt0.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2caedfe1130d1425445f0cd17f73af55d91787d20f296b57c9c69a86752f65b9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/entry_frame-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8a584f8bfab1407ae9c7bef4a3c66f3bda70ac0cc83d5eac44000c86d3d5f8c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/fpu-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f59e873cb24dd30a3afda6512aa47ac32235da069ffe23af6e4ec0739947472",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/generic_timer.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ef4d7279cc54794305b91912ff5436c91f46bc32685a5ad5ae59c711aac14c22",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/gic_cpu_v3-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7c65aff34240e168e9830cd1678b529ee27692b9278ee3ad2376748219ab61a8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/global_data-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "050558af7f8f6b07e0831fc8bac880d2d8053efee57190353098e8f52c3c1b14",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/hvt.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8e2705df40daf0088b6f5fe499f7541b608b1410825353367fba3c41ae9a6512",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/hyp_vm_state-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cacc671301842d08c43bbdaa6153e43db3ac6bb600dc3b88c0f5de3130ed6510",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/ivt.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bc70259b850be175c462e4863715fdcf1b8d6ac7c00df0a3875e6bbbecccc404",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/kdb_ke-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3352aaed673e4989d0cd1c12d4f39765fbe43c6c8fbb520172222fcb748a9d80",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/kernel_task-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "10977d31aad63385122bcf31152d45eb3a64a869135f067c909e3d57df838b6a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/kernel_thread-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d1528b204645a280e334afc3aa9bac2c77671d02593a31f4c114efec89c5d422",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/kip-time.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "215f30ae178053c3f24aed77b8a7f314a2fdaa1164f4cd9b1ade6494940ec4b3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/kmem_space-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5d49f0827d9b9f18836d601785ffa59d7d7fab895b7fe6651a68e2d8071673ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/mem_layout-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a757a1652832010066e7c68282d057002245719adff0ccdb54d68d3716ddc8e1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/mem_op.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c99e49a2d4bbfb9fef30b62d918cb7698cd1db660048229d1704a1b661170836",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/mem_space-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "889ee5075511565421f1b2ddf58fc00f10cb185cd1f4ff11f3b81096a01754d6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/mem_unit-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c1de2991956b30ec16fc6cf1f0523fcf63fd6975c3c544e2bb1af4fef544c25e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/mpu-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3d8c222ae1982e7fa3ef3e5faec34e4d3e11ab09e9c5392f55480e301e89342b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/page-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e25c659b2516fc9fb08ea79f767c9d875a9f80474559db204ae9c206ae760a38",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/paging-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fdd51854efce2ba4f7e83e32dfc5e36c8879a0159ca2ebf73a00c283911b240a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/perf_cnt-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "60ebd5835ca42b3ef9838bf5207cb44fd7405810bc951f8fda58274dbe72e431",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/spin_lock-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2e8bca8010c3265efeaa7d519589bdcbd7d9c45e636da0a31a0859ac46dc2449",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/thread-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ce4f0da057b8d786ed2bafb69a6270e12ea18572518bd66d116c57bd4745f88b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/thread-jdb-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0f351767bad0af5769602e1caad2a1414167fa80ba6abcd83516b63f79fcc05e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/tramp-mp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f823cfbb0edb4827901d3621f94d332f77adfb67f511e33b978914e5494421c5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/trap_state-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0ebf0b45e70ae2cc6a9b6de389eebc6f73454b73d6650a5cf6217b3b7b443413",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/trap_state_regs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "89d92c8c7b4316df3481746fc7f71643774ee88a2f1ca76525b00da7fb74ebff",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/32/vgic_v3-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "99336fc5371a8548cf173240a48743e9a86a2afd308c4e73b4dd9b3afa61293b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/boot_infos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bd84716dfbe2f2be589c2f01fc8dce4531ab88154ba70a6692c8b76436ad8bec",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/bootstrap-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "51d1f2a03028a5083b973faa0cb1922869f8519b91d99b5b2069152e408ddbfd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/context-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "103340883cc50c22072fadc6e3b255ee8f3e956068f6f938f19c216024cde90f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/context-arm-hyp-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6d399fbf3913cb634b3cfd2ee144876ecf0a4d8af5fd8a80aca84b2672610d97",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/continuation-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "58786429b16a4c187397be4deb88314ebc1aa26b1a71d4c7c8f925da367fe9ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/cpu-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "290003b7a116cc335fe2220ca3855e18503aa74758c3367a1e525c5f1c44e82a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/cpubits-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2afe71976e1fec638c6d881545bfb64318263a0795a6d9f9417669d639c11435",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/crt0.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "08649e83eeacd96e18a3f671544e0fb9cf77e52c4268cedc32c24eee3b635a3e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/entry_frame-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9432ce01e1c326c44cdcad15dcc9b5fb854a4e13fd6e7be500ebd44e014fe361",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/fpu-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3454508e08aa86ba2583486af3e0321253de0089995163f37c8bbf227b1b7c4e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/fpu_alloc-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ffdbc11ac8d5e3079c08ca82e780ce6444bfc3f9f9147b0364fd9e4d54fd5ea7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/generic_timer.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9a9dac9f0dfda1f81b46dd87df87748f2faa14fb0c69fa3daeb6dba59aa82eec",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/gic_cpu_v3-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b4d2f0906869467b9b421029cab99e67cbbce75a9ae027696142fe961e2f611",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/global_data-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/hyp_vm_state-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "73a43214769f7dc9afd5815c018d74ca825151eb2728b56c1bdcb9436428fa4f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/ivt.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3fcfb8fbf75de8fba2440868e2315da3561e6b85ee74dfe316e2adb1d6172f24",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/kdb_ke-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9a6c47ca755ca8df34f2bd19faa0c8663882fb15ae2c12323f88c5b453d6cf21",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/kernel_task-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6025be0f807f24212e4a1bac780c5abce293b12492b3b7f0349bb41ac75fdd0a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/kernel_thread-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "994e9c149c0c74feeeef696dea581d2b27b08efeb2770d4d7460a7f5f0411157",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/kip-time.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fba2e89262ff4e0e8508dfe88f918bce2a10fda8b184418cbe595a858a7c20b6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/kmem_space-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0cbd8d987c4d7abce2f4bc26e169e840980314dfd89d1dc84f66d1ecb00a40cf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/mem_layout-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b131a7acecefeafea8fe895f5c0b9e00618a8e5d89921b2bd7027bfe483dfcd5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/mem_space-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "82c1007526b7d1aeec9c64994b56f24094a6a37372c8f4488fbc40a3f0d36686",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/mem_unit-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "16cf826ad5df1658b44bbd38e7e2c7f73a24c0a652626216df50dfe6c32e6701",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/mpu-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9da187f855bb56ed5fac8e7701d6fe56ce070b3a689b5aaee1734ca99afd7550",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/page-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "77ea8792a43dd2ca6b34733262bb26ae5ee26cecebeecbd94ad75abab2a5d1e5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/paging-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "de5d6466510dd3142efdd622c821fa18e636ffe1982f8ae3e329d7db6a404d75",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/perf_cnt-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6e7ef2622b9532db38bdef0386d275b3fe4df8a4cc1a3c06b3fea50d700e5084",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/spin_lock-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "77dba37b5b929257e7d81c11691633118e3f8d69d2c7058d52fb5c7e03dec763",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/thread-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "60ce8657abf54ba65ee8c97df651afba7dca98d8ddca9b6d9368fcadd0d2fe44",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/thread-jdb-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6f543e7215a7196919c74c5ef14f373ec371a4bc4bf1fef22eb1f962bf74f4b3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/tramp-mp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9b1aa9aa18fa577c53a5fb58187830f1257d32b29caa8d3064990155268d49be",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/trap_state-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fdebe93449e100993a6fcc876806bf73b69ddfec1ed03b45d1c5d0d35a569bd7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/64/vgic_v3-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "67b7f8fc49f898ae567910f65c246523072756a8793e6b0d1bdf97da892bbda5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "43dd2362fe24035a39624c6692e54a03408d1986695eb7a48f7024efd05f89e6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/Makerules.KERNEL.arm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ad5530f5b9faff560440174b3eac38fa9f5fe20bd3a9193921ad43b56458f264",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/__main.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ef432136010ab4c0fdfdf2d395438f71309675b5eb25296872f82d2ad598e9c1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/acpi-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "32fdde36ab18ee267fcfae480ca1f3e59e1675ff122bc87407bb574f33647add",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/alternatives-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "550e8497c15206c042b44a3436f6a4b972bf265d877f3731d186646301e443e6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/arm_dmar.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2d48f0eb5e3c0382c84ff85af2faa4d2aaa8400ec260f02de62b89339bf7f9cf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/boot_uart_init.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2d0988e4a92eb9c761bf844f76bc128a7a7be1dd0369b72defb127d4738b162d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bootstrap-glue_libc.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b6da3478ab716dd91a2d5824f67e1695acde0c4a13d065792cba5d78faf63840",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bootstrap.arm.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "694d127a30951029020e6cc0e27a5e743ffaf82644cf5afffeee8e3ff70803f4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bootstrap.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0d48e8c9da31d17a5794704615034d7b9a4653b8694b9dae11e325b84514738a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada37xx/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1ae1466f9dad687ee21bf3094d8827b992444873a58218b2335752561aba6898",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada37xx/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f6d304921c1cb60cac5ac60eb98f372aa6a57eec8e646378c0e87efaaba3169e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada37xx/config-arm-armada37xx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a1405c1e5a09321822c0b1e31c42e29362a1ee93d40c595e2d63e8c6945492d4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada37xx/mem_layout-arm-armada37xx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "457741ec66187c378867611f74ac2380296129bed744f7c32b999a1df9c26156",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada37xx/pic-arm-armada37xx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7186efe489ebfb0910129508403896abd38d503473462ecbcca5747b98385311",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada37xx/platform_control-arm-armada37xx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0bb4e0380f0dddcffe6cf9ee5d60b2a14442a00bb3d0a6471e5c4cd0072ed7ce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7d3d98d1d0ff2bd8fac51eee113ec23615c495625aff7dc1de1ef9a9786588d1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9a2cfd3f71e6081da9673b698f1c8144b72974f4ed8dd8cc16d6ebfaec4488ea",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/config-arm-armada38x.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "61f4ddef28a81912d9494571a30fbe202569a92fc90eb240dc97b64fd96763cc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/mem_layout-arm-armada38x.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "29e7b6e754539e78778afa7a0c8f2d540444f9af1d416f0664b6554534be20eb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/outer_cache-arm-armada38x.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "df512cdec1f1bea3e35bc8d9cd4832ca903ddbb4fba2e61d707979d6b5d5dd68",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/pic-arm-armada38x.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "79ef08e2802a0d176ecacad8868e49b7de485205cc106caa73c9e6e4afbd1042",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/platform_control-arm-armada38x.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "990674753c76ea880dd9988ad11f99b5444713e469bcf761552b9dd50664452d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/reset-arm-armada38x.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f40873cfc4cc849e28c3951f0c73f043edbb450c2f84a6b51a80da34351f4b5a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/timer-arm-mptimer-armada38x.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6ec12dfd137736629a951177ce27775de41a98a5cd0f1477fe66c317b27c695c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armada38x/tramp-mp-asm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d92decadc283bfbd1e7ea3ebb80c2262cb25d38352708b151b51c1b3ab35550b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armadaa8k/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3db1d7b4a4e54caa428932348c9d906789e77680b3820252edb05a3b6285dd78",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armadaa8k/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e93ed0d33848eaf7a8398a9919cfd660cc8321f29f92f05671a14811c1627f64",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armadaa8k/config-arm-armadaa8k.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f7ae2eb01134c5224f4c78920e71ed224813c8c39d9c50abdca5a7b591dc7ad",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armadaa8k/mem_layout-arm-armadaa8k.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "338466934ceecefe2afd389af0be077ddb62018eafdf67c55132fe2ecb7652a3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armadaa8k/pic-arm-armadaa8k.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d9b66273aa5b328188d777717098c0b3f6da7700a401c75db5d502f90be6f23f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/armadaa8k/platform_control-arm-armadaa8k.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "76d0e913e8235af1f575539ebdd23bfcfbc14165ae502df4d245ba10caf23d6b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "600ec7d92832828f76b2ec71f0470fa12c997b4c0d9973f4d7683e7afcb5b531",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0e94ec962322a51c24d75bd7bc8356aed42091cf9f82612394613c4f11d2d37f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/config-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b2539e96ce917c9fc9eacadd59b32ec232af38306e89dcb35d2b0b80f2b13a4a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/cpu-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8988d985103689b59a0a5ce0a3c0b444235c54246e2325f8ac53c70ad77c0f29",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/ipi-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4c19ca3289121036ba9d2747ecf4edfd9a3ece159272fd3fc9cb2cf33778c869",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/kernel_thread-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d17e70c311338ad77d4f2aeea99d428626d9d6a89cace4485d19e056f0bf54bc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/mem_layout-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cd6d6c22f4c24e5e21b5e21f34fc2ab398d2d915f861b4792cd86e147c56f612",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/outer_cache-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3366ff7dc44cf6e65c923b5d8d4e0e42eefb2305972283ef1cfdef2c324927df",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/pic-arm-gic-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ada86c9280e6a3205f6a8eec4eb6a72fc4c0589bb36d4d25e9e1dffa7edf8968",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/platform-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ed15a4209652ed6c9557c9e00ac2351202bbc2991b3cfe869eed63c4134520bd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/platform_control-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e0e3a79f08fc8d38302910b7bbaf7496ededed4148b0eb76dae7802426a27367",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/reset-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e4a16d312f890939f2fd0777598e5f965a9c52380e16c37bd92554bc3cc8d62e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/scu-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "611cc1699c2e3abeb240c251b77b9d19e512ce691414d42cd173b906319fc9ff",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/smc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7daf54bbd9d2ae99b3e09889c2c1f4550595939b882cb3b4e4cf02c5fcbcc3da",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/thread-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4916d0531cb1db32d08b2471fbbf27f6e2fd5c1a16bc0fcf6f4f5f78a93cd4ad",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/timer-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f86cedd249f4d01dc158509265b135a4cbb873dcd01bdd42155905c1068a8bfe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/timer-arm-generic-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b5a9845bf7911431579752b897fef875c8c9ea698d3d3d5a53552a8d8043057",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/timer_mct.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7386327228fb3101f634ce8f7ce5441db387a2f7204b9df642a9de6a0d91a87d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/timer_tick-exynos-mct.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "71c2702f9e62f9a3c68e14bd2f283ed5a3e8825ede11ccb090359fae24721ec9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/exynos/watchdog-arm-exynos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2a6a0582042a16bd0467171ed6bb10a7c1c94cee7f8b4e5363eddef87ed637ef",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c86ac7dcb0c26793eae300ad9bf1b75ef5389b9694ae568d6b59b2512e816e4e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0416c8275373f67ea4533c2f97e05c60e2405805236aff4a57f2056f31c96e49",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/config-arm-fvp_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8ba204e01ff724efcdc4ce82d29c142a9bc06a0fa7ba8c0b469200b5a88f915d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/iommu-arm-smmu-v3-fvp_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "09755c8298701eb8edffdb62acbf960e86e929cb7e24ca42a34e413c28ffe261",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/mem_layout-arm-fvp_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "95ce4ef45621ffbe71b6bd9ddc9ddaded1898bb518c197dfa6ebe9e3e5e7718e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/pic-arm-fvp_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5a9628cde3677999dd96550f99e7a5f9c4cf0bd3a6ef78cefeafd8f98cab30ee",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/platform_control-arm-fvp_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1f2a5458faa94fa2b2ae7de78b7ef4ef574bd07abc050a2ef4d6123c1aeade8d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/reset-arm-fvp_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2fa59a0a3a0d4641e6740e93b96fd3f9252f7f2f44bc056d680b9cb64956a94a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base/timer-arm-fvp_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "89d0b5ee7cf3cf72d995ae065448f31b45c626ba62c39daf995f9d54e6d844f0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "13b481de63d8eb4a35dded6c043122016b6e82a76847b50d5a7a9731d7bc2135",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "576c395a3ba6c1fafdd895bc85536543506b140346e05e6d0be8ede867e5dd63",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/amp_node-arm-fvp_base_r.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "623a7c015babe3d075f29021a544883aeec07b7086ea0ac81751d4ea6db6e780",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/config-arm-fvp_base_r.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d5e4e72f1f873fa91346f8d31956e38552914795ddff5d05c3cfe92afcdcbe3a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/mem_layout-arm-fvp_base_r.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4d58e3325698fa47d380a9a5a4fe5d79e40d34599605f8a8a39106141c20af6f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/pic-arm-fvp_base_r.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1decb3e04e7a4abbb65b197f8bdfac575ab9614247654222a7a07656c502242b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/platform_control-arm-fvp_base_r.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5a818b4cf956cf540ec87dcab632348021c2d302506591879e1f532f509c0b77",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/reset-arm-fvp_base_r.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e876bd5c086a0d09a38fe930efa33ca856efd670cef7ed7d435d30d70e6d9017",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/fvp_base_r/timer-arm-generic-fvp_base_r.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cf90f39ab34bea8369c20f3e93771560a30c58e59db78869e7a8da799fe87516",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/gen/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "37a3316a67457dca9b80f93acff81ca951584a420f3d09b0724b0d4e47f243eb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/gen/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7a375b11bb12f66b9e1a8c9e45196f30b6896487bbd91af3cc8a4cf28fc90e0b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/gen/config-arm-gen.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "568c350943b2bbe784acf7481ab38099ec847c90f5a492f513ba09b77851281b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/gen/reset-arm-gen.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c3e5b4447ee26af75e10f09abe5b24fd72e164166300c90934d845930baa9bfe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b73230a98a3a08ab6a4bb2ebdf58bdf09eb9d9b37cb110a8aee74f25b3207d3d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d7b432b3f28afe6dc8cbb625311c879113a3de648facbb769e68b7c366e309b3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/config-arm-imx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "93f8663ccc2b8d307d65685a925ee61651dfdb2a0431fea7c9619b830667b615",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/iommu-arm-smmu-500-imx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2382f8448735d3c2f15f82763817072a5c04f2cf502571a5d31a4188798531a8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/iommu-arm-smmu-v3-imx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f4f02b7d5203e95155fe02dae28a849071746efff9f4fbb1f3dce7defffd0e88",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/mem_layout-arm-imx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d5f3b0d1915bdc2bee7a7141b344fe18023eb39144619b2043dd8a91978da1b6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/outer_cache-arm-imx6.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d2ee90559bbab905a313e9cd5d41a4c48e08b26214f58ad840e56b0dbbc6878f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/pic-arm-imx-gic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b5282e7e32a33f274f2241c7c61bfc178ebdbfe3c54c687a3b31b3a9f071d76",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/pic-arm-imx-icoll.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6999729310338efaadbec7b14d5f6f8eb1e7dcf7f8b98bf5e0b18ceb703c905a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/pic-arm-imx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "640f9e7bf578d89007015df1286809755615a04e2874b0672c6b4bd7c9020f0f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/platform_control-arm-imx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9f5d2695010cb0c37b2c42500902be7555c1e91b416daf6b43721e9fb5a7223a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/reset-arm-imx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c0793005a4e6062968bd4f415660419b49a83f2c226b71bfd699f71995753a0c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/timer-arm-generic-imx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e78b7a5a02dddd60e67647c1e8d9fdb22160f27ff4688f0c55c7da2ee200ed06",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/timer-arm-imx21.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "35b2a918fdbd78156814485a2a4165fb64bddf80c3ec8a1ee82a3526851c0401",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/timer-arm-imx_epit.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "235fa1f094c12bf6562c1fbd21574b5b792d74d44d6afc2be7418ccddee6ba86",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/timer-arm-mptimer-imx6.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6dfe37772d2bb371488bc1e8576921b5902c906da6b9ab6bf10b92a3df271e1b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/timer-arm-timrot.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "70d685b5624352b9668a835eeb60076cf3260aa150017e07e5904308ceae8e42",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/imx/timer_imx_epit.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "261a96bed06c64f8ffb7d176d92c9c0ed3296721532d5163295339e57c25eb5f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/integrator/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "16819ec1b1881988f692ce2daf5766cfb5c097c536c05715d0bf6b35fe42ec8a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/integrator/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "02435f31048cbe468c9e60f7c7ff7f5fbd778af13a3a937e4c97e35bcbbf19b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/integrator/config-arm-integrator.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1a99a0d313a422ed21288b06088b78d01948f2b961f72bbe3331bf5c2c6d57b5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/integrator/mem_layout-arm-integrator.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dbf35a1eb6818a154714d079d5810e4a0fad6d777f9a1cf7708ac185b28a65c6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/integrator/pic-arm-integrator.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "299827c37402c04cfbd334b2b4b28b1e63919b39f38242415fb42b68722c0cb1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/integrator/reset-arm-integrator.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3688708e2c42541cd0c37d8b0eae29e772ddc367ef5039e7b989416b86b54b2e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/integrator/timer-arm-integrator.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "71d0d2034d4f43da9b40b016ade700ffcdf18b98c9f07dbf2f88c28b0573f10b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/kirkwood/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "18a4cc920a0a192c615eae4c30c3cf8af953132d8fa9d1bbfe887f93f44d6192",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/kirkwood/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9ac38a1bd0f254cf2e1d4c448e28049de01986effb3600812e3cfceb7b99775f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/kirkwood/config-arm-kirkwood.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f8f6f596a99d9a4a516003312cff3a979b506d979fa67b64ba754eae56ed4fe3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/kirkwood/mem_layout-arm-kirkwood.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6f5a99715a6c14dc3ac52a4b4fa2fc9933d2cd6241f52033c81a4d3ca22f6a31",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/kirkwood/pic-arm-kirkwood.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "38b92ff5884bf2824dced5a0be743cab1570b82352fb6e2c7bbe92e7af696c99",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/kirkwood/reset-arm-kirkwood.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7fd1bc2c523fc6358a6c6133ce10906fd547c1d4f93e75f4c66022b75b7a0c02",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/kirkwood/timer-arm-kirkwood.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "26c84259fb49ea5f04d1bcbd0b7a84c6608339494fbdbf84f1e1aedc2fc861df",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/layerscape/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f1edf9e5c974057d3db9aa4e6e0ebecc87d2596858642bc3d2320dc5e0ba1133",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/layerscape/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f0506a07d20a707256e70b0ac310b14e203959edf7d9d4fe677703b9ec5ebe17",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/layerscape/config-arm-layerscape.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3e9a5eb76b8386c363737f387328bc04b43a594a22c0ef84057f086ef8264913",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/layerscape/iommu-arm-smmu-400-layerscape.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5e0fcd5586f8def682c095e937ad28194349ba6b3aee12563a8056c74b0f1553",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/layerscape/mem_layout-arm-layerscape.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7f7c1a49bc46fa9623cce64f6354e5e5c9b586b5792cdeb1712c18120b3871d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/layerscape/pic-arm-layerscape.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cba66e363cd1df31ccf001fc6f6b53c913291cd019b9859b45fcf4963e260a8b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/layerscape/platform_control-arm-layerscape.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "728084a333e5fedec02340c27edfc45dd1354bd894867d976b5fb770b6b08d65",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/layerscape/reset-arm-layerscape.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a5ca7265a745b008033e261b3a3adef6fe4c757eb3cb91310367f95f7657fd29",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/lx2160/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2a0a12817883cf886f7c5c7703d3ad4c230d789ac6221722bed2d7e019d2f935",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/lx2160/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2b6a003273cc928eb85649e780778c0c30c928079aebd0b1fc259f87d5fa9367",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/lx2160/config-arm-lx2160.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d9ff5590fdd813857afecf0c90f3b445a97a45619c91a8bcfa3f144123788ca3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/lx2160/iommu-arm-smmu-500-lx2160.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ab634a7dc2002760546d5b38ca995294f089174baa30bdb7c638617c58e9abad",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/lx2160/mem_layout-arm-lx2160.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2d4aaa58dd70a347fe19a6c2e684410ce8014f6caf2c4901d28032291fa5aded",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/lx2160/pic-arm-lx2160.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4347da0587b18f558385820b9921298de6f355e2e236e8ad9fd5f2036fd00a1c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/lx2160/platform_control-arm-lx2160.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "16c247f21786b50f9c59d91b2bd6d7d1945c3d3e18141b7c8879530cfbca4d5b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0e2f4273cd0064500fac2066f02b56ebb00c5a4ae0d21c367e122472e18cd502",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6e31e6dbecf6fe60047cac2945777f69024b136008fc5107a7424d584c6d596d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/amp_node-arm-mps3_an536.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ded8db4d7533f2d6e954346a2222cbafe5e74f3948e316796105debbc3a5df82",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/config-arm-mps3_an536.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c40901b013c4b628889b238bf32eafa88ce952479a871a2ad034019d7cbbdf61",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/mem_layout-arm-mps3_an536.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e35047c417034279d9f28d0b5b2fdb6b363e21be9055acc94512cdad94d93030",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/pic-arm-mps3_an536.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c78cbbb2f6286a1c926ac7f702553226584f5d075cca14e512023f3f3cef6068",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/platform_control-arm-mps3_an536.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6c388542c8240117791ebbdb4a613f7eb76496e72c69f0e65d4359c93ee3cac8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/reset-arm-mps3_an536.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1ad5407625bdba966b48b982845d16d832777b80a8dca39b44b1eda33321f826",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/mps3_an536/timer-arm-generic-mps3_an536.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0e2e148121e3a0da26428fbeef6d209223f62468da457849991bfbb79fc2c59c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "29f2db1e7ffe3766a4f90eaea51e6570da0c5086c9a5c8a05b2f27364d26cc76",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a4d2d5be75f411332475b2de55e7873d80567eeef2872a7db15b6f39da81a8d3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/config-arm-omap.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0c1651bae3fe654c6e410ff67a77033e0574a48b69e6266dbb7513919531dd11",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/mem_layout-arm-omap.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d28331717fd0f56712f0998dc646ad36987d12baf899a28dc235d21e7b715b1d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/outer_cache-arm-omap.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5474f978d98c2f96f60a4abbea8e27ebfc525e615e2a1e15e0165af3719dbfe2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/pic-arm-gic-omap4.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8b5dcd44b315353cdc0e1b407a7a71eca323a6ab89fac69dd191947a31f02fc2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/pic-arm-omap3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ea23481789d45a380a591f55e509e210d59dc907dcd015aa75e19edabc6d6bb3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/platform_control-arm-omap4.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b0b8e43c10e6df19ef9faa990ee64ffbe7962886bcef0411dcc3d60e642a6713",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/reset-arm-omap.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e23a37026fd104db423ab95857a3d483eae93b1a0af11a5fcc1fa4066d7f5b94",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/timer-arm-generic-omap5.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a1f964d4117b282797d83186f7ababaebebe91d6dd5a9505d53c4e375f007e10",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/timer-arm-mptimer-omap4.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "12cd12c3320be848c87c51900e18fb38aaceafa335d507018e16f4f233eb7282",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/timer-arm-omap3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "452b65e6d2581f16156054f24feab6b3c49c2758d5c53bd7a3a6afa7aaebf1a2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/timer_omap_1mstimer.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c71aa90f5a62fa3bc37f922f674e4d7e5223f76258d3e92ff98f021c916da3f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/timer_omap_gentimer.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0ae36d284df9de57ec62d593bde0ce03cb51cc1fcd1dfc56abb4e2d1d657e28d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/omap/tramp-mp-asm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0392758c475c4e438184cbc8db8fd3e425c2e6ee05d274502854b6d4b7bd2300",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/pxa/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "27672e0c650155e4f9d974f800e1e8b015366890073e2db4fd3067d683b469b6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/pxa/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "47e13efb96492e489154557a5e92e80b00f2b79ee804cae50b4edb34d7660c52",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/pxa/bootstrap-arm-pxa.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c925417cff0fc131973362c001f9296b4a5e9b269e47cc2b2f8fbaf04194c25",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/pxa/config-arm-pxa.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e2d96d5a80a5ab53e11b41ce9f76ec739ffe2b55c63adab2c875e0df3121ad14",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/pxa/mem_layout-arm-pxa.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "586936516f20679fe13962cdb9e9db97c309fd3e70efa2f5e84cbd66768ad973",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/pxa/pic-arm-pxa.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dfae7307d5763df095133a7fb5a887c25d67517fa0963ded7a174360cf9f8733",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/pxa/reset-arm-pxa.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cd0558c7185bbe00b05262b32d51ebbbba1d08fb26d6f0323a951f63835ff36f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/pxa/timer-arm-pxa.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c3aca94205f26799d6c04d5b68501c28747ff33a0498c8d26899d3645fe9d052",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar3/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ed1dd2f376e05138958defb47d9e1be0d34b1d63db6e7bfc2b128496bfc133a9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar3/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "185ffba0c0c95b30874574ecba7b834545584845512bb15da4962c6d79a657b0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar3/config-arm-rcar3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "85859fe00c3685e39a6f8d708b6578332300972449fb47af9da3f1961591a6f2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar3/mem_layout-arm-rcar3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e8b02871d318c48825edb02c422d8607882568d905b16aa65dcac3253e655d72",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar3/pic-arm-rcar3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a387d93a437772e0b68f9b0fa3700f2b1ca7d2e9735243d1a6cad4f7beb1c1fa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar3/platform_control-arm-rcar3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "57d44b4a7e7efeb0dabd79b721bd7c793868e0b02f726c51564e640bbca1bbf4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ddf064853b3db6b0d1dd47b4687d0f777bd907bc2835785f67cfaa1395e89e2d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e0b37b2d101fd7d8b9fbc96121afd325b107f8eb0b2208c6ad10bceb211fc1ce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4/config-arm-rcar4.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8c7ade301a9b97bd906db3b5190b7c4305fbdd2a18e5e1997f31875cbdc261c1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4/mem_layout-arm-rcar4.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a9fcaed3d9d8b47621eecdc3e902669228a79f96bac422c15019c8fceb2117ea",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4/pic-arm-rcar4.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d1be5d16ae5da803bfff7bb1371e1cc7c86eb33770680dd81370aa982c8a550f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4/platform_control-arm-rcar4.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c2ba4b9ed3173844e26b61d37d28bcb070d09aed770ef105ddcd4d01d206df7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4_r52/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fea98cb05db9861d3613ffed3f3b4b64ee735e7b60d8657c5c00802f2cc1ccbd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4_r52/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4e91cd40e26e8b32e9d586f0c57e6c244e45fb94698cdabca7abed691f65d7f0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4_r52/config-arm-rcar4_r52.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cc27fc8e84ca906a3bb4da7b45329794a1752feb17816c6e83877e4ca41934a7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4_r52/mem_layout-arm-rcar4_r52.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3afe55cbf281d1ec83f5f1a82eb109c0515511f88856f45ec327ef83f0edfada",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4_r52/pic-arm-rcar4_r52.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c3a7448b840d01d912412fdbeac5188dc6ba804e60ccdc4d2c7785a8cd478f94",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4_r52/reset-arm-rcar4_r52.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5ff94980b58ab50916f81bfdfb3a9f4f8a0fd587039dbb834eb73cec98a41b45",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rcar4_r52/timer-arm-generic-rcar4_r52.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f9c81cc946072ca044392f6adb971349d1b166a4d19b09734d40fb419786eadf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4ee201b5b2f49977baa70c2506bdfd230a5b74917712e49d6e92a53cd3d0c27b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d23457d74da154f9b408a71b8dccd805521d7c331c62e4364ec83eefdbf66901",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/board_check-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dbcb50e961af6bd2981c0c5e3f73e92ef9d453532948f9e6b84395b069a486b9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/clock-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b58d83f0f757746551e3d07046ebc4255822983712046a7f70436c918360ea6e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/config-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4eab58263daff12f408251c5e010c2b48df0638587ecd1e7cc0a5048376ee45e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/mem_layout-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "15a4d3586660e2ce0c375ec247b64686f078438c4d5ec33921d3cca2ece32337",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/outer_cache-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "534cedeb62b22d9d5d3b3ae23165714e6ab24198d1bef449bedcce7245bbaa3e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/pic-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "803b563fb3246e5e4367b0319cbabbe805ffbdd3079fbdc8bafbeaf3efdd25f8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/platform-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ac46b0a62e0b0aed7e3b3e4cc86388f46566d191bce6b8c9837bc7959b85ce87",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/platform_control-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "082164b2f66d7c84210716c667b17feaf7c8046a9716d9aec54d80c2fb6aa8de",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/reset-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f6d560d92197b054cb0a1b6b94b91c1a0dbaebd3bab4e47deb87f6656b2d50cf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/timer-arm-mptimer-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "025bdec2cf2b4b054a59f793e742788851361b3e231c1d4f6bc4d7ed6a8652c0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/realview/timer-arm-realview.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f8205f743f1a7ecbc697c5c6e5c9bbca772e58be6e3eb58a654f166cb8b61277",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7a76073e340e8801b6f6074158431450921d9accb14df4fc142695188d59baa1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d0f54708eb371b6f6b14eec4c1a96723e0b9d5bdb72112b19134f0c233b9e660",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/arm_control-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b7642a47e2bb1c65a3908d47ca290876cd0fc994fc04dd68d193f2a6664e2ac5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/config-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a87bffbe44e8527ed802fe7d2f3fcc4dc321c373bf00bee2f8eec26cf0359e32",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/ipi-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "552de7227a1c1ed1df0c435ce7e72ce3fea5f46bd8478adedccc88d87630dbfe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/irq_handler-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a3e5e2dee3ff7693754093a687a5d5add50b598c4eb48198159851bf1874c729",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/mem_layout-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "48cb29952bc3d8e08163fe34e42659dc34bc71c6dc89b1d81c72fd64fcf21616",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/pic-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a13fd721bfd1f962e22609b6dcf4120981df95b7cb734fe3746e63ba3b234545",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/platform_control-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f32a53bc7fcd0df963ced183bb7567f26935f72d26398edc450e0f481374209",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/reset-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b936b283ae35c68ecd45a760535b20b28b072d5dc8e362c5a24a652672a06aaa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/timer-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b9cd3f2775795030ec35d1196e154131c0e64f4c77d1e47dec6586e15ee85d1f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/rpi/timer_tick-arm-rpi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ae3ef1f22e22c1fdc5ba504e3ec668a148bf1280d500313ab27a4c588e24691b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32g/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7c7fa400413fa605688f8653749d7d9a2c95e81d5d2498bdc43b3a2ad7255fc2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32g/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a101fc2ffecc3c2780dcaa0de2722c8b6746436d27357ed136b4785fc9752564",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32g/config-arm-s32g.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "69a86b8b73d83475cf42061aefa8097b80e289a565f8762e8aac671dd482289a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32g/mem_layout-arm-s32g.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "41fafc5dfbed07bc109c57b946d9601fbe424118b73b74443c1a2f9ba89b1e2d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32g/pic-arm-s32g.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "73cf3f9caac49a3192b1b99a5330ef1cc248b282b717f8cd0d65235e58183ab0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32g/platform_control-arm-s32g.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eeea8974a339c563a81505cff42a1b070c0f1124c30a11bc74e774d1f42ca735",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32g/reset-arm-s32g.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e3e71224421a48ef15faea6729ab66dcdf47135af22847e4b536da0a08fd5220",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/Kconfig": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "24ef0930e9dbb0074ee6f6f62941db2f3f3f23bc4656d2755c8dce52bd53edf4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/Modules": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "f2c418de8355b3ee997bd0ca8c7c0c2e48e2d9b969d00f53407d69cd45614915",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/amp_node-arm-s32k5.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "e74f02cba0be1006c8e8db8a5eccbf3dfa4c1919abe2d666a84506e17c854722",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/config-arm-s32k5.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "ec253d7944537e6ca5c4e20250b5fdeafee45d1d6dc64cdfed21c24f140a84cd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/kmem_alloc-arm-s32k5.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "9fce2874bb88ebfb4aeec469a7aa42ac74184b4a1a4774468c4b9233a6f4dce2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/mem_layout-arm-s32k5.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "1d907df44bcb93423fa557b4733537cd466565222525f4f544e7e97ff7beef37",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/pic-arm-s32k5.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "1bbed740b84b91fdb575f5f9da0dcd694964ec841a30828df1d1f082ffe394b6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/platform_control-arm-s32k5.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "ff8ba28e085f0266658733661d0af5f201b955559ba7a3905f88eb5ca2c6d681",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/reset-arm-s32k5.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "f6f712cee1a831401289f0109c1f5ffb24cf4b9464565b5847c69588d9ad3196",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32k5/timer-arm-generic-s32k5.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "418973afee4625d8587afe2336d8ebfb845de53a20177f22e7b4bebfa274ca0c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/Kconfig": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "9fb6a84b0d0059e26ac2184b178f67b37e11be441ca93be94f1be26ae8769912",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/Modules": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "749495028638ad940d80a8637d501d63fa92aaaf65b0dd537c239c8d21cddaae",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/amp_node-arm-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "797d34b74aa4ba208f8cdd18367ed9d0093553f7f449ae9ae7eac646d3088a8f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/config-arm-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "765aa8cb9891da598f96ecb7aaf40acb453698848fed302510bf28e57e12805f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/kmem_alloc-arm-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "d6aeed4605bcbb9ab62934d55c9e73ec3bfc29f9560a73d52b855a0c1be18603",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/mem_layout-arm-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "84221115eafebee3cae89ba5d9e9204d45c9578966973a0e0b1cbbc1ba4db5d9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/mru-arm-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "bbaa2bf537a201129865cb2fd5b1c541be78981f3b784263a6cef8fc9614c6b9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/pic-arm-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "31aa40e7f47858a32c0e37c859ce4063d7f5e3c514debdd364761eaac274e0db",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/platform_control-arm-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "891fb16d9b10832eac5a053356dd8e5062a13ff8c3bb5b6d4ba323be4941f199",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/reset-arm-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "cf36486659427bfaa0fa2f64022728e3eda9da4c0cbf8653648a0e704249838b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32n/timer-arm-generic-s32n.cpp": {
      "license": "MIT",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "69fa6e0c5df9540f67489addd886f6ece591d96854aa1b265e8feae465f2f209",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "61140cb24c9eb39b96976b15e75a4bf721739ef282dd0e54a4d8ec8721796501",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "15af61b04870b4546173f1c280fd6c128147f69061e4b70aa28496cefd14a685",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/amp_node-arm-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "54a28c4954c8250bf5f7bb9adb8c8d1b940c77cc8e2592df94768044129d3a7b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/config-arm-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8d7b5f16996c979efccc7a1977eaceb201429209792916e69ec923219aa98ee8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/kmem_alloc-arm-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4e275cd934094b896fdec3d2748a84e34697b43a4409932f580c982d870412fe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/mem_layout-arm-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3ee4b3b10b78a4430b859288bb913dae01984f3cb7e2c997003445d0c3af2ae4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/mru-arm-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "46789a8b63d2949be8d0c272c1ee04e8e03a5496597ff81d632339f5afa5db80",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/pic-arm-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "869b73be6f584228704ee2b2423913334aafc0d3ad982695390f215414d415f7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/platform_control-arm-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a58b8b83913c5c76d463417a9ef682cc32f9ee1a9a9d76b0f0a36c4c27918521",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/reset-arm-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3567ce67f0b4e365e85b68cd8c732347625c31cad34b58c3cf28cf16eb74c3fa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s32z/timer-arm-generic-s32z.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f18f4f27e7c1d7608dad14d2b6cf5cc3130fc3832930c01f85730a866af44364",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s3c/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a848deb03b32861d0afb77f1152727a30c210d8667a8633cf28d6d536434aba0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s3c/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8a313d9917ee08e67a12ba73535aa2ca206800ced8b09e20c7005d620598d8db",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s3c/config-arm-s3c2410.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dc2bddb8a1b1f852d4b21ca414ddcc08a8858460b99148a8ed31856c8867d07d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s3c/mem_layout-arm-s3c2410.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "36740b41276cea256c66d602a8e9774e206d79033a8126424bb1fc252c2b7338",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s3c/pic-arm-s3c2410.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fae745a738ed1c5e1d086ac44fcb39ace3e30c3e473285eb2a1da7468e49335f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s3c/reset-arm-s3c2410.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "78a3e3479139cb29c77f944e13baea5ec0f1a657a3840973c501148ebfa9a146",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/s3c/timer-arm-s3c2410.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dca87a9b3f5589a779968840821d25829b0630b355e3a52e1407df01960c7e84",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b20abe4ef8b41f343b32f42c96cb89fcc956ddd9922caced7c050ad1d9dc37ff",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d4753989fb389d37f0d425c3bdc07a714293f4987bcb033863951031b4c313e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/amp_node-arm-sr6p7g7.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1a870ef05bc38b582c4e2389493a3152eaee1894d167527fc281fee00527dc24",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/config-arm-sr6p7g7.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "84cfcfb366e8fa25cb44769870f3201a0cfd728a29311c0b443d0ed3e22ebd02",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/kmem_alloc-arm-sr6p7g7.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dce3d23434e229fd527ffe89feaadffb37be2a57e0e5beaa8faef077e2527c7e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/mem_layout-arm-sr6p7g7.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6885442bb3c753d41c56c79054eaee9b28ff80af20000d58d5301cf77a51c0ca",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/pic-arm-sr6p7g7.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bb816ac0afcddf96ca92e1ef4b251ce81b32fd475bca0953d156e71a05e035ea",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/platform_control-arm-sr6p7g7.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e43febc84911efe9746b93a6f8ff0074da1ce22fdf69ad05f99b344fd1edd010",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/reset-arm-sr6p7g7.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "21acf78b36b6a33195a4636415897e043a4c7b9457633f0b511513fa4cd48f62",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sr6p7g7/timer-arm-generic-sr6p7g7.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "400583a4742f9a2c6feb35187bbfe868683025f623ebedd825d39d00cd401a8b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sunxi/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "74e2ef8e62b89b66d4156438cd3b2928cf63b36efd2ffba4413602401fe51e24",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sunxi/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3a8a3aa3a2d8c63c49609f2d604fa5f46cb75eb592b2bd80fe5f5d5c3af76662",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sunxi/config-arm-sunxi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0a515c09d5d473187ee6fa95b25306bdbc6d2805f139266e958f5b9ffe78c61a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sunxi/mem_layout-arm-sunxi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b89d5b04327fb6a7eb261d4bb19cc9fea3e0073e5fdeb285ddf41a3aebef7a8e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sunxi/pic-arm-sunxi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e38bc8af890a55219d784b869651fb4359880dc9cba22f0fd106f782ba286f37",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sunxi/platform_control-arm-sunxi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2b6f54350ef99893294ac52a66f60b975809c11007ec0f83cc12160025302681",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sunxi/reset-arm-sunxi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5ac32b26252adeb82705c92e7aebab250999da43cf29e153fe8e83c5e74ed488",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/sunxi/timer-arm-sunxi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "591ffc5a52a70230edcceafc85109fe11318a094034d344d0d15ecb544bf667b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c809d6c75ea1c3868c65e8f1a60d03da001638ce9390790489fedad960f5b50f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "183b1b1dab1ef4e4a4d3bbe6adb0590897d8cf166a074bf0e31fdd7515e345ba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/config-arm-tegra.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7ed7c6d72e43396bfffa6fb6ba730f5944c179aa656b09beb79eb56fd32a97c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/mem_layout-arm-tegra.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9afb2e96cc461289fc9a2c51e0c98687d4c56ea0deeffeb2232ec59f26a8817e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/outer_cache-arm-tegra.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1217f2bdd49cb92c3a47097af5d148c60ad2e5ee2ccacbdc0b4951114ca8eb7e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/pic-arm-tegra.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8460890d7cc5230559ec747e269810b6ee85547c31116b0a49595f9b41e7357a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/platform_control-arm-tegra.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "895a82df9c8f9e9562b1cae21285eb7f110c3f3d3ff93b276e41745399583c15",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/reset-arm-tegra.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dd671db012a532b72bc37d4e56966be7fc0ce3da9676a9436ca8bda89624ce61",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/timer-arm-tegra.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a820427ac1ad8a798f6ce5fe13f675f1ec1e3d2b534a782f801654f0e3fe6e1b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/tegra/uart-arm-tegra.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "44e17e0d00187013711b52ce42fd4cf8721821c87370e5eecabd06c012d48489",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/ti-am/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "16f4d27104faa97cc56d78708850c0040988fe7620228fd7117f9037eef0c8d2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/ti-am/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6e8937fc22de4fd7fbba78570de14a576985ac38e56249ee12adf18a034f639c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/ti-am/config-arm-ti_am.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a40a4d8cefb7a188a1875ca6c200a3e024348bcbd0f532fb39e612a2624986d7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/ti-am/mem_layout-arm-ti_am.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fdd26f6a3a4bc36a19130382924257c04a2fbbfb618eb2ae0ea3e8f17f87b7ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/ti-am/pic-arm-ti_am.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7303e103c8f1c0371625879398a489ff764fcca3e3e0d89bb732eea08cc06362",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/ti-am/platform_control-arm-ti_am.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "da0118603505525ee77cc687f1d7d31fe9b83bb845dc43c42171e2dc300f6328",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/virt/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a6826af6747b0966290c31de25841ff56c3be348b8468c3fe188bad6ded61aba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/virt/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "63b5405f965089aa7535f12a82c4487f7f8992f8da20306ab6a84627434fb4b5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/virt/config-arm-virt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eb40998ba35dff1ae765f1085f4b846a89d4b2de42ea091de41dd2c03a7009a4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/virt/iommu-arm-smmu-v3-virt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "62e1ff907340d357c252d906f080b00cd537af4b7c49698b19b1182e1d53b3d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/virt/mem_layout-arm-virt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "78810bbcf34be222f7f08c636c7c819a0970db688c9f728ff3f0bcce10e01b37",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/virt/pic-arm-virt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c2d81aff8fe8af425d64369ea6bf06160d0ebd3aa2f32d07057e3215c197db15",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/virt/platform_control-arm-virt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "56f4361f0d7cbff5cb2f125db0739fbf00b1f7949ee13d9b80830cc36f7ed35d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ed2c0787d22a4d5fbd8cd163442229226713cb805c534bce88b03ba3cb98e142",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7d5c9526e12cca74689ed56e3a84f6f9cb3bf0874c8bdf8563aac0d895e556e1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/config-arm-zynq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d81bb6bd69189eb6da20264f877b90b316240fa9399afa117ac70574b8528073",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/mem_layout-arm-zynq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2d723c19ab2275a6ac1a724f3b1dcbbd87d90f7790c96b68c42258490896ba6c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/outer_cache-arm-zynq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5ea82c7063b61a5d1bd58eb331748876ca966824e181d8aaa3afcc4addb8b479",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/pic-arm-zynq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e928b4dad9c9f1eb91d393743546f9468a94bff0f81ada15ece78299eec2c6a6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/platform_control-arm-zynq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e7aacf3e79e39af9ac66bfb0ba2ae56d80b4830dd9d9bf23fb417eee4fb471ba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/reset-arm-zynq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "30a9b5b4fe2bcd9b215c65c560bbf1c3e80869b9a8c9758a4258a9d96b12f483",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynq/timer-arm-mptimer-zynq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6ef03a5d8ea45dde41ca640245b0aa7a37c267e071dd8b9460569ecae8f4e569",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynqmp/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a08972ee41c2833410619099e25082fa344c49b1cba81d42d1f7f02dd66d5cc3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynqmp/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ebfe1b403eb099af768b7ccadd0d50ac9adf6ffba6838d02403b75268ed26dad",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynqmp/config-arm-zynqmp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "10c3ea97febf80cf9ba3b0484e13b345d2ea76a5c78f97e88593b5c2d9adde4c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynqmp/mem_layout-arm-zynqmp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d1ef85f9f3476614202bf1f6b32b27818dde00cebad25cc88df8b97eb5da8c8c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynqmp/pic-arm-zynqmp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c714b67e67a3bb3507f6c237ce024429c465f6dbe6654f25d1219ee4cad43d2f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/bsp/zynqmp/platform_control-arm-zynqmp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "29cda82bd5724ff6ad350e8ab7ab5adf420f6c1418b81ba4e08a6730e2ed5ab0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/clock-arm-generic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f8c3832c6cd86969c0e524c69e20477141c7b6c865e2b02b1449655fe2de33f6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/config-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f7e7c4e736023a4c670aef3c0ee14b4ddf8c52fb8c50bb87d8d0589bdf33464d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/context-arm-hyp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0fa0d15aa1662293018a982e57b9dc6c8c4730bb62208cd5fc26a082ceef4607",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/context-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c041fa1cad2dcccf6126c2c45edf6d5762a8d391d4e3fe711b173c60de198206",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/context_base-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "962ee8bf53dba49c705cac5b3608465d12f54b272692ab39e44bc4696ed8e975",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/cpu-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b9462ae022f56c9448004ab20bbadc9b2520e6f1f84dddeaff12870eac278285",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/cpudefs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "098e7cd8151958bb735005a2c173e9f3c8fdfee5aad5e561caf1cf2e521c28c7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/dmar_space-smmuv2.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "41f597f3685335cba1f78c3a012af4644dc48ad39794f644cc34a008b14ee484",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/dmar_space-smmuv3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aa218ea97193187503d4659dd75caf8023dc0b665d1f4e4a05d152a69c98b3b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/dmar_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bb21c3d75092218093e2ea3a5f0ac16aced1449926c900c5c4dbb0ffc2f23dab",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/dt-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "64ddc32b69fe3b1b3e3493987ee2c78c2f691ad509ae01b26be9d18e48a45d50",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d615c8e51243e8ccb59eadc3b0eb6467a5d78033c7b759cafbfab54cf745d2f1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_cpu_v2.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "abf92ccc712a3caf6efb14ca1be49be611019717013887cb78091460c32eaf27",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_cpu_v3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b10b3d3a0b4863381d85a4af7c73a905f386d6ccdbe25a46ceb670c271688ab9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_dist.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7c204691ed3bfe297c969b4489c105a448d8e02ea1ad4e5829bad843ddfe008f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_dist_regs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4ab524be225b87692914ece9aa5b6524f2561f8eae3603cb8383a467ef02def1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_its.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a20d64ca6691db27df917863616d83f0aee83860b0869d78447668e53e8a49d8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_mem.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6231589f9d1cb683da76c20b5a48ea6d6965b2dafc148c7990f866249033ca70",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_msi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b6373c4c3375e39e9a5b37eaf9eca357200d07ac980afc74b2ffa0d9241d2759",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_redist.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cb17b66936ea97a983ce9e4a7741daf7256dd190e34fb360a2a68371caad3c3f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_redist_regs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0abfcd87af2355d96dea8a88354c40b35d3c880d837cdab062913f985244d58d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_v2.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f6e62ffcf6cf619c201d99e51c45816a94525dbc847e3347bbc78c29fd027659",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/gic_v3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1de60e203ed227d1f2a8a0d577347b06bca323193a2b5575506df5772b456531",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/globals-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "779dc05b862df16b76db35363db461aa472fd1a836dcd4f4e2b28b722b57335f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/hyp_vm_state.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2c2f7e8d83cf48f214077a666d4c97b6e6743687019051a9b5abbeb8e2782e5a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/iommu-arm-smmuv2.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b7105657f469c89316538aba59ef321fe1fde480c8e497f328a54e4c619a6bae",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/iommu-arm-smmuv3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6446f34e656c51c38286edfcdbec35665b5659f4d9d77fb3452848f2ecc68841",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/iommu-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f2107c5c23ff66de3c550018deebcfe518958d8bd57bd1fdcea389739360a7b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/ipi-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d071fea3ffec5c664824e3ff254a8a6e2e2bedb965ed5c4b0e432c91baf96120",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/irq_mgr_msi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "037e019dd42d7d34461aa2ec57e83428f01704e9a67230416c99764e06c26501",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kern_lib_page.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f825975d35e1cdd8bd100c22d25fd70f17b8d8c1d17f37c96e80581530a20b0a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kernel_thread-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3664430c5d968194cd99d30a580e02e8e65042b53973108ff14f2346724e9f11",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kip_init-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "84e8325087ed217ddf86dbdd2a1a8199fcce5fb7e8176d2cced1fdf7f802e272",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kip_offsets.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "21801faf58864d8442e20d0c92ae4b46933286309293ceb18fb300cdb041964c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kmem-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3cb9f1fb5169fcc71a1ac322ff7dbe8f2e1dcc47fc02dcbdf2e575b9dce58f73",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kmem_alloc-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3a78a7c6a724f7c4bece737c634f8d610596476381255552dd64dc3699f45986",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kmem_mmio-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0ccb2dfb9c660a8f404e5e43c611d30a2e7dbdb720a742d8093c0f1444702251",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kmem_mpu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bac3f8ee9ef046a12950336fcb16754e13f10760e5ba9c381388ee68274ef977",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/kmem_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d61290b698afccd16fcda7e1429ad214f44f66dc6bc6d4ce06aa92248bfb6b24",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/main.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8ddd119806c05ca764b19fc8c6158d1e297b2eca3553a0646c7616f19bda29f2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/mem_layout-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "de80c4818b10b0e58af66bde64b18b60828dc6c85d34503fbe045ad7b4341cf3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/mem_space-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "819ef3c933d31d2994735e6646284e80f0a2da5fae13da3d46464bdded13ac17",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/mem_unit.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7212df527d62869a40d5d1632ba4ee886628d1c198cb989304aca4022f9f6c22",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/outer_cache-l2cxx0.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5c58c539da976cb0987582a2ef56897694c05b4ad32503955bb92ad1d89f7dda",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/outer_cache.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "41a20e0df52898b3b406ef6a9e4c278f649cb0b294f0b77aa80992cfa695e6ee",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/page-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cb47ca218a2ef723a30252c0f88c745bd6ede20019bc73067386d4165b6a7a09",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/paging-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "384336a60233085e6183fdfd1c451857a1692bef0be5885c419d17b4cb787421",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/perf_cnt-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e1169b8616e4e9744d6b731a609911af25a04561137113cbc8e71de401be98fc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/pic-gic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5c48199a557a9d74944ff253a5cf06acdf5daa325a22e4ce14a1b217dcdadd25",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/platform_control-arm-dt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7717a798d3982fb3e12ae0db523f28b8e6e7203c420d67109c6b0c470738b122",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/platform_control-arm-psci.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d1918f33246a2a82af2590cd6b09c964d60e34f07dc74016b17b4445149d9625",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/platform_control-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "84c1bb3117b4a1e840a8a06b1dd83f8234628760f454adadd071bd512b95d2a7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/platform_control_object-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e596383a231a93b291e3a391c96288b78e9c6a7af5e21c058c16b737e565bc34",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/psci-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0cfb1c4ee46e25a93248b6ec89aa87ce457173bf8c65c6025cb39edaedf4a6cc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/reset-arm-psci.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "17e7ff46d3b7aa8cd57f20631c27c6d9b519e8d67e3f549b47456953de1cc6d1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/scu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fa8dc9b65734324274d51a2e9f63464fa07de695e5c6c88e587499d1f333a03d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/smc_call.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "af6f620649ee7dfc6068a9508c7404f9429e6b3eea8bdf57444a8593b737dc67",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/smc_user.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e611996da03e5ef60ab8e8196141c03788f1e059f565be1683e8d29b8159f5c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/space-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e8bcb875414b7431170c3be520ca0f2f6323b62aa70830f1ca9b17290c5683b1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/spin_lock-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "331d62357c9e4bec97628ee71edde499716cec84d7f84a683eaaf9d921a5f317",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/startup-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e1db1b3bdddeabc5f7bc4f3924280415a2fd90347ca6b3137a60096cd3f6a514",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/sys_call_page-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "29d31716744db5ed525dcf9bb3f622807ba2a38c8a746d8d6ce27b8096417174",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/task-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e9c7aafb0b7828ecee09d16fb75ec641ecfb5d7e189139bc5c5459471cce5f0b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/tb_entry-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f542385184b301afa66aa0648feaff98cad27118993083886b99dc8ab4b32315",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/thread-arm-hyp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8582ae6f299955d4a24a722c011ba42064dd69e9c4b532a0202876103332620",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/thread-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d7b346c8bdcbfe7536afb8ff482bc4a911636ce35a367c643d7ff4fb18cb39db",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/thread-jdb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "be4375e5909b8114d0c3157f9ce1659aaf103b916ffdf3eb29bc5115d9db089b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/thread-pf_trampoline-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "64851cf03354dede14e2bb7a31b0851af98c7eb341d9c12f93e8589d58f41172",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/timer-arm-generic-bsp-std.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "06796203cd74de8217c8328a982754a1cce25fc2c8a147de88f863c5b78af189",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/timer-arm-generic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d932214cb83205c9f896be52aa2136d54a2825eef843b52896af70b50fc5047b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/timer-arm-mptimer.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e20eb497f7638aa0abf04c55344d3ba1563e69bf2f746212f5f5a4f35a1e7f44",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/timer-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "52213d83a213ac82027d4c686b1720c0317a97053546fd7c386989d15598ccd0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/timer_sp804.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4a5bf9de6719cffec4bc6b82bdf04463e1dbdba35d16aa5505744c56dd7d5fbd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/timer_tick-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d3fb95d6c4e274b5214e5613cc33a546cf81695c5ed6e95be66b7fde549b677",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/tramp-mp-asm-default.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ab451045bb1a99b1fec4287e5c6672798bfe2b31033590af66520082d33f0098",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/utcb_init-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "75d986cc2a92932e7d4a0cd9576ac078b891910181ba28f1b5a99867168d5b9d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/utcb_support-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3cb39d4d1771188ca5eda85c9286e06b9cea485ad632094c38b0ba8c5e3c0612",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/vcpu-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4df862b7ba802cf4e360c24a9c4ea87b0cdd3d2a9606b4cc1e75b12e4b76a006",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/vcpu_host_regs-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9fe5b20063c00593d4c84c2c8e2a6669f05ad7ae6abe357642ed39ecb7ec39e3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/vgic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cbc3613ab1e61dbfda9bc155f9f535869ada582e0da48c7d5bd9db0f2e141722",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/vgic_global.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e950860aa4c4dc44612da75ea90c2a9e7cc6574161bd08c166ce954c9f1747ac",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/vgic_v2.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "889815fa620f4f1fb17b0eb6de1c3354d78bf743613f56fd09e90e0eb2e4bd6e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/vgic_v3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bd5ed76290c1af37b2577ea938e8e54601b28fc150aaa8efae3313e38f09974f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/vm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "adaa602d1995635c01efb9aa1b4f48690ba9c6149aac90133f29f62159a3e50b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/arm/vmem_alloc-arch.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a9fbc8bcc47f1f286e017ec4649b6eb394c8c18548851506fb29765a8fe2dfd0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/asid_alloc.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cec1d9b3785c9f2c74d8b3028e2b4de3b33bde3da4725c690674123c5f366da7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/assertion.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "476b1236a29b8c3dced859cf8aa54779d1e3a6a6633d033ba51decfdc707c6d8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/auto_quota.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "713ab3b178af712f144d7569c66952be1d5e4bfd75567f17fd032b77e6565b9d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/banner.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8a7f7532483f0efd05284dc7e54d908fe8f3c7f4bb6eb3ae02583a55dad14e7f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/boot_alloc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bce0924338a12bcd1d5179eb59c9ba26ddad03c78f2514858065244b4006b51a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/boot_info.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1343f620a3936c7435d37de00967fac15248d165f47fc4e437ce1363ff938284",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/buddy_alloc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9d171ab8e15ba3d259f640e3570d7fa7c1dcf26c8d7c6dbed313a8b8db33beaf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/cascade_irq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4586295c46895113a868192f3165f2ff9e79175773b4de2ca2a75d8b64cdf892",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/checksum.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "80746aa29ced5c26fc575227daaa0c158c78dda8fe91efb534c61fb4b46b4921",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/clock-generic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "55658733ac275481a2e99d04c8d2c9be69d27be91615ca1cc89c5171c1282dcf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/clock.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "154fa91c06965ccce2855c7166c1362acd6ce52756b6f2695fbf1a0435be0e02",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/common_mapdb_types.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7f133655cc2d19fe1b60e8d6296a4253d58e89043a32c9fef9d50fc4377f1661",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/config.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fb670012aecab1d3ae8a44ee939e9252a6259637e50f9047b041f38369cf3ef2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/config_tcbsize.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d3871ea022db78e7831e5140c1884eb0170a81165ead3f5759072d035eb388a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/context-vcpu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ed17e96305658c4a851526a92b2be2830eeba0f74fcdcbfdbc02bd62777b9437",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/context.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1801e5774e6f661532f34c3a7636718ab78078046c4b462296da79d483fb3b15",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/context_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dd620dd0671e545bc1257c37f759d5fa5574d08b173a60947afd3fdeea36759b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/cpu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0ef9925ba21b8c53477b6a48365442ab46336169831c96cae221e159ece934f3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/cpu_call.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c47d45337db3437abff7275a9316ab9c07eb47fee5f387c25c768bb41f40013",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/cpu_lock-generic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "800183550039f666e1e0caf3a90385100365c36f3efe3b9575a0051d3c8333ea",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/cpu_lock.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8f88c72a09bf0bbd3627820e210768fee3e52e0ed3e9d01401d6cff667bcc68d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/cpu_mask.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0d4bd23b2399863403d6d1942a6149dcce492b615b763f06f10292da4b3faf8c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/cpu_ucode_mods.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "355b39da20b111d119642ba2db15225fe90ad61836a5ba79b7d3509bb6b229f2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/dbg_page_info.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cc862069afac35e68fb27587e829432185848b7e11be1358777854261d19d45b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/dt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dd1de781518fa6bc60410bb2545a1e29afb3466511428f5701a6ee72ea2b50bf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/dump_tcboffsets.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e2947eb49cb2cff66199257c35de0dbc2c0dab405946f1aaf2715f9dfb6db4f7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/entry_frame.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ff934d11c5c69e849f0703761429957dd2a30cf1ea52e322fdd8ca9b233484c0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/factory.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8b2c9202fd6e81da2064da50531bcf3de083a0d608e2d1353a85acddad784dea",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/feature.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "93c2a0ecc0302f431aaada27e680af33959360f93e80d52ba5ea172f64da011f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/fpu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d464905e4eb2192d403c8d4da91054880a54bb31da73ddb8bf5541cbf846600d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/fpu_alloc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d4ebc58057a4e40e0c2f92949201757fdc92e3c885c067b4154bc7cee78984aa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/fpu_state_ptr.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "14ea01b916e652cc4815e3750ddaa5918ff39e8b04252f9a7869d4dfee0da7c0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/genchecksum.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0e055292b07af199e6168e9d5b139844d6ac4af5de54ca7e8f0151e50e17f5c1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/global_data.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6863c230bfdc93935ad830e084de1acf07ac25bc1c5fb7dffc4a0080de9efbf7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/globals.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "72464aa7bf55cd1e398e4b2d1f96942fdc3296bec042e25cdf513f2bdbdbe69e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/helping_lock.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7c7806f6be29c673cf14ca6559b79a38e5672201fe5b51b3a887c9d61a7a9f52",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/hpet.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "feca081ddb6dc59950cece4e5a698d02c5302f86df7752a93a7d25121f1c5207",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/i8259.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e55ba554485b1cbd56a51bb1cc6b0421fd92f7bd89a366183992d9db3fea10b3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/config-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "22129fb799b3435a56a21a2d93a3cf946da0073711b58488627aef889e1f7d04",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/context-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "376c15db9f041857e6fba4e75f871ac34bbce1f78ad3abf8599ebb09b3abf34a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/continuation-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dba1a0733a88415d7ca76dab53983c7968ff932d8c7c82a7fbda6c119508be5d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/cpu-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8c03662eb821020b9d77023bf985712e2395a1731d8b911b23a9d3a21eb060cc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/crt0.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f7cbbaf0ab58f031234dcdb39d4a59cfb5d528a0bbb18d780d57ced24bedee6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/entry-native.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7b9ce2f06985fa69b3cc94b2bde2fcc1cfed86a66dc4f485033279202a2f9e33",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/entry.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "554e3e89f61d84d39880e7c9bf0b48518a6dc47cf4073fe31783666470d35025",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/entry_frame-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "51005f111a76549b0077dbf2147f6d6f0b6adf5bb3b988e14d525b420597ef4f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/kip-time.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b3ab730879db55ea316f5ccab1a37b0c7d22199041131ea3d93d7073f034d039",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/kmem-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d7333028619c3f8a4489fdbd98eab668806e159c085bff24dfd853852b28d14a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/linking.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5fcbc49d3f37f9b97a3949c086c22b611f96fbbf1d23686b834ed40278b7bd6c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/low_level.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "33db26baca1c1f30f2b4d56619f24bedf006cfab0644e63e77827a2cc7a39a70",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/main-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "496c4e4275f4fd450088055f78db040bbc2c968ac3c9404357c864a917a162a7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/mem_layout-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1a32150d3f0d7301825a77815bb37cab88a425fabcd10ca36ec7d3a3d717a1ee",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/paging-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bea60ecdb8d88f7e71b2369fddc2d78cce29258897ebfd9ca9fced5246369ae7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/sys_call_page-abs-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ac24567381e223c8e70d904abe2f68c08cbefe82a961b20462a44e38067a967d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/sys_call_page-asm.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3d671818efc08908f0fc5465c31fcd3dd09c7a599b3bc6ffd7378ab0b74f6aba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/tb_entry-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0c18b6c9fb6a692a6a75bbd8449763b47cb4904bbc48f26c075e4289b5038ff9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/thread-dbf.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "34fde473c831adad9ac905f59b2f07f3555f2916ed74cae5a33e3ea0a8dd502e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/thread-ia32-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b99be3760079be4a48677c35914eacc7fab1759eb465ab67bd19d559f75d6faf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/trap_state-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b338353a141029e26f8a912e97df4fcfb11e55325112c437f8ecd7be272b23d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/tss.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9d878dba444a7b482f8beca5f93453b24f8a4cb56ed3c2c0db81295fe55e6ef7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/vcpu_host_regs-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "898014e93b5ff9e9fe2395a3aebe83da2ae5526eae7d04f990a75ed3acac1b55",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/vm_svm_asm.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0767b4cabe1f3728f00a4f036bf669d494ff6fffffda06eb0bbf59156c425902",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/32/vm_vmx_asm.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a509b770288b7d1344fceb0efa3157de2e70f879c66052e43bb09f28e72b3cbe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/config-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "053f59da4fd1e3000053f9306dabc395518b48efcc621e4aca24615562feee27",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/context-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c5f089ccd8e12ae15c903982985e1c903d96a6b16efd2028a89532f067776095",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/continuation-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cd8d02e92aa999db06e4468ed312f2c72f10defbdbe74f1b299bb896bbee2d7a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/cpu-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e58f04d5214842125b8d72a9ba65ae9bba36d930db85a8feba7302fc5ae53c4d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/crt0.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b61b71b4c219aad0b310a62a8ca03893c5010f739d7ade6a0da9bd356e20f038",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/entry-native.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c72fa66d15772d7ed9f2c7e2892eeedee4273f5e7a5895bc58e9816b4e13aa58",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/entry.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a5a6643dd0ccaa01d02a924f0c47ee4b74fa44105cd20dc042c14c63e8c30717",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/entry_frame-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b74e5d6b6aa5306d326c5a04b5c22bc7d59b91788a19428cabe9d73ddad43467",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/kip-time.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2d5821bee51203c983a01763f297df6ea0e30006abaf644c89b189de9e1786aa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/kmem-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a697e3ccff09532e340869a713740d25b240e30d806fa822c1ab2f034c28b816",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/linking.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5c78ca858a7d79d39bd72dd15131a3b58b8d45733d420e4d13f3d256f7d82306",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/low_level.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "90638b54d09fc036024099e9373aa9ff052f3588ef2a3fa6d575b879a155f9c4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/main-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d2ab7cd8343a11af71cc137546e1f68ac4ce2848a97e074d2b1e7bb195d3a467",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/mem_layout-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9b5e3f44f011f1e19664cff0ff7c1c6a03327a1ff6c27c1235976c07ebc7788a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/paging-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ca9cb75ff8de962993331a53425b465f032bf1eabab068761fa45273d44b5b91",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/syscall_entry.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3a11d11a63bf0f6672cd1d2ce9992d259ac88f759fec4164b75e9e40e07f9515",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/tb_entry-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "91eda7262b66cd7ab3d59fc512496dd8105f22246531df0876c88f340753d999",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/thread-dbf.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e619dee8c36cd6920f6ea8c079567ed1ca19cfec60ef41b3093e1277b0dac1ba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/thread-ia32-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "61bf1fc3b5e96d5e80ef8c33816766f5e0fc912f3cfc76b994d20e41ccd39a30",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/trap_state-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9bd3a5a1aa500a8b79c5136dcdc9aacba4a78ccd888b9863bf4d845b8998352a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/tss-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3cc72d59eec1d3515dac0f4b96120eb54fa4f066855d2010e985db2ee426edee",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/vcpu_host_regs-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4c21d256ab81cdc39098a29ae6ac9a82e0dae238a3a587b3810e9425da006d1a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/vm_svm_asm.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d051429841cec6536e93f7665a34a11aa73cbc70b306209a51722f04d29261f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/64/vm_vmx_asm.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f59ea1bd1f1735f5a25e24eccc1597de23a1fbae89f2958d28554d247bbe3570",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "79e5f54220fe36788d1dfcde814be3efdebe94236be66df5fa601ba7cc7f3bcc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/Makerules.KERNEL.ia32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "037733140e4eb62d2a52f4315c277bc64c42fcf770198252d1a55af53b615f41",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/__main.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ac3ab51bea0926d6a25be1e2bc1a7a217e69fe8f57bd8d5421670bb5386ad692",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/alternatives-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f25f6615a0eb074ae5360fe7811328f6d396d98ea1f078dbbe2ad7a1a1605416",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/apic-debug.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "51af141fafb3c5202abebce58ea7ed6a944518b2da1a10cc8ee2d89a5b9c0a69",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/apic-ia32-mp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ffbb21e65ca7d15495452afb70a578c93b539bcb4ef8bd457dc173f9aea6dbd1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/apic-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4d78330deccc77aa3044db51e7337b6f4d185b020ec877a735f02499e66c4111",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/asm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "57a70e2e3d57389b48dddc291bb1e44114cde8d053ae1a87231a86ceb89f46f0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/boot_console-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "46a8c4613a9ffe84ad268ee008b5d8252bd9ee9fa6e1dd3d575391cc12322dfa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/boot_info-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a4f12877d26396142549c80cf46439cfcde9414f7b46dbd65eaeef3ead27de26",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/clock-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "13f24068208030abcc630d48ade226697377755b4a14f03e2b4e6a4c0778324e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/config-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ed4d658fc95a80cddc99ea1ee6ba9cd6e23c00387cce4dd3ffba4cbe86e65f7c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/config_gdt.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6b837561cbe6be5f2900d8459cf7ca42f910f04880893763c045f93b27a156d1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/context-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9e49c40fe3441b3a592fd45870bbac179a6da1bce85b9814c2d97f6f9eb4e220",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/cpu-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "36f3774a6b4eed24e839f85c2a3be2d0e4b753c55e9533a7bc903efeb353e7ac",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/dirq-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "414d4cc949a7b1ba8900bbe33568fd49d8f10302c8fefb91e69dd343f7e37ee6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/dmar_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bc0409e703d80c2e1ded6f059d82113e6e7adfc12061853f7a2dc97cf5385155",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/entry-ia32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "13457a1bff70a6dcfc4196344a16b301b3be086f018f643f07fba612bd798f98",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/entry-mp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9c705b5b00539ec8282c1536db7a6ccfb023b3b0cdd3fd03800fc68b0a543061",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/exc_table.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5dbfb8601bdf027534f296363c07067e99abd09eebd380a38e0f377375654a1f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/fpu-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ec6dbf8a06b4781d8888fbffeb7d712283221b0653eafe6abeb71d3a3829bb00",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/gdt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2ffd33b41ed5e026daac900c1a89b499a2a783f9ad2492ccd4bf8eb72acbd32f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/idt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "91dc3d2d6c5a0cdeb8a6c1cf0496539c4657eb479c8911a26864148347390c14",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/idt_init.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c73508b6b5ee9d4b8c0916a4769a7a08daa63d92c27d51dc288f1ffaddd81ad6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/idt_vectors.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a9ac47e871c358b7e224c06fdb53c98c5bc7c465fed57a758c742ad9da0608e3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/intel_dmar.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0be35e6ec30bfbbe813aa2e1f7203d0d2645a212cf2aea02a1a18cd55996c043",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/intel_iommu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "84832fd94a9ed0687f4a06cd055c91c8cfa47f72edea5e9c15a8e5800f88b21b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/intel_microcode.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/io_apic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "81ef4fbb7bf9c33e95c1006830442177b00a9ea88817210ca583b7bdb34c78d2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/io_apic_remapped.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4f0db5c696c9632ca18be5a890f32dc51b46dda92f70105ec40058a3c6f7a7c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/ipi-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5a244175b10610e4679220db1fb8627810902f7237d4d88ea1ab4de9191ad4fc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/irq-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "42ad2d28a4f7392f9a723453416f700cb25be8f966932d5598f898c9cb05dcdb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/irq_chip_ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4eeaf9b428aff01f193401e8526c591a56a638853ef26de30f2d17fb9d397ac1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/irq_chip_pic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "627599dbe7c3a00d2eaf2535804528b55b8271d47dc84b2e5e756e95364655f0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/irq_msi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "afc37a63ce9afa4a0f38ae10e5f11aaefef2711a21a41f79709fe6c80661195d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/kdb_ke-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e5dafa5c8e5cce047715afc9e4a914b4b3b6529e79a0740657a133de41153757",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/kernel_thread-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6cdda5944e3c788198a9bf5b5c2e1bfaf01e29ae44daf0e7504159362239c1b5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/kip_init-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c74079184634230654ceee712b5a9db471fb099fff6a69477a975a8b362ec40b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/kip_offsets.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d51647b845e3734e503a0ba5d8fa58a4fe31fa7e9fff2612bbd6c03b81e5742f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/kmem-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4dcdba7ec13e69c35f64ca15c5c115ed0a30686b6ee25f76916aa3cc45ea28fb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/kmem_alloc-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fefb74c6e148d4db7fc9d63428a2444bdae210ae1b85ef0b2dc552e1ecea7320",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/loadcnt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e22018076b82b196c31360db66851fa680d6bcc6f2883e0480598b9fdc5a58c5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/main-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ff26bec542c649d7af76413ec7347a2817b667fd7b4c55a3a9f361950853852d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/map_util-io.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2605fc17d34ad35e2516af18b482ea22e2e38acd4b246c5b13efc2c33656e943",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/mem_layout-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c85ddde3d3430018f034a7d0c9562df1dcbcf2ca8a5a6d903b78621f0576f524",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/mem_space-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9e2c22e8f7642470ce7dea18385d821c424fc23700b0d12926fb433840d9ec89",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/mem_unit-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ee395dd01e71943866b597457efad89a243d77064f3bc6eab372c54ee8530758",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/msrdefs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "22f4dfe68ccd87aa8293f0e23276aac32c56c41d6a15dfa3902ef5c533cc4773",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/page-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "413cf2f4157585ec2edc466bfcec29d01c55601ddae0d83867541833c5fd5f80",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/paging-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e4e1911c094875f6205d58f4c65e67f3a7fe95bc195e9678443d62b0b965e2ee",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/perf_cnt-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d09365da2c44c65833cceccf8a0e7ae57ae7b40bb3e974d8090c8ba90799a486",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/platform_control-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "47113719ad232a01b50ada494955757e48100b7c1eba996cdcde7d7a27d3924b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/regdefs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4eb0251f0c40e9abeb2d6de0aac00447df77a078898373d21a8f124fd23ce0e0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/rtc-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1729c000a544ea2a0de1433afbb00361b32ab4930786d3611b7a568f5da91913",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/space-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "347db9ff405dc1f53851b86e97eefec38641726924f27bae7292e2424afc5fab",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/spin_lock-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7b843732f0d9f803d075630e0a0268bd6e01edba7a4c9a894ca39f0e61535fde",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/startup-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ef08a06cc61fe642b9bc7f97db4418db0c193a76fb8d9cb3e2b5cfcfe6483901",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/svm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a7e4bcaa594166bd201374c389b12b1813fd87af5e2c96c617cea96323edfa66",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/task-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bbf8fd5be57e202f2db9de70d4ae1bfbfde488317e6d4ae874f02e3e39046587",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/thread-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f6b63be3c3f6f293b1bd2201b8330a01a7f7d1b2ae792699a0156b23f2982c10",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/thread-io.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ba2d5abd6ea2666b3c9564cf734297b4bb92049c367fe86d503f60cae5bb32d3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/thread-pf_trampoline-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3b751342abad4ab06e22c59e20ae4a05532ba8eed8d10a480016ec0cb890fb7e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/timer-apic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0eb3b08235996ee89cb2e79994e8ec1f61d7353185b1bf52e0b3874ef16ef039",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/timer-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "85dd5cee62e73bc57a8d93e1afa16e6b985c1f11b4e3eb3c472cb47b9ae21370",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/timer-pit.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ec7082460a1af483300f9956952a236d78c51817acd6389859ce51a69f34115a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/timer-rtc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2307e3b48252c9634895d6703e9a0e78eaa7714533aa7220b41a0988836d6a2e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/timer_irq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "55ba63e165a3ae0f111bc81f22d695ebc3af2ba238279612d00444916f97ff6c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/timer_tick-apic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "53e4b5f7719916c66d42aa1fa955fdb96625ec36a752b37a7faebaf3f84ec476",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/timer_tick-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "245a16c92f0815f54bf4b6baf68be21d658c2c686be213bf7dfa315f05ee8cdf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/tramp-acpi.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d737e19a51dfa844073b399199b8c55061e513ece9e768775b3f8391a43cef23",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/tramp-mp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3bb61e04f9eed7506c2843934eb0f4c393697f35aa854428bfa907799cf657fd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/tramp-realmode.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4417e88ef8b23256999960622c3853bfc55fca28bd3698f732b7f7965c19f9bd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/tramp-realmode.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8bb911941a372f4838764b09073436f522094f78d78df15726f4a6f3b1b9330f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/utcb_init-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "397eb7a8753863309b121f60c35bf2a4080e474e989f49e6e9297bf82423843d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/vm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "216ff3c5e1ee9b563d87db28c7e80238777bee254f1747a8dc1dfdb6f95dc93c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/vm_svm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e96cf81a91de9ee5a1981ea92494ba3d8da8a49ef75e7970b8a4aaa90aeea321",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/vm_vmx_asm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d60ea768793339105082f4b8789b4b2dca1cc9edec3a8967a60ada30ace845e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/vm_vmx_ept.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cf97ee24bffe902980172a6a851f2e9b3a4d139cc4e9ef0a97345df07baadde9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/vmem_alloc-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a94d92d8b672f908592afb2a36761172b07dd15afa4468e7117fc15c68697c9f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/vmx.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "048e5947d3cb18c1cf54c30594f1df69e81088aeb2b819451069eee3e1a7ecfa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/watchdog-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "66456be3cc3e65822ed190548910c895bba0d8328349f637417cf2a56b4ec01b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ia32/x86desc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c33425ca6baa1d99df67ca0a636b44e0731af9456aa512632e0d26484c837c93",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/icu_helper.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "323b37f0b822e021c0ef9d1c56fc24fd7c0e6d4d0eeed347b3afd88fa61423b8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/id_alloc.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d213f8a9a6f343b1fd84852d10f442337e5774fec75e1dbde1e4ff7a0f908058",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/initcalls.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "253ce490b81fdf26874decacbffa70664db1eb998dd1fd643054fefa2b572bdd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/io_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d943d52a1ca6e6b8af1bd35162408a435d3fa70d7d72de3d6439ff4bd88cd8cd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ipc_gate.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "55bfd05732d9ea8ec22beb9392c9d88ea5641a8f5fd719a05270cdce8edc55b8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ipc_remote_timeout.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "55577ebcbcb56a5bf9289dc574b0a6b9ae686636589678b47385cd7f4f3569f6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ipc_sender.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c77d299851513c6df815c0b1cab3617f1211408ca01615c9cbf77f6e04f3ed64",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ipc_timeout.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "160a10afba81bd0f3fc0bf54ed037b8a85c9e9ccbcc69acb8999057031367e25",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ipi.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dce93c93c5f86ba4ab805deed088261025eb092f2aa1d15b8c86006974dc933b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/irq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "46231203d2b3b4076fc9c5aebe771100632b1ac3dda9ce13279f87fb2a81787e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/irq_chip.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4c374d80839dc4aa918d184e5a39d1325b75a797d648aea4b3b1237a344daf26",
      "kind": "file",
      "non_ascii_lines": [
        "825fb0d7da0dd0dc2d978e9b7ca0d167da612296352c8ed04b398cc6d151b2de"
      ]
    },
    "src/kern/irq_chip_generic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "88307fee472e11b48c44f599c9d4d690ef9fe88b4bfdbcf3869f65c71986d25f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/irq_controller.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "244a008c84dc71b3ec0113fa1cef5aa9068c12acdc8acb8c1fd7aca274b2c98f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/irq_mgr.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e714c4e086e5ac480c2ae5e328309a749f0e0c4f66e956802f37a57395bb6fb2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/irq_mgr_flex.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8a7c1de7e8faa59f1d14f48ab3ec0a12050610552adda07f78e3c6c42241bbcf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/irq_mgr_multi_chip.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "47531b98367aecbee551e78f1c58f3425e0ea0f8372b949115290679fba03ca5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/jdb_object.cpp": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed explicit grant in src/kern/jdb_object.cpp; complete notice retained",
      "reviewed": true,
      "sha256": "6a1359080661ea097fae1a9228dc6448c87b95dcaa6e9974c5e5c6ffc87ec3a2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kdb_ke.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "820724d983f3be9567e21a8c2032487fc4f0384c355c8e2c68ab85de0ef649b4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kern_cnt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "76d8292665bb8f0a9651e04a358b6d18eab25ad29c2a9d983fcd47e4960b7e2d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kernel_console.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a56d651f9e3a276e12794bd1263121306b537f5006dbe0b90cd20b097c53659e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kernel_panic.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c86484aa5d866f7b78931d77f12433ea23a805d95784175247c12b7e03a3636d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kernel_task.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f7dd9b7b476f04572456562f06e2ff5b1986336272fc84a7ec626d73c4814f1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kernel_thread.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f08ef9f64e5f216b748db422c7a61e44cd8005abe20c2f898fd89027bc89ee41",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kernel_uart-libuart.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3c1e616f71ed4daf4848a0c56a77b1e635233a7daf2c27dfd9456e22b28d4607",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kernel_uart.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8d2ac9e00cd7a28610e74d97eb4bd331623ae66eeb0c8c15c1f877ff27c3923c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kip_init.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "235da6de423a6d81d20e58517fe22d873a6664261c2cb3ceedb64c20a512fba1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kmem.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a4204b58aac23c9e3d6bdfdc35de37cc8d8ff22593c97428174cf6dc0f184b6c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kmem_alloc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "db0b092d312e8b52372490557047b01a0279bd94a0f26ba72adedf2a51b8d2df",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kmem_mmio.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2e0dacec7445ab95b963d096354b41aed9fc6d0ab6fef7ddba00efc4b61cc62c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kmem_slab.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0dc8cc810cb9aad95a6b4162f010797d718c92b75fdda9f5596730b6d19e764a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kobject.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ee7027ddfab9e8d215e624b20b648f4ab8110e45bd1d7ea0714be67a7fcecd71",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kobject_dbg.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "108586cea04786c99acfc30dad9589f8780c43a322c209be5657fd7fea447646",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kobject_helper.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bc1034d13b4075f8470d0609d43714788cd3cf67835d71a343e0c624d6541b52",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kobject_iface.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "99bf5295545fdc683a880ced29e6b63f188c3842dced750184255fc0c59ae51c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kobject_mapdb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a0dd9dbc37622e1e13b37db4ba214f7d71eaefb7eed70a6cb56521c2f95e90cd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/kobject_rpc.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed explicit grant in src/kern/kobject_rpc.h; complete notice retained",
      "reviewed": true,
      "sha256": "f7e73f837c3cceb1c0898b1dc38e9b30bc2a9084f5ae00ee882d7b83f5bdbc9e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/koptions-def.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "af68ca6443d9e99d33b663aa6070a210433b6133c3267187344ea7840f64a075",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/koptions.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e9f36fc71cb00ed38f6fb6afda8240fa1ac475f936be83f00e046b6b7749b87a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/l4_buf_iter.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3937439cbb5fa162a2562793cfac0fc863bab96f2f136b9912d0adfc1b3d310a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/libc_backend_lock.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1423bb191b4703558401091c806943a7f37c7a6a81f909802c6201ff314f8c00",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/logdefs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8bb4b46a5911bbae8cb9c666659c310ec5bf023f96a888ab2503730cf5db36b0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/map_util-mem.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f03edc864798a902d3450574e1f939cc05d692680866d1e13b126fae62785402",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/map_util-objs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5686fa6200f1782f25be88934c65d97260ab8a573c5b789721361a02579208e2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/map_util.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f906b64491bab1d2d67dec2be010d4701dd4a51f08a6475d88ed3f561b871bbe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mapdb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0f611f0f806691d9c37664b5e4beef5d0da369f8dd801492622e54a31a2040e5",
      "kind": "file",
      "non_ascii_lines": [
        "bbd42b8be0e4fa3a7129dbd9ab24dbc21b652824272dff068d26883e22dcd735",
        "84ca938e335c3622a7c8c6e7228fa933de7b0ebcdc7a0a8b04cc1fed6bc2068d",
        "67e72373c010cdb95b1926febf8bc3fdbd73ccc13462acbb7332b9730605ea18"
      ]
    },
    "src/kern/mapdb_types.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b46abc1c2b4c594bcd94f3afa8ee1794f7a107ebe788dbdbaf3761ed37ab5c26",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mapping.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4dcafabe8c6787835d05f1942b82b6c1857ed2fbaded03ea9039ace554b50844",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mapping_tree.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f0f60a66b90e4fa1cc863bdb4a87f4933fe07598930af9fdf992839c06f01c8a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mem_chunk.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "79bdd7e34c4978db8e09e3aefc7d4ae499120ff722e7e7e492f16e1971409e2c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mem_layout.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8a01a8f09b028a8c090f78dce23ffcfcf2426571d7b50e5b12933286cd6419aa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mem_space-user.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1078c5e542b4680d38c9e705f66ef831731b21926897cd23545eb3396ad69c09",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mem_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ae1badff17019734ff8d1bc1cde0c8edc4dc6f18f661f6b569cc0c8a198fcaba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/member_offs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4d0371fa83c236774d41130191b7903c698675aed3c4da20f8f39345fa71a7e3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3e52d5b8d42ccda9a55d5aed973909bbf78864cc1347ea9b6936be6c56c74e54",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/Makerules.KERNEL.mips": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e187fa5851fc07cb62a7bab3b928d66e71acff899296595cdd83a403cdebf766",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/alternatives-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d8754b91aa66786cac49d36ef2b10d2c3aec3d1473dee79c80bb7832fb673987",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/alternatives_asm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4b14beac6cbbefa6c94dd1894f1980a02f7f5a48cb9c381d99d388b91a4520af",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/asm_mips_regs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ebae27a2d48a649e6f81afdbd0fe3176719fcfd9ba7e80195292371526b50626",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/boot_uart_init.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "20c9ba92787b5a86b8384974fe6a0256c7041b3af1909acb9163dac98339489b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/baikal/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d378774f87387609ca985e0250a6b7ed4288cc806b4a4aa34ed5335889155850",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/baikal/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2010986b9d0488f24f6ae03ed0ef5f8965004a95775e47182784c96870d539c0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/baikal/mips_bsp_irqs-baikal_t.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "adf1a2ae8d4fbad9be954baff1e323e097185af2e2b5a38c5cbf5cdb748473e9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/baikal/reset-mips-baikal_t.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e6fdb0e826663e53c5dd3cf02f7fc1e7180fdaa580ad6887ea71719cdf6fb3a2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/boston/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f458ffee8ce06a3caead168fe9f0137cd8e51f4e01cffe1021bbe7220458d165",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/boston/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9d33f17645a92a9797111578a54c3cae20396389099a72adf13abc5868f4be2d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/boston/mips_bsp_irqs-boston.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3d08e756fe32e825f69d9f7afabe8d7d36554fc3bb6ce8b00f5fec30e269ddd9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/boston/reset-mips-boston.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e6250ed7b15518a391eca479ef977ba3142f9af1b7012b4b95aa0954f58982c8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci20/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "51712ba15e7fa112fdc1c11146aa83fb63c435671781819abc761c4a6ab25358",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci20/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4d045982f0e0c63c488358811d06c22706109459cf2465e209462585c1072096",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci20/mips_bsp_irqs-ci20.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d6cffcb244882d9e5acd33469dd5b4a8a90fb1d2b53416612190ee1a8e10372a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci20/reset-mips-ci20.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2d7ff07f47cd9f35670d6151e71d330b2ba3cc84ceaa3239d8c79ca15f548925",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci20/tcu_jz4780.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "124c58591f0e144bab69f9a9cefd08b13fe67b1c26cf90000423f4d3d03679b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci20/timer-jz4780.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d1ea85a7f076f00774d07bf6bf56ba01dde017874c49a7bc616d223d73b48d01",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci40/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ed6fc6d0c0042819fb4dc1a734dde8c8ce46a8bf276f0008dc93761a4492cd14",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci40/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7da521a14b8639790fc13468c75db1e94ba885519bc3e1952aec7cab9e0ac597",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci40/mips_bsp_irqs-ci40.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3d08e756fe32e825f69d9f7afabe8d7d36554fc3bb6ce8b00f5fec30e269ddd9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/ci40/reset-mips-ci40.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ab211a090a1b50d73fa921177da690be1d85feae786311c918fa6dbf1f45364f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/malta/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a796f8ea661ed7daf300012adb2cef49c331da18e5ab9eaa5284f8d3431332ab",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/malta/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "41e561d18db7ab8518d5895d3860e150a943b6b04cda32fd02d5a2ca15b29ffc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/malta/gt64120.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "41697a8d01a1f6a83314cfb653e20e389eb94c76de7d740c0c713cb5edd4b4fe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/malta/mips_bsp_irqs-malta.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ea26e0a8e7c6478dd1e7260806033fbca03501199c508b732843cdaaad1767fb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/malta/platform_control-mips-malta.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4656e3322f17116b91a6a8a2b70d520df951ecde8d81728b91325c8fd252a153",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/malta/reset-mips-malta.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4b155d9db4a6d2368236f352262a5f9e7cc389de72aa8c78317f33bb2c19aef5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/sead3/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8180b1c04b20bf072964add90b392f628c1251d49ed2d9bc1e5dade7b2a12bdf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/sead3/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "33f6be9d68b91f7ad49244e9a5188500bd3072eaedb2c5e87e8dfa49c9eb1995",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/sead3/mips_bsp_irqs-sead3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "57e55d1433044e380fdeca1657c2de25319f165fc2f375b3b8709189baac8ab0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/bsp/sead3/reset-mips-sead3.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c66ed525670c28cf7e5557a7246aa0d313865278c4788fb908bb83a0a4a85dd8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/cm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "08ca3d4df1a6629c56cf76015c9b6780ff6ab4001140feef8dab20f9819ce9cd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/config-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ca9f8fa98571fa134f36ba9f4b725476e37d0287b9ee67a91aad031da8743a6e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/context-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "66e055f54f70f3c26b541fce33f833dcce5d66bad30bb1af22bf118ff191c958",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/continuation-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "700bff1f82bcf95e659ca9279ae00156df9e37588d40616d404697c747fbae0c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/cp0_status.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ae2bb54f0b8bca340139990fac1daab5e099920e5b93c9f4438eb4441e074bb7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/cpu-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bcdbc3f636b79b1e3386acf6b0eadb8ac305cc400cf055dde9e265e0c1093e79",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/cpu_p5600.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "469742724e6f80c442e04a778c29deef47221b897bbd9f32d160a344b8a5211a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/crt0.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "012fb9fcfc488d4e1fa6d307565040445f467bdb70432aeb3472e2c61c42756f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/entry_frame-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3c242d7909d46aa5a16d5384591650f2d6d253f39c44f60e11b77c5f41c69612",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/exception.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eddcf53e9aed6a548ca80474ca8f4b2b40ca3a465376b1a4f5b46c990c8105b3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/fpu-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "be5b2261ec61008665bfb6304231b4128c185c2a2129a7cfed43766d7b41fddb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/gic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "131a65ff9bb112202b36a39294bfdbcd025cf77c2b3b32012d18ae42c1eafe0c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/ipi-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a4d1da4a14d4a16709bd1fcaea66e4a87ba817353402df875ea5bc3b2f32da60",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/ipi_control.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e041fef03af2b424bc20779fe450e7f848704da5b80d484769e4ea9b5e29b7b8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/irq_ingenic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3965ac9b0a2e49e61615f60cc23fa077796d6851cd543175192339cc5096fe4c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/kdb_ke-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "adee7d352c23c834459f1a37ce160f2b1feff1dff00eae2cc6fd4424d8aebc89",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/kernel_thread-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9c9a25e35f091fd3d042321e0ae92f1088d37372af6e1c09cfeea32dc0b3ea5b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/kip-time.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c7898c18fdc23505a9ac1c9c868ed6c35c4efe1ecb7de64023511ab0275b5fce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/kip_init-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a10d4efc6a450923de8f757bdd73dd01abaf8e94f385a19360836fa5b87f6269",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/kip_offsets.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8dfe59cb4870d2727e619123ea1adde2e96a6350081a6bb9849d8e4d6947e28",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/kmem-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5d3a7f86e5587dfde583c8491c09c83b11511fc3651bb1b07a5213321e3df13d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/kmem_alloc-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4c2c8078fef42aef61490e3ca3b6495a24654d306272bc71ab27702d78a03265",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/kmem_mmio-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "38fcab1b5577e6a060b811551bb682dbc8166c189a768f159948a4fc0ed7265c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/main.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0a85cbfa15c8ebbf4718832826fa5af3d84bbc9336b8fed340b69164d1d6e0b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/mem_layout-mips32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3fb2470a16a2e3064502e59ab0427a0b9a95ae089c522b5b71dc7758860c7e50",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/mem_layout-mips64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8b4f608bbb63614b178756084057b7e66c30b2ba7429cf8717071a70f2ab8889",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/mem_space-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "58b2620e0a3654331a41493f5c1b8a13e3667e5fea2c6ae8f2684a67d8005fde",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/mem_unit-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6ead13cad583083f7382a1b8f9a26fe06a92534bc3789f377f2fec0b225868bd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/mips_cpu_irqs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "af80dc063d05981ab132682a7c87301f63edd38724a71873f352f8b15de6c701",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/paging-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8861e91e8108cdfa55f524d732b8a92734f8ff41d59a1a330ab1d1daa20f75ca",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/perf_cnt-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6362cd0fee279b80cd3964cd4a5409fa47e641a58c4f8bb3793f87a3231fe9a3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/platform_control-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f3d2db66793c0cb786d07ca259d9f148800403a90eaa21121846f462c4239ac9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/spin_lock-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "737f64af7a416bdd9e91cc4558e03dfcb5d8ca67ead9c85a96ae096e7fc3ae0c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/startup-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2f7c6a0b3b8886edb0e32f5cea89b03e5fabdb8084a42147013834b1e63dd8c7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/task-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5b9a9c0501b619e58edaf8dd7be45d433829728a0dce7b8279cb3e8ad88e023b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/tb_entry-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0a89fdabb1f83d90742d5b24d1dd983fe1e6e8e254ea009922f22c6f24617c25",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/thread-jdb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b5f0fcce6882069260649a9ba5bb79ea4d41c2a673d3af2af4905e0240dc4403",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/thread-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "03efe3bccbc9d48b0b182b2edc8838c9dc9aaaa1c442d01b22a5e7bdf640586d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/thread-pf_trampoline-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d248398699fcc41c773d31544580761e35fa64cf8e168333d22d6f36b6c2dbb1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/timer-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "70f701431d7d9e7a6601ef6cb6c1fab58928ac6bd568b70630791e7944d33dc6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/timer_tick-mips-cp0.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0f7021fccbc2ed97066e30a4cbad7f90e82fede9b5b5a18c8ce16380721a3995",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/timer_tick-mips-intc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c674876131f08ebe43e0314574648894d5fafcbcd7a38a8ab1de80cb2c4d5aa2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/trap_state-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4d4b599fc6160c30c79aeb6b4114822197747a417bb86d153287829ac318a9d9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/vcpu_host_regs-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4bdc3c83847cf1f6e4891a95f3560fe5f05fece2fe7a4deb2ccff640c699b45c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mips/vz.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "414f0860b671331ed393b22cb0051a3e9c0d8d9de342b9e9c2eb090559715719",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/mpu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8ad3294c33f18f97b3ba114f1fa36f6eb959046a746cf1370d0c10f6f5f2f044",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/obj_space-phys.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "564ff9bf39cb7d7ec6cbefbab312929981080173015b5025d6f25323bd0d51a6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/obj_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c430372aa6a6e0da3e561c3c2638aaba12b5b9836e656dfda7c416ec79f1e00d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/obj_space_phys_util.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3b619e1325e87429608aa47351404046b615e6041f5ff8b41df1726474d898ba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/obj_space_types.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3e87dbd1daf90674d9dc5235bcf2a63c2bcdca0a31602c72624b2acec0a01865",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/observer_irq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "119ffd09f9233a0178a02b9df7c67c4265959532dbc4f642842394ee5a50a7b9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/page.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4a31ce83fa4bce98a1a76a6ebb9a186a3582a9292101d5cdf14a1d8969258367",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/paging.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5e58e6698afd6320aeb349fd777c43f76c52c04307c8c6c2733339a6b6eca661",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/paging_bits.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5ffbf1c2cd688f4e19181fb5e36242405dc68554e704d5a7c5307d3c682e0a69",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/per_cpu_data.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d7ac9a5d8ded63037cda7ac4672a784184691ce7454a454082bfe57e3b895201",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/per_cpu_data_alloc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c3816c2be58fe5f34ca88566d574c444e5d2bf4a397beb328c1feb61ea854f91",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/perf_cnt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a246004588c582e65ff9cf76a287e131c47c873ca0b19c1df76ac28fb61ca3f0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/pi_mutex.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f82a4358e8d48fa600633badb11749eefabcc2de8ca75488bfd801cfed92e854",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/pic-i8259.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b6adbbf8ee0b092aa51da23a1d45c4eb77fb682f1f5affaeae089d4e727700b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/pic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "56e9a5b3ce8a25c2fe371168c7a54bf806e1d6b227cb7fbc6d00b4ecbf8e8bb9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/pit-i8254.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "338d66dc8e94422c561e38ff698733207d6567f6520a6c6e6eab2465d9be70ce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/platform_control-acpi_sleep.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4f3eccd3390b480a07b41f8b007d7179e05e745057634f2aa1a4899a9a7c1b8d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/platform_control.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "34f786e79f8df9ebd15c9370c0d4aadabede4dfb5ccdb9af0a14d79bc987855d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/platform_control_object.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "95fd6f4894b49070f9be4c7005e0d481a9d027c2399d5269d0d74d7ac74caedf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/pm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "542539656e6d26aa3884e4936efec7d82a1ee96d1ebfc89be6a403214c8891c3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/poll_timeout_kclock.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eb6e2df9396f59b52087c6bbcb16189c923e76be6930896b13622094d9a1ef8a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/prio_list.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e0b5bbac6b0990598c54ee1725f546cc0e314e8bc342a105bcd754687a06e2a0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ptab_base.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7570d1230a3f3d20c49188262a88a56a72906e9ea5a6f307f7e8816f7020f78e",
      "kind": "file",
      "non_ascii_lines": [
        "2e35d263b95ca652ebf46b01fa87d78d2e1eecf219bacf388b2fae42edc1acf1"
      ]
    },
    "src/kern/push_console.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "84e495ab921e94604a6f7bde2ba99bc8f2abf9e1ecd5f58fc0f3574130cb082a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/queue.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c0dde12a26392f5c9140be5671dd1ddb660136d92638969a92254cd427533539",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/queue_item.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a63c937b5d94cf20347ef1512f8c3b86ad0cdcfbe245662502fcd19397d59653",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ram_quota.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e29e3e8b7b703049cb868de22ccd745a70528a3ca7f33228f0a2cc91a10bae99",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/rcupdate.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e72eb1e69416321017ed1f6813f8ac53902450ed537a4abaf49a87c07b9aff88",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ready_queue_fp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d71ec1dd7c66bbbfa07e1994fdf1ac72bd9de87d9e25cb6560631b7a5597eea",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ready_queue_wfq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8d47e59bd844d061f78af5bab9920335020fcfb7719226a1fca2898208a9277a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/receiver.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fe1ce81a46b19d0799551744dd3242f4f190cd78c01c0b55f4369885e91cc1b0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/ref_obj.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c2c244803bc5e0501df4e83f663ff05c69524c80b17f6cc779a9ee13fb249f34",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/reply_space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "351feaabf1849d996ecdc003823ffc3b661bbb32661a95d3804104abbc2ccde5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6c6d3a3478bb22ff5c9187c559d253ae8ac17481e57d408dcd49efe529944fdf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/Makerules.KERNEL.riscv": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "021aacaf33c344d2628fb2a32f4b706ebcad7252dbcb0557ad54f8ec7a2f51d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/__main.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "120dec14d136c35c82d2306cd47b7746afdf15ef818474c07d4ec9d56562e7f2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/boot_infos.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1caf0abf5c42eca5f2350afcc303f6e997f41ff53adee86000d4f8dd69fcd730",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/boot_uart_init.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "28ed681a6cad1c8644b340194502900910835c9279be3b60f5ad9917e854923d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bootstrap.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "55a7d128ff8bc8c21100378c6dbfe996bd5c475fe50f7d6e72700d44b112299a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bootstrap.riscv.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d32d86db714eb8d01be70657e2d37631c4906f3df9c91509825847368f3a5211",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bootstrap_crt0.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "885677a085df222d3f706f0ddca866298454363b2c2e914a9fa60d54e87a5093",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/hifive_unmatched/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f8e29123563a67fbfa0f61ab0a1077d83d1f3d6cf39d8e638c468cf7e128784",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/hifive_unmatched/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8841745a49c0aca9845c902b575195752afd02e45766072273a640b31dd0b286",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/hifive_unmatched/config-riscv-hifive_unmatched.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "87e45c0597e60581b049ab901dc7593f35c028b8bd4e1da39cbeaf3296bfd837",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/migv/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c61f621f2192a4959cc757ba9c9f15fb30a55d734367d83e5a8c2c5b8f588989",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/migv/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "df42fb793aa3d4075937f09297f13deef6baba1a6113bb4835a746666cbd7ee7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/migv/config-riscv-migv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "71be5c586c2e7366777099945cf161723c69dcad5da9feeb2658e8ea95edac9f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/migv/irq_migv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a440c0330191b33d856138a1f7cb93a76181aa25291058fbb1e370d48382ee85",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/migv/pic-migv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9d8151fcd1e104589b4aebfd34099978128da2fe74cd4c1be604cf4241876fe8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/pfsoc/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "57a5b0e42bc2605353619b17ca97dd8de9da6703ef82d9d02575914b60fe641c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/pfsoc/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e61b52813ff142dd007721a20052e191cbcb32d8da0c806ab29213b07d3dd6e6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/pfsoc/config-riscv-pfsoc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f7345092c51621453022005b63baf9a383c54880867f12f474a6def076a74986",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/sifive_u/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bd50935be940ddab45d5dabcbd2c6034c9eee626834b4eec99bff569980417a9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/sifive_u/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "904fe55abc66477db343351c0a45d6963ef9d3ae25157c4cf46b5b5a10390069",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/sifive_u/config-riscv-sifive_u.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a897d50cd3fa4f8535a993c175723f5ec79b8dfc01b550800d6e46321f24418e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/virt/Kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c96804aedb92963fc5949b48775bd97689d68d5f6f896f66804d8b5c9967aa23",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/virt/Modules": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cea33506ee8223bb28d61c1879227ebcbffe20499c141ed168fc55569be1313f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/bsp/virt/config-riscv-virt.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e241695530a2b30be9faff4e01448965dee66af83dd7a017182e43ba129ff56f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/clock-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a62221372569e8720899b52f6462207c4aec1eff9d195e29dc5269823c0df874",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/config-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "981e412723aa58b416cf5e1001b28cd6a5b5069b8b6cb593bb76396b5772a867",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/context-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "809cdaa6ce88e01773f085edc8ce53f99aaef7c1f278eeb4ab89b9c8d07d8923",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/continuation-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1ec801ca638398531533cfc5cf57c33ef3bacc22c8f2ee01d9c429da1158f5ce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/cpu-riscv-hyp.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "59c0b55268bf04bb7366c7177cb7c2f2ac806ceefbcd2d2f6134d8698cfdbca6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/cpu-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a1e9eba24595ea311877ff3764648fbfc49fb5b0a8fd0d1958418c7ce65c726d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/crt0.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "94e993022434228bcc79e583c3a6e9c22a2ce9d90022afcece818c3b8deb600c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/csr.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "be6b2d2a70667d4be59ccbf5857729a5323a8a8fd9d48d16a538422ea6422c43",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/entry_frame-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f4b8bc3662e5f9a3926bb1555b82a797e1c5c8d009304fdd8702f782729c3910",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/exception.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "55f17b16244591c26f6cf15d38f767aab10ff6fdb86daafacd177035cf013574",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/fpu-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f7405d88372876f369b30cec5e9b687220f0733d87e910a302d793c33d4f7942",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/hyp_ext_state.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a10b449169906ac1ce1af42f53a578d35bf876d149c3e86d60f2e73f8fa04a06",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/ipi-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "004399818bd26a57a384690827b225ce9557024b5f1b4460b8a17abc51799bcf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/irq_sifive.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "14d71189130b2d84c5b4f8479a7840833c306c101ec9b0f8c367b62484ccd768",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/kdb_ke-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e8dfb68c2a01c6c401361ec6231c7e6a501dece80016a38e59b4ae2564a9a6fa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/kernel_thread-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d2b7315d64fd225adce9532a540056b7f79f59d38030b216087c9c78b4afba3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/kip-time.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d24ca05bccffb27df72338de0006d7bbc8c0daafba2a3e763daf72ff353f547",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/kip_init-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0e6c79478e9518726b43b09f3f3aed1ee1f62cc16f6c6024c6ca4be93a503420",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/kip_offsets.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fabd9987e3a7a729524cacd2492f8d83ced61649f5f6a0875225683dd9346acb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/kmem-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "95713bf1374e029c9d2d420228784803fa7c50f2dde86060e67664d7504fb09d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/kmem_alloc-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eceffad5512b84bfbc2e0e94f0514e48a50c76d5d7241d04803981cae9d36752",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/kmem_mmio-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f78c14e62a12f1e3c53a19d612a0307e23611d312ff069ac4006648f065d63de",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/main.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6d22c6a375120deb465fab7d5979f7372d6665e176458a6bf628a9809d7b3628",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/mem_layout-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a4b7d1ed97641598a60009dd0db5e5aee196d3d8497485ca9d14381e31ff89f5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/mem_layout-riscv32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b3289f5e4ee07f98d2a19380823ec936f05970ae5a23614e3348879ff7e66c4c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/mem_layout-riscv64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "90735c863850dcee374bc6c27b6ff5bef340ca4848a45393f2c201829782c6ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/mem_space-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d0eb409de9c8e339938ffcd7fb16cc189d7b86b2ca2e85897c15cfc71f683bf5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/mem_unit-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b551ac9372255781de7a8ec586c78ed4226eadf3f186b184722d28df94f271d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/paging-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6acd84e6ea906d0a8dfb954ee8db2e23c9cb3c354c8a302682be7e08b099ea4c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/pic-sifive.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4043ea1a398376057c16d0d9bf060f1315ca25c4d4c7b331b2c42c0692721594",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/platform_control-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "387742e25a36308f0b810f0a66f6079b070ece712a94c1caea6c15613731efe7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/spin_lock-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b00c0573ef991cb960069014d0122e9e80e57ce58f0fa66da7cdadb8cad61082",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/startup-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e9ea8ca8d58c70b3c7f40938ab197c90504989fa6e8b8bc9108018ef8aaa0cec",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/task-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "04edd9bfae872dc6f07b8b2b2d2e129a6e84b18caca16524ad4d5fe6bb1f7243",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/tb_entry-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "516528751f1d00694f84a9351228d88ba801389902d3a9419324e78d0d4287fe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/thread-jdb.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0a5d7db4c0546bbe225d4aa817ea0b7bd4e6632482df1ca2fbcdd6b35258b253",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/thread-pf_trampoline-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5a5d487163f63c1370d3c2bbbe47913f2ff54f0867dc1cec1d444dc2600af220",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/thread-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "94ab8acde3fed2ba7e700952f44cf8aa73d52f8873bad70e7e01c2b61c4e5b18",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/timer-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0d3b21a45520b13d8abde6ec89758f72c79a80761980e96df06310e2ec97c211",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/timer_tick-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "947fda0bd7859d3014057e2d49fdff1393a82febf6d6b583de3ff8fcba92efcb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/tramp-mp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fd5ee0853f944ba80c45b0f0b472d7fe8f7b0490e2703d9dc57ac53d47f770f1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/trap_state-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f82a7749adadd50ccb9fad7b4262d48f6118652ef7255bcd8534859e3f80ff8f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/vcpu_host_regs-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4474f70d699a1dca13da34ddcda56945efc3ab691b6c4a3c61c3b64b38642b38",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/riscv/vmem_alloc-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ce289e6f29596baa98d19723587b46ec111ddf30c9561395e6076daf0413123d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/sched_context-fixed_prio.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dc638466ae2e51bc0b8046d9e42b38d6cf33bf8d72d07c5a9eb3d9deb94db630",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/sched_context-fp_wfq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7e6e20e65f00ac6c5e738e69d34138e342c3cf8a20fff3b024f6d6b2b9cae0b0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/sched_context-wfq.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9f75153e8d6d9a79a2ac70b755f4c0554dccd71b7ebd3b1cbc6fd4913b7addaf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/sched_context.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "79acdb4c2dea09f81b5d2d071c61828fe8c3fac0d01108387794f153ca1c1d77",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/scheduler.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "57ddafb509967691c60232f126b2bba44b1bc5baefdf0bcb9a90105401dcf72b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/semaphore.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eb02daee9dc60a3d1ac1151cecf5a6032001c21fff9f55747d522f56746d446d",
      "kind": "file",
      "non_ascii_lines": [
        "68c007f51445757a3cbb7feec97d4d267aa77810ec8fe0762c0205bc5f6ffe8d",
        "06bb85d0884d2a98893a1bc277aa9d4d5c245ae676845fda6fe8ea139b45525f"
      ]
    },
    "src/kern/sender.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "79b083e121a679cb316d2b5f6f18005d67903595b07327ace2128acdd8cf976c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/setchecksum.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "14ef349819336311c1d17f358a3f031f7a042e53cd3d7848dfbfbdcb393b7d37",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/sigma0_task-io.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e5e2a14f23e98b0077b648a7fb03f2cefd06a58adb4bcb0842a94b133e177804",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/sigma0_task.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "491bf9c1d5ffe138a1e8ae2a0a66edfd017c6161e1883d382920fa94c0ca02c5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/simple_id_alloc.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a7a86a186b83acbc0212eb34dd8725a36f45473f602540b3d1fc9155d5f64a2a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/space-io.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "754f45874cd841096b0331d1386443853db3d390d83989c529fd1264fabebdab",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/space.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a3333434de6e4ae3da6643f80c0be3ca0843afe010df5cf6083cd473479526c1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/spin_lock.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e4b9c4f7dd2f83f7061c2e83d5c7be404ffc0e55789755b62dde77f588181542",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/startup.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e2223ebbc789b8d8dd4337c0ffda2e17cc1e4306f8cd78815a6bb9dbf3a1ce0b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/static_init.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e5861162b7cdd4ff5f10a3fef7fadac346acb8e5862001c0b4bbf5121ad855cd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/std_workload.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d578df6557210c4785c22e22ee1d9d92ce5e5799d95aa383577ab452ba4194a0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/switch_lock.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b077d1721b2700e20ad3838288468a7b2e155748bcc8602ebadb72b6b8e42890",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/sys_call_page.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4d582147f217d36e66f9ea49b0b48e67c5240181a21a4356f49962fc0008f3e4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/syscalls-log.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8149d71815f65cb10dfb7b409ee4ee24b35720c842708ef41194ec0bfacfa2a7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/syscalls.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c2bb9bd158e5a6fb8cb955208567e5b6215ece1d93312b98f5708c7ed0ac4f31",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/task.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2f8102fdfff1f0988ee2f4ba0a30ab0c7523062c33c8fb7b12ed35cb61daa43f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/tb_entry.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8704e264e82d8d1dadcac9fc19aaa172d013fe9b0f2548eb62a5fa495bf51a90",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/tb_entry_output.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9f007cea0caaefbd108122b3db91f63ed682baf757c143c7797cfd6b7ea9ab7d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/tcboffset.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "961e6280e876f26815e849252dafc8f35c6a6e40f006d7e4e77573a471c70874",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/tcboffset_in.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8656f7ed4bb55f8b03e7869d3bb049283ebd325374ff854823b8ffd46e4add4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/terminate.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8e8a67b9004eb8773cd6ef02920f91e4cf403dc6ac9db4247558ff60fbe1e26e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/thread-debug.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3ea815feb0e8a2e8205fbbda805e8ccaef8ae9a706ce21d71aa020fd7eb9d590",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/thread-ipc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1cbc79e7dc57241f6e7fb4700287909cd57d77191be46283f22de1ef4c82e024",
      "kind": "file",
      "non_ascii_lines": [
        "0bea48e87ab84a1e386b0f2a7addd71982dcc0ddd9c6940503f2644222159576"
      ]
    },
    "src/kern/thread-log.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8d248070f2497cdc98d1265bcdd6b323e7601c3505d6a9c05ad5176e17f74b1e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/thread-pagefault.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0fa60bfaf9e37c41aea829a4d323ac8a329b55b0439a95e2721eaca2bee713aa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/thread-pf_trampoline.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "46a6d83b3d217bf1e11cba7faf2ea2a01d78e3260b9ae148a2db16bcc3450289",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/thread-vcpu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e196b4cbd2c7f6a0e2266b40696cffa74ed5b01b454f87757ac88be3e3fd016f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/thread.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8012f991f3d13af303b7fc3164057aba9d2e679ad6ffe14e4a28f9066414e681",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/thread_object.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4ef55eff4ca514c4d1c16838e889e013c4c83e7d3366b109af3ad258118af51b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/thread_state.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ca5bd2f3bf150ad7349a77815313fefe16f3a306261bfef89cca192013064894",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/timeout.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "68fd08bdfefbea0d94866190c7512a561b9c386935766df16c24dcd1c1087118",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/timer-hpet.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7eef6662763a46c7b274af102f1b8540be32e4572bee935d092f09bd43c115b1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/timer.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "abeedf66603745643732550c4f11b9050fc2f8a388ef00da2892d4fe615faf55",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/timer_tick-broadcast.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ec25176387ad2d5ea32345608fad82de0b771094d1f5917931a84bbb07099476",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/timer_tick-single-vector.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "48bd80ffa6fa7bc5c815418c2e6d689a54c4fa229f6a7921bd57e30ab7106122",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/timer_tick.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a3c6967bc97bbfa1518c023dc98fafeb5ca8f1807ee2843f7d22ea8d967ee7db",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/timeslice_timeout.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "79e957e01808eed3ac131226bd7bdf61442809a12064c14d097c76939e383102",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/tlbs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a93dfd469a92541d3b024455ebd4bb43ccf669423ebaf38ee7f3f68f3921cb0c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/trap_state.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "60ad5ccd1e758afc7f6a18cd506432fdc091475dd9df8fd70eab958bb61b6428",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/utcb_init.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c0623b8d8c3e2a4ea704c2b21514f26e0c0b367c95ab0e16b331ef92e83e3864",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/utcb_support.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9ea268c4d043eb766aa8c455a0b7b5bb432fa19672d99cfb19920d0e89c74032",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/vcpu.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6becc34c8a5cdad83967160e9848cbcde16cd3e8e773708a0f4de36c2a1cbd49",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/vkey.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4ba3e69caec46b644baf113b4308e1b3956d956400b0f1eb448fded08ff44e52",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/vlog.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "172e70b530bd8320d36bb4d588f8ca356dddf783cd1a6f9aba0401d06dc6c841",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/vmem_alloc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "79e576d27d17a0cb6c09655c9a9bd7dca24a84dda136b6e2608c12d561cd1e04",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/warn.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4cc19998b002d0a3a553a14f6bded3580e2473e68cb0df852c822d8ad09a5bfc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/watchdog.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "64726e76a86c72e25ca0e0a71fc53c55fb2c6aa7df5ddf23aca69443dac2699a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kern/workload.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "18786b3ee6b3fab402b081cd4b73a939e90e21f94d40a39131c04758ec089e16",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kernel.amd64.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7af0ac34bd3ad6a4e56ede83094f3de4e9a0cc53b35d45ca37f27f2ce18d106c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kernel.arm.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "916b19c1394be0a374d0028873b65bb5ab52f287b6c966dea7d81aeaa2086129",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kernel.ia32.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "af79ebcab19a890d53afd0cfd18415fb6703d11c4c9225f95547d681487bfeb1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kernel.ld.inc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "463f63184d3d562eee80e6bc1b1e3360befdf4446bbbc032bdf3075784a3730a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kernel.mips.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dc8e95a0d714d9c6ec51cc24002aef5b6ad48f1084323fcfa4274fcb2462ace7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/kernel.riscv.ld": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4b116bdc32099d331a099532c16c64f72306c98267b73ed8789bb9e3265cdb06",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/cxxlib/paranoia.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cf5866a4e47fea966cca80194ff129401c441736c752a96476412bda62fa2ec2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/LEB128.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "7407777de1d486ca512a511dd4549e923dcda097d4d387e8864b24c481b9d29b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/LICENSE.TXT": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "65e9ed46a59976eda8f5bd1ea79a680dea38dd299c760bc9a8d87a764ef5029b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MCDisassembler.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "d841adf87c92132037016ceefca8b6dd2e13d2e8c61fd00be571d0ad17ce5d26",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MCFixedLenDisassembler.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a38633e42770cb7ea99c945058bdb036418e2a717ec3836711a73e6e43a41153",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MCInst.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "014684d37cb221ef9df9e285c69d021f951451e27ac5c2512315861ea2729e6d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MCInst.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "ea5f0cc89736237fe57fdbea5a07d02dfd82a7799e4164bd52f2077849fe07b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MCInstrDesc.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "9ca9c5962545d7bc9cfda55bad35239235b40cbb211d3a0b0ff50becd0a10002",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MCInstrDesc.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "b2da8bf1eaef0b5434247566ecc02e8b27f38d370d813e235003caf5f7cc65e4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MCRegisterInfo.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "7243e125850d0d767a99c043337ff90f4ea0de4c2e9acda898cee7a8292e4b93",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MCRegisterInfo.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "5be79e1f6dc1e74209d6504ff0440189752faf2caac07a6fa939bf813109675c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/MathExtras.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "b19eb7cd15886722a7701a7b93552a61dc8f2c05d27fcf5c61c8cd8bfa224a1e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/SStream.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "78756da8579026c0e86a72fe56ce0235059b44e9ec0bf62475422d398ec4cccd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/SStream.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "22921be565cff3ea4e0664e495c287d2ff38cfb1be805780f32fd8908a9115ce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64AddressingModes.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a103c7ba4bbde9bed8c175a5c61650bcd1c695dd5eae8980b92f3a4f8494ee38",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64BaseInfo.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "59f4ef2e3f288117bd0d84b277fd4476fc30d4ec95890ad7123b1ba46a2fcf11",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64BaseInfo.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "d842527a3c2df5e56df7c82d30468c3b13b3a3d966cfe9e5af36e0ad6fdac90c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64Disassembler.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "4fde78e29124d8a86494566a1036bf2028c6ab514af0d5000793520c83178fd1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64Disassembler.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "1bb3b7d7f4aaa56c8ee49b938c99ef6ba3fa177a87127cb56c55aeabf49c3368",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64GenAsmWriter.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a704dbba156fac8836198c995eed794a2b7d3d467ffac336ef98b55e1de260bf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64GenDisassemblerTables.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "3c62789a9c9abbd11588e10ef6244495d3ceeec6385b10f5be9e424c99304238",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64GenInstrInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "139f8e63894183f1c1311624417ccd87cc03c01d18bfbb6861c478e73648ebb4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64GenRegisterInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "145afa15a47b7417f2a9ecea40899ae7a9d357123127cb915d8cf816d514dbaa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64GenSubtargetInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "9f93db9d87048153d56ac8db6811eafc450f336de6d4c55b5b1cd6dd1f0fca32",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64InstPrinter.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "3f14e51504555bd9cb7f428f599146726d65cdfb2b0e444397602ad797072954",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64InstPrinter.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "9cf59a6429f34360eae2f64aa96b37c89aecc43c5ab96947702e0961e4f883a6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64Mapping.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "eda7a10d825e1155b323399ca907772b3912329e7a7838491fea59afbe76428d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64Mapping.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "b98a45aedfbb40d354080875aac156ce4741c6e8bf473a77676d21dacee24122",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64MappingInsn.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "d2cc39869a606719f5c02f182efe9d60536380ec510a43669ce69cbf5bee313d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64MappingInsnOp.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "1b580057df1a126eaf886012466f3b95cf6b96c3167d457f46185a3d93401711",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64Module.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "8986a105445d8a80be86e17fd14458d8189a634c4a3d7490f63407af3ea3133a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/AArch64/AArch64Module.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "51288cb01799a08e50826844e8bab3d93974a66209eb67e53c15b13b11abce8d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMAddressingModes.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "3c0e23801f881e38e1e0d959590df3f25dd2fe5c0302d2666e8a6fcf902769ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMBaseInfo.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "d61bfe473de5839455a29e6ee697d0f46b876d0d07ba19713e35ca14315ffcbe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMDisassembler.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "dfd11ea4926dce855b77aa51280c70cf883feaef13938d624091320272155544",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMDisassembler.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a4f90a5fa8470a668491c5a572b8d2dd5d5d10f34866457b526271d7215cac83",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMGenAsmWriter.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a53e44cc50ff08a4021ddcf8d8cfb81d953638d4bdccf62d8c848d4a0d77b87a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMGenDisassemblerTables.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "33f104c801ae5e45d516487078aa5a57f4f3869fead0040a6032f938ef2dcb43",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMGenInstrInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "3a7b367e21510b0c08e44278ad6d0e257b6dc2308144d642aebc93b767a83c51",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMGenRegisterInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "88dde53249f86c09b6f84c2e4ea03a7cc0670ae2cb6c12fb9139a95fa538176e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMGenSubtargetInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "85f8a6e09052e0da4027f631407240fbb45aa3ac17dd61af773dc41c81d37927",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMInstPrinter.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "f81c89e6954ea4f844603e9ca9297d9e642d84deb993e9f614f9412b522795db",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMInstPrinter.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "453588aafa19d6ea1c193917c96a41da773d9b72f45e2141a60a129cf3f39f66",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMMapping.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "796b4fdec7bd9c726982aa17267653aee28d3bf29e18f978c9518284655dc4c0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMMapping.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "8523d16dc7b24516dcc13a759a9d28fb13abc15abb37a7a64d9ca763b05cb128",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMMappingInsn.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "e76fadac1faa58de81152b280337f99754f2dde92afde675803172d2606ddf6b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMMappingInsnOp.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "8da10949c61b896e98a8ca63465ff83919d8fa978ca2e71383c2f5258676712d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMModule.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "2933d7692cd813228b0326ed28c0e69870d30e62f3cbee05be298e72b645906f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/ARM/ARMModule.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "22904c1cc44147d703f242aef281a85bd3e7e47fe7d954beb764869cad214ed9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsDisassembler.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "d7206d56fb50e43c3c1b22bdb03f4033a52aed26b737492fd430438561f66f55",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsDisassembler.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "643ea2a7aa39cbcba1ac567ab210571af65d83ce1a598093237879c7989089a3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsGenAsmWriter.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "14650be70d69680f8ab0f356b75e5e9ca709435e6120c92c725531a849bdcee6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsGenDisassemblerTables.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "1d1727fd7f9baa4cac428e4b17c7ed9a3a2ad3cb67727d56c31b5290ff9b8b82",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsGenInstrInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "d003bf686f4f6ee8e315a0ac5f1bb4c3fa6ac4c65a2246137b17408819d05c33",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsGenRegisterInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "cef0401dd04151d59f5180879f179497856a124ca351a804e818938346e949ea",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsGenSubtargetInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "3b21182fea9516615af14d35f28e1e5f2e69aa097baacb27ff20030921701669",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsInstPrinter.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a4592187b95037ee30747ea289066ba491c45a28de2bea41a11a357266eca3a1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsInstPrinter.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "ba66009e3554e7251c910a38ba443ef9fb65ddcba22fd3723d31b6bcadfbccae",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsMapping.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "7a538667690790e010df3e6e47a1672e523cf78226fc2cbbba59acba70ad14b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsMapping.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "73d46826302d261d8cc495a44b2ae67398900b6f92107c973c8095767bf29cd1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsMappingInsn.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "212d442489aa9adf73a0e907037b8d571c7931bcc5183d7ea72ebb82ba068c85",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsModule.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "137afb82053f46add058fde243bf5fd7562883f0b6fcef173e85afb382e90605",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/Mips/MipsModule.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "37a720487bed0c2299da6e6b40e6527b11f3bec3d155ca8a14d205c9c5c0c316",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVBaseInfo.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "f2779ae3c7506a330644c679974787f8edcf23a3c0fb486e95eb9d1a621369e5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVDisassembler.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "afeb8b56e9ebc303f077f48071667209d8a957c045b2f864bf4b390bc4010e51",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVDisassembler.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "ce5a6e94a5f899b8464949e2c007cb9738881d7433e35bfac460dcaf546a36b8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVGenAsmWriter.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "26940a7ed8ad3fe2fdaedfa6ff53c2690609f268258307218e63ce5165287969",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVGenDisassemblerTables.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "138523b52222370eac66fe7862d6cfdfa4ecb6e530be6b970f809ff76ef4348d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVGenInsnNameMaps.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a32bf58474a6337f74cf6b2c944465bbed5337fb06f3b8cb48272b4e61cc0aa4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVGenInstrInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "69d95484ea7ffba6275f63b58e3e3ec579acdf8aac3c5f70f86ad24e235e5a59",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVGenRegisterInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "3e22d6381d2d86f1d265f7e855a004331b8cc9f4f92c71a8475299a91f8f7650",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVGenSubtargetInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "b20d4a6a75d59d629aee4268736897178226f219095df0fb58996505ad115324",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVInstPrinter.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "ebb7c27e3f4f849365f06621579c08d09a95faf597f2ae079bd91619c5b33e2e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVInstPrinter.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "2dadd989772c7973d6f9867b50c1e0b7d0a585bd07eeb3f9e0efc07671909239",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVMapping.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "c459c06a9d2dacfe00b98f59a1e2da8e4c708e3c33eb4df6ea40437160defa4c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVMapping.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a9bca7a84a42a07b8949b16edb1305b77cc5204b38452b6ef23abe52e137b215",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVMappingInsn.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "156deccd9d387256a2f8cfccb22cf320b84ddbe22f7cdd8607ce731229a46349",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVModule.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "7b7cd5b27ff8a95b04bea2f2aacccb8c4d29ee7022d4c9b57437cf83fe2ac11e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/RISCV/RISCVModule.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "8921c2cda84d2c4c3dcf00e2fc9fd28be399c09925d7b55e8264c8852dba6dcf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86ATTInstPrinter.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "b8dbdc7753a0953ebae1d3a2f2215d421a03f1b8b2f5c02fecd7fa00dee0ed90",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86BaseInfo.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "6595b09d9343bc085de7d348be6f0941fe2e090b804eb7b41be013a399b5f164",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86Disassembler.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "022b6ea2fe4f50318ffbfedbdf231a4de5f893a916eae6999ad29af072112a8f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86Disassembler.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "c6b1022cdd1b6ab45c46ec9062daba50228766db98435aa0a44477d1074332b3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86DisassemblerDecoder.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "640f16cac521e6ac7cf782fecf836a33ea535df5b347efa9a649f147134a6520",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86DisassemblerDecoder.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "8a17fb566df43a67fe32c312149df59bc844917521ffad70cb230c876550bf97",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86DisassemblerDecoderCommon.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "5a5bbc564abca67fa02275795fb1948caa25bb34f6831f2c7b187c6c96de35bf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86GenAsmWriter.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "ad0938d58174b4dd39bbd47dcf27a9d29365f46d49fcc91ed170f38f62d1b2dd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86GenAsmWriter1.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "9ac7561bd7a60524aef7006afd25ac522f1528c66c8730322f6b16efad3a25a7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86GenDisassemblerTables.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "c2c0704b8e4cc7a9242382335659c57a40484d88b6bd4db228092f83b1575548",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86GenInstrInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "a1eff98ad53eb87195f6e1f2c04f12c3d8e763086dfbd7705eb1b0183d08bb0c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86GenRegisterInfo.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "30403a1e08980272d86a863fdd273029e270b3ea10db328e314068349121b522",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86ImmSize.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "bdabb072d222fa25821d5cd13e12a8bcbdc4004b8cb69d858c743d24eca345aa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86InstPrinter.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "1cf8a1fcb491c9720c22160d64e045079dfb3c65ec6906312d23230c500af7ef",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86IntelInstPrinter.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "425a1fb42ea55e9025306c04bc65d9a477ade65f040fe702b3fc21d38fc69f7f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86Mapping.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "fc04b2b057cf1f5d904597f2ac2345379eff6842ca425d367b582fadb83b47da",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86Mapping.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "e1476f14c3eef4b6f9b940a3242faedad2a1fd3bf4dc8df7e9367c32a75a20ff",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86MappingInsn.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "3dd6f2bfe73f32b70d3e07f45fcbeb79cf226f0e2d601ab1418a347304cd6ba1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86MappingInsnOp.inc": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "263c9e645a360dbc3d577973a38a2ff0b50c7a0ce2d6b39f271f5eb2ea22903d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86Module.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "25d812cf57e6add4ff3f6c40c57bc22d6c2b6cae210fa623db2f01b63cc584cf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/arch/X86/X86Module.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "43eaa343228da3f51df7eb048e9118e34c86512ffb2c4ef9619c65f499f123d2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/cs.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "aa55758a3f9036579c76e2ea1f28eedbf46891649f6b0b5f09add91be9af0632",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/cs_priv.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "04a6d7831448f697ac83a6dec52e1de765b8a7f6787f80007ca1ffcce7529a41",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/include/capstone/arm.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "489e0700e40901da4ae1cc307763b2c7b1e18cef8c04359ebd09cc8242e3d7a0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/include/capstone/arm64.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "92c8dfe570c4440c650957e77135a4c193676797052c7925826d0fbc6ff7d585",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/include/capstone/capstone.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "9a3ae0369d4071156c761e782d377534c3312e78dab1bff6057bb9642292347a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/include/capstone/mips.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "4bcc849f09b2c7de2b12432f000ba0a54bfb86b1578da1c0f6ede103053dae80",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/include/capstone/platform.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "65b1113df30e1bb7a758fe1ea48b058ed0eefb4d26fb4d00dd1147c178632784",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/include/capstone/riscv.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "8c5d9f083235d399c54c9705534e143999aeb100fab958099b07705fd9eb8405",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/include/capstone/x86.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "25978059125e97699345635b7719f24cfd2ed877f5e1e2eca2b3379d5ffde531",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/utils.c": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "29fcd89c066702897611fe05600667d194850639ed6c87f2091491153a3caaaf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/capstone/utils.h": {
      "license": "BSD-3-Clause-Attribution",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/disasm/capstone",
      "reviewed": true,
      "sha256": "cb06bff30d63020a7d801d956b878a9bb01166e16555b8c7b7bc7f583fdb0f81",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/disasm.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fbc51ce252ba2854604fb2911acde3270a2ce10e7c25d6d98d32938cc538719c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/disasm/disasm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1f2fbeb488339ff5d3fbf2831ec9249b89aaee1090731e4481720d7d6391dfdc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/adler32.c": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "7a921ef4c444aa3f49c312b39499e17bf12b25856ca5a904ea768037016ab337",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/crc32.c": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "9522f5b68c3c87bbdc55b5639b75015cb3dd4066097f81093bee724ece6fe2bc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/deflate.c": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "24de2ffce0907d7692fc6eb5abcc200e9781a8eca24d8db9289f709fcdf5e3be",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/deflate.h": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "094cdbd9e851140334099f46a2047b9ee722dcc3f2cf3c0b32e4b56dd5cab823",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/gzip.c": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "a6caeef2f681ee03d261eda33f1cd14524e79408dbb1fbb4b381ee482f6ca4e7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/gzip.h": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "9a7b4b7c8bc820d3da8f7c760cac177f718be7144b4f86d9455f35b67eb8193f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/my_conf.h": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "5a6cb5c9f0ca0d4e0e1127623dd1488f1c3279959922b0041918374fdc26ffc3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/trees.c": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "41ea406e6be0b4f9d92c1877e89093868f5f25a723688880cd05cda1b5107f1f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/trees.h": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "81579041310716219bbbf7c98849d91f5aeabdd7eadb1f8e9d7e2aa57724b58b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/zconf.h": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "ed7b3394e9e6749dfe9190fb12cbcdef7d01d948b2795952c6a18820cf89cd13",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/zlib.h": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "7388aeb8cc550dcbc158fd43dc90ee900f5fc6a3d055ceaf4c83aa441e6d387f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/zutil.c": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "06004f5eb2bf807987c9339d78792a0ac78e4bb66b8151f447d81375df9ba64d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/gzip/zutil.h": {
      "license": "Zlib",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/gzip",
      "reviewed": true,
      "sha256": "9e72b2bb8d7ef54a885fc09183ebbb0ec6431495e63c9154bb10aa4e5f2b2c5a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/host/endian.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7a10e9c5c6b288d624a67038b4eb2faa90592adc2905d89d449a8ebb6487bf01",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/COPYRIGHT": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "f699f9ce43f98c3b09b3e194cf62f5237979a0e765bc079650e07e1e7c8334cb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/arch/aarch64/bits/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "78213ff8a529db45cb1baf5310546e5c297e556e1c2a8e959627a32d80c973ba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/arch/arm/bits/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "112f0f8cf2e66ce167cef3a00f797a219cba946995b3d44cf4683f45af872114",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/arch/i386/bits/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "0db48c3d16df7d3a772667207657e4463335b0eaa6a197b98f76a995047754f7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/arch/mips/bits/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "ded55f76102566d9e4dc70f469a80302e727f1397cb619a3ea80baf3eebbfa4a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/arch/mips64/bits/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "5e0bfcbdd9e8677fa80cc05ef59edd7e2c85b2b5e0fb3d32a0e4bc32c1c5a839",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/arch/riscv32/bits/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "ba4d9ba04db86677e760db45022e23a14244a804a5e28c9d4a5cf8199561e280",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/arch/riscv64/bits/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "5f883846898fd0379844bc6db9082a7888fa8ab36c81c46b5b40fabf348961f5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/arch/x86_64/bits/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "e6a786d963fa17e3f14986b63860c07d3872061f4e964c3d899214888a1f70df",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/glue/aeabi.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "1a8acf3cd736bb832860c5405940cbe758afa12f3998e5dce0a2cc6182191f72",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/glue/atexit-aeabi.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "45e1e13909ff80b14870d3740c04ba16a46b209cb29673ced3f1688879bedb28",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/glue/printf.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "fe25a0cbefe7ead4e7558112fca8d0727eb2077dd17732a79cc840d046b99a73",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/glue/putchar.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "eb32c39d8502cd96c584610c5b344f8f0efc91e5f2433fad2f5a229a4e584e48",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/glue/puts.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "023b3061b6bd4a8a2029bf60d125653edd827d847b7abfdab9d7d46d90809fb5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/glue/putstr.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "d3b7437428c163f599d49b2ee2152a45cab28de79effb9b0ade769574a2d9628",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/glue/stdout_write.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "af6a3a2a79d8b936308b7909398f4f63988063e679eaa3f2329430768528a354",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/glue/vprintf.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "b1a77732e5e90f0173317a3e07e0cdf0ce904101e625cb5c09ee49c9da1c3df7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/alloca.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "8768404d7cf4af5fb135b1a2ca91765bd2be311ac072e0ec8b68f5cb3e6e0f3e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/assert.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "c26faa766525c5edab62ea35c9403053712baf35dc416c615183a40cc2b3b6c7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/bits/alltypes.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "a0c07e6be40345e57f63604ea7892b4aa9f4c63d9b377ea3d2af66c74254680f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cassert": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "5086ddf7453c9479c43af468a14b155878ce2b2613fe9e4a2cfa33a88c151e32",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cctype": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "6b6ec13323808065410ec3241b775cc150702c749c8d8f35105e9899608700eb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cdefs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "0c50fd02be3d88f9438a798797a31da5b46d28ea2fbaedb92a9d481ce35c63ca",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/climits": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "b288f870cbc37e2a77ddaf3a0df51c1993240a41ea2174bdc09e396c37a9f50f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/csetjmp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "ffe941ebef10f704ef29daf8597eb1a8143413fc8e5fe83a2197931b0802a201",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cstdarg": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "96b10ae4fa7c5f1d0858caf0a6aeb37438fde1f48b1a927494970cc04deccff6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cstddef": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "acbe55a26a240c3913927c7b4240b0f14c05177aa006a2017aca006f5227fff2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cstdint": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "ae1968e348ff8bf01c8d0e8eb42eb80feec0795615c72a78bc0b5f66d4d23b95",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cstdio": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "d4d3d9a313b57aa74503c6721ea13d9dfd3d0881de32851c98fdb445fbfc533e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cstdlib": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "cbdd189863c1a13b59d2fdab03b441ab55899ceea5276775e3edc9eda16f5ab1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/cstring": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "8d7b2aa2e924531344d65255853c0e9ee9bbdc87ed5591e5ee528af8ba9b4d40",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/ctype.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "edb1d279fc91819bd8a14e400c5046f5023e0180134e8ed81bf55afda8272161",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/features.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "94eba7dd31d2eb18b6e65411261f1adf0d8b631d983dc89843db4f2af1f86390",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/inttypes.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "dac325b843b43d6e9348a91fce5113f3e8b9d518c28a63883f2c91acc5716b1d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/limits.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "a86dfa8c8b3a29576067917a455bfa9399039e85a1baebc1551ec08b362928a6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/panic.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "735263dcaedc4fc70891d59e1ebfd57ffccae0d5cbbf2c5a487e2fb559fc7f84",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/setjmp.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "1dfbb3c229fdbeebf63c82ef55f409b8b64d6c17b75f86630cbd0d94a46302b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/simpleio.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "b5317997fbcc87d90c8c377cf0f137ec32459358bdeae83071f888842f6f1f56",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/stdarg.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "20b903cf4ddd7e0244e0bee6e615e24e1921bab2f0986957fe4f7869c608890a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/stddef.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "4a61f6a8e59d22385475a2122c338e44fa37d7322668d6e6b589f7a695803dfc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/stdint.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "b06272f6e81989183f65ae6fb7d73b9d46fae2a717a654de6e77338eaad37192",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/stdio.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "c2010280f3e0f89c5a978762a5b5deb6987cc1fcc8a66d9cdcaf47cf2e2aaa82",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/stdlib.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "5f351561d4a8cb232af5733bcb20016dac819d89db8cba954014e5c1bb13596b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/string.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "a0905e04d845348610fb4b6bee4d0e6ec383450d30076af419ef6f313836c90b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/include/strutil.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "7f7a2a500f87def837c70c30ed68256dc0ba75f17451b0a7a830e6e64fe08413",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/ctype/isalnum.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "22ef09654dd27ad17dbfa7661ccaf534ad40aab23489323cf4767a37b75928b4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/ctype/isalpha.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "246d1080a6874f4516bb07bf6131d244edc3f0de42e9c9809b04d0e3230f9a98",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/ctype/isdigit.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "81d4c676b018feb751c800bbbf184dc18c88b9529305b5638bcfbce5d74d90ad",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/ctype/isprint.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "b62b8cd77798b4ba2562df9e03431631e02350628fcfe55d544ee7da689f4450",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/ctype/isspace.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "e3f2387c05bc99af328fa90a3f8db4a6edf8895d4d99b5cddbec79be10e57387",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/ctype/isxdigit.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "ad4fbd9beb40e2d08fb9e341f86d14c8081740bb2620e3392cd250aece47e3c8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/ctype/tolower.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "0ff330ecddba0b4fe4508e15b44842b89e2f6b9d74e5f6e502722d663e0718f5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/exit/atexit.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "55e2bad9b6f6be8db70489865068f484198ed610615c2cfb72b31ec8dd36bb06",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/include/features.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "15e649d7cbbd9c3300607948512aab5ab2ea5a751ebe648e7d98e6a2abbf5480",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/include/libc_stdio.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "4b2b70569393ca03641fdd2ff6fb008ea33a6f93965521bed1fc3f1195592a7d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/include/stdio.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "4bd8fe307b950ea898e7aeadedc28fe85735c372c5be05d30569aa8a895e116a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/include/string.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "93a9f37d69566fe060496888e32ce151592340ceebe541014dd2276eab71e8b7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/internal/intscan.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "f75e22b60411efdca4384b977779ea19901a8478f18750caedce09a7308052c0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/internal/intscan.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "31243198e69cb838a843e4db3bc85848569e4bbb226fb425cf9e111acd14a9e3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/internal/shgetc.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "8a0eaf919c886339a10b7fe66fe2c43fd23df241418422273d9b102d1115b5ce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/internal/stdio_impl.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "df04d6f33d5467605913807f0bdecae17db2f1f8553921c5ed983bcc77e39166",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/aarch64/longjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "d88077cad83efd1e364769dc4bfeacef9840b3d19c0c69e98a4261be11ddf91e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/aarch64/setjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "dbc4241ed0bdc5233e2338133fd513ceec611773742045f8b65cbcfe3fe3bf47",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/arm/longjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "28bda6651c126d667b7877767b1f712b09dfa6c67de2b2e9f72622de3cbfc862",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/arm/setjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "43162f3e04c627d1e0bc5a468cedc43109eba9afcebd61c1c839cc4887940042",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/i386/longjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "6773b9fb52f9d86df6d33324afe0d12165c682fc8331ff814e41c1e173102b14",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/i386/setjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "01839db3d9e77c2ef4d642ea2f3f4522ea7ab7531e3b2501bc75121721ade7f5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/mips/longjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "ea5bc9136522f628b1382c3849a83fa618b1fed6011ccecfdf3f813fdbfce0d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/mips/setjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "d031a75e0283380481433b733bba7ef5148976d5ddd5b4dcb71e03c0adc96407",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/mips64/longjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "1b827cf2a439a1e76c3c98f25bb0e9c55846625eb03edf2b6ee16f35d4f94d95",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/mips64/setjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "6b83bea6476b081b219c6fe0764fdee93a408aa6b9991bed6824221975ac1bda",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/riscv32/longjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "88d6f9c7bee5bcd4eb03bc57dd0f07f35b8a9e74539481a78d9de6d75ef29220",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/riscv32/setjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "89e1410c48424cd8f872fb45e161dc6a3b4fee71a47fd6d22b63a7675fdf26c7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/riscv64/longjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "6a1caa8ac715acf78677ac7ffcb9869198f2f0ebe8317fc0b9b22b07ff58b195",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/riscv64/setjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "0d6afb1040742c02e01c5c122f0c20d083faf447ee0c75be939c93e6c96d5a66",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/x86_64/longjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "c505c42f1a48b1150f9b8ef5f8f13b224c65ee1a7c0765354dbdf66d9eb177e6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/setjmp/x86_64/setjmp.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "7b74b13ad4bdacf019ff72dc55486119b6d8caa5ba1417f88d73d2b583223425",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/stdio/snprintf.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "be661cb258170863a1372b8e5998ef345bb8ef8e3f06d38a603dfda77eed4d4d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/stdio/sprintf.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "f758fc864ff028c4d2e3430a1ff3f7d40c6c5f04a6e97e80f54784957bcb6d81",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/stdio/vfprintf.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "75ff4f2c2e073f4623d0e05096d354aea2ea82497038aaba433579488c1bb21a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/stdio/vsnprintf.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "291056c7adfd89547f1b853d3ca998ac350e154fd71c59ba37cb74e173996bd5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/stdio/vsprintf.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "7290ad13793a6668b68d075e2aa57678f08639aa4ce7345eeff16d9f9cb4bf7c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/stdlib/strtol.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "a0a716f12cdcc0a7e5f517a533abf7814764ec9c1dc7be17b1c2277e4644d87f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/memchr.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "dc5a40b41f7b74c0fd01adff943c5ed6f082ad579eca1813e2600484353f1d39",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/memcmp.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "826b1b5e84d3c0fb68be827c051f6dc0d67da17ee3a444e94be0e5360586916f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/memcpy-i386.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "a94980118aca2436a67b8198a97d8796698757f4814ff1cbe41f44e960f40cd5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/memcpy.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "83f3b35f34f1889e17dcadbb17ecada1d585ff378d88ca060e998a4141bc9b12",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/memmove.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "7fb3d2672bb325e2c4c019fc3ae2cb0d1cfa84df12791351b6c5e8522bcbf081",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/memrchr.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "5cba6bc6778480c1c26379cf0daf923b0480e5d8486c0f7dcc88220f605f34b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/memset.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "6bd9e51fad017d4de1c2023d44f3baef4e64e45a2cad73765bb19b7857a77dd2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/stpcpy.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "aa450bea85e659fbe21aebd2e6a86c72c93ca5cb61ecac89438219d0364f4b6a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/stpncpy.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "81ad7476f6e18acce087226884cefcd45df937762279293bd5946f19c54bb7f3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strchr.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "629d401b95d07ddff9560eb5a9cfbda1652caaec273dc6a79013a56b1790af53",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strchrnul.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "1f966faee77054b73b131e455bb8bc2b87c140ecbabade1f6111f6a0659733af",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strcmp.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "3e1793ea2dd358e5c884c4dd232083605d0f6775f7ebe19d03d64fe97068a78f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strcpy.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "3785cd5bc3e08049617db754a3677f7485e5e7bc4a7901102af1604cee290b71",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strcspn.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "aa472d155866a9c33fa84fd338d663d686a695c8a99e5c1b1bfb6c35dee7c066",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strlen.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "cfc8725af99a65a51534c64c5bd37299676e58b8fb1a6a8d9c2674d4ad758f45",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strncmp.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "ddbb11c703886e54d5764a51d742e21aaeded0cb5ae4f61f1c05e436f21e7824",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strncpy.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "88301f7a48004250e1833e9155c7d2fa607ffdddca3b1b1804774d93c82acb96",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strnlen.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "11d64d6b32c34abc9f9fea7bbd0c2ef2fd2a55989f390e2b70153ac06614211f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strrchr.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "a39143d07d79906d370d268bb7934a203918d7b7b54bae0a81da277a41bb9960",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libc/src/string/strstr.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libc",
      "reviewed": true,
      "sha256": "20633e5a8181f933c1302f881c51013e696f51dd50cb7013e21384b72ed7b0cc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libfdt/fdt.c": {
      "license": "(GPL-2.0-or-later OR BSD-2-Clause)",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "0574facf26b0e9d1fdbce3747ceba66b4bdc16bd161601e2bed6a2791b1774c6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libfdt/fdt.h": {
      "license": "(GPL-2.0-or-later OR BSD-2-Clause)",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "f1762a7e8de699e4c2dde3f39b2c1bee7380e8a13017036f7096b688efa059d4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libfdt/fdt_addresses.c": {
      "license": "(GPL-2.0-or-later OR BSD-2-Clause)",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "11ac9fb9f20f798483bc1e9e2835b79ef110e55ed7114e20337e59a1b6f4125f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libfdt/fdt_ro.c": {
      "license": "(GPL-2.0-or-later OR BSD-2-Clause)",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "69e99486680db4aa7abc9e8a4bc64025084e84f1fb565f6efe8a9246f61fd936",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libfdt/fdt_strerror.c": {
      "license": "(GPL-2.0-or-later OR BSD-2-Clause)",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "4a1de9eb7eadefe07cfe53c238785aa9bdd54e5387903c2faa7e42006027c137",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libfdt/libfdt.h": {
      "license": "(GPL-2.0-or-later OR BSD-2-Clause)",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "9c95eca4d786550f9c5259f8925a0927079642a3effb21a82912070db39fec01",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libfdt/libfdt_env.h": {
      "license": "(GPL-2.0-or-later OR BSD-2-Clause)",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "687b9e736f5e5b26812dc3e01609ba3a90c902442cd6f9446030a1f093a0f911",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libfdt/libfdt_internal.h": {
      "license": "(GPL-2.0-or-later OR BSD-2-Clause)",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "8ced50a74598b7a0649d2127c0aa1fc5abc0597d55eb93250e0c818a52cdc0a9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/allocator.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "29770b3a57c790c471cfbee22e33ed67b8ba36c59de09d6f278b772f8c6a23e5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/amd64/atomic-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7b866d9f0727e460bf474927698ca5468bcbcef27dbbbd9a64c514506f184552",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/amd64/div32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e7db05ee3ffd90927aa459c5125989e536eb68a9b52588b5cd50d5ff729a2e71",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/amd64/mem-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "536c7ed835c07edd2393b0dfc88cf52ea25c276976413d9e37ec3299ac65c9e8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/amd64/mod32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d894ec87c4339f5f8a47d86a3ac863c17cd4b6d28ddb70b94956c8170f68bd69",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/amd64/processor-amd64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "24647b7ad6329b5cf019777012f9a14302355912c7e7fcc66581c252b141ab66",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arithmetic.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d936f85e0ccc3d66b106c3dc92f8827e6d2f8174c9ddfc9de68574491af1336a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/32/atomic-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6de6f061672f6686b245b13a3710009a46581032155dc9c6980fc1b5d1e43bbf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/32/gcc_lib-aeabi.S": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c96b115240d6e14fa09498ea62b5808d7728ca5176defdeeac88dbcae330a538",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/32/processor-arm-32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7f1beb8ea23897e15c30efdecad7cae4578458049c3c606c85ffe111a1455f81",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/64/atomic-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "40acc08576167f3cb7c27eda515d862dea90b4d4f95f86cfd7b77bf26590ffe7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/64/processor-arm-64.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0dbd1fcbcfec4f21dba3d8d5dc9b399ccde9fbb5c0d7ee39fd8bf42cc22591a0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/atomic-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e223ae25b7f32305e67dc0ce47ba8d2c3db63f1b6984639ba12445858aa066bf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/div32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aade626311e911a3001ff7adeac0599242e885dcc52476017e2d57e0d7e86246",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/mem-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c789db2ad1856e9af46f488bad660ff0687c7de3c23329b3cfb7de65262cbe62",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/processor-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bc85d8c8dc2c7a6fc5db88a30849d399c4ca505e533d81b687c4d660888ecdef",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/arm/scaler_shift-arm.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "70188125b8a2627931f374b3cffb7a15c98dbf3bcf994c979d57f301deba3995",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/assert_opt.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eab4004c86412295d403045647e2a8ec4fb981ae21c5185cfe256870c57313ac",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/atomic.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a2360255c851b943dba6dc3c27516c9b197757e474ffc24df29695dfdf0f65c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/bitmap.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "50da19687fe395d912311bd478076279def583c0d31b84faad3d0a47a8b9e1e0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cdefs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0c50fd02be3d88f9438a798797a31da5b46d28ea2fbaedb92a9d481ce35c63ca",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/construction.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "85b561669b334c640995b45735ae84ea9aafe3373db8b5e7190b695d67edc93b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/construction.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7bde009d99350202b9657b3e72b2e22e5e16250188f60a61865772c6df37c9be",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/avl_map": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5e554fcb6597fdf8c8ad32618164718032f1a1668f610e1880723f1fea29734a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/avl_set": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3d17a9732a727ee9302798811a60db5037e7d5a73077057a454b02b9f27ccfb9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/avl_tree": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e3d640526f05bc520de149835402ee8bb2c683eafa08f06730887a846c29aa33",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/bitfield": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f6c99ea4793ad0c3ab718b42a4cff67d2a69449d8ed11cb265701ab8a4cbc317",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/bits/bst.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5dc25b2ced20c5e6927a7291a06e988483ea7f602dedd13826e040b7a896bf54",
      "kind": "file",
      "non_ascii_lines": [
        "d09019497c240e26b8947bb33710944fc9027e702f2e00f744d8cc48e5019c9b"
      ]
    },
    "src/lib/libk/cxx/bits/bst_base.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "59a3a5107935eba0fe289dd7a2f081c44fc2d62546fe0c164b680821a2542578",
      "kind": "file",
      "non_ascii_lines": [
        "d09019497c240e26b8947bb33710944fc9027e702f2e00f744d8cc48e5019c9b"
      ]
    },
    "src/lib/libk/cxx/bits/bst_iter.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "68164c77ed7bebefb61df84db38d4ee1ae105326f411383ac7363f1e4f93f788",
      "kind": "file",
      "non_ascii_lines": [
        "d09019497c240e26b8947bb33710944fc9027e702f2e00f744d8cc48e5019c9b"
      ]
    },
    "src/lib/libk/cxx/bits/list_basics.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "af70fb9d1d126b5cefcc61a6c1f406dfaeb653937c0b7a3b521a1f095005848d",
      "kind": "file",
      "non_ascii_lines": [
        "d09019497c240e26b8947bb33710944fc9027e702f2e00f744d8cc48e5019c9b"
      ]
    },
    "src/lib/libk/cxx/bits/type_traits.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3f26d3634130f8ad4610b010766fcd9a03a7f4e3267de66f8f443e573179661f",
      "kind": "file",
      "non_ascii_lines": [
        "d09019497c240e26b8947bb33710944fc9027e702f2e00f744d8cc48e5019c9b"
      ]
    },
    "src/lib/libk/cxx/conditionals": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b9df557a01c283f36c164a286ce06a2dfd3c8362e4298ad3d912bc2becaac11",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/cxx_int": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "29b5659450f5e567eba784b23d3f254cf3469160725e40178f01f13ee413401a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/defensive": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "85de928d535199d5baa0180fd4bd144eeb56d1e4f8dfef0feb67e5c2b21aa4d6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/dlist": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "04bc593097e668f66f492dd7e41f2e077a4ed00ce51972033bf7ae072be551cb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/dyn_cast": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5ccc48c8efdf570106b0bcdbd35ba22f00c44dabc0f1b4ed63028d1ce5ec721c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/function": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cdcd9ad7725fb26958495a09b39ef3b46b4e5720a7700b4006f09d4690f3f831",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/hlist": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9574dd11a050c7929e652b523c2992645fe2a067a28def176ace34d5827575d7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/pair": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c33e39687fb74459fd166b3cb0bc22bc597b9731263073c4f9dbf0bfdf1612c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/protected_ptr": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fb443a853bc502103b7d5397d6550b99f4c7bd8a3237f64711ae797b5667f4c5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/slist": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "abc266d9758480eb3610396957144d8151b91f1d6b287e52f24fe62df91ed480",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/splay_tree": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bf244c63bdd83578f27c0b16204f5ecd6d676c185d722830dde96f070a05438e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/static_vector": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8e9e8b5c3848f0eecbecb23cf1844246769d5cd67558cdedb248fc2d2b0ab273",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/std_alloc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aceff6240b2070be65d3dfb43694514c96f66d5e0e09a387e508af8a8ddc0e8b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/std_ops": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9a80f26381c7a7b89c026a1ee917612cfa8886da3261e36863d7b2bc679f9029",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/type_list": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ef3fbe4a135a4a8d092c6e33be96d815bff07178c6afb7db9e88226b02966d93",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/type_traits": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a867c83bf4c7e5ba9afac7df1642a1308791e18603ca998e070ae7f015a21671",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/cxx/union": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f6acd246f7d7dd0e98dabc9dda7f62819b5ae0e9b0958481193c9bd89c0a9085",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/fiasco_defs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "876fe5a62935b9852747399dbe4a70dad3e5d6efd8ae8d382fee712df35fc378",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/gcc_lib.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a907a27cba1bcb2db92c98ae44abec77f851abddfef7802830570c6d23815711",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/ia32/atomic-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d7ad4faacd37a39476f90793d31bf731de6c9cbbda39fe096cd0524cc9dd0bf7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/ia32/div32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e535d09955af422349680701f171a9afdbb93e251048ba7e785f360e8cbf644a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/ia32/mem-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d95b73c4535342c8dabca882c56f4112633705292e043b36aa26b1170c08c0d8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/ia32/mod32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0fdc22908aa8345e3722b540fb5de011aa0d837b7fcea56476c7d3633ca4717a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/ia32/processor-ia32.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8e7c1be25c8fd49f92edeba3a77db5474201d7f47002d9d01703c119fa638648",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/infinite_loop.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "473c99385fd18bbbe8505c247e809635bc7814e1a6a03ade807d0d757caeb950",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/lock_guard.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f47f8f2f3369c900bf2a15688ff4fd6bd80ed20a67bbdac82c848ed8ed9fc7a4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/mem.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "97021431e0b16a7617bbe4a83009d2dfaff542055a2001bc9e7b2039a257ec7c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/mem_region.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b62759a8ed85b2b6b27940c1688e13863c012f876bf8f630eee5a70efd3192a6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/minmax.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "071e3a87d6da043e0529260e046a4decbbe42165c1c32ccd67866890f68de06a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/mips/asm_mips.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "961e59a6e516bfb7a3f0f602ae8b989a7103d9398d18fbea9bf08f73944e4bdc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/mips/atomic-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aecf65989683cded24be4ac7a2203b58d23973869ad192ef84e9d2434efdc109",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/mips/div32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c3edd0dc5233ca1ab83cc112359df5f8b31215c4c2455f231cf52d4e2acd7f47",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/mips/mem-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cc5ed3ede793e5ae731421a9923e954468c69c3b53d358a9aa520f4334993c24",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/mips/processor-mips.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5a86cfe1d06d50d52ee48b21fbfabcc98d1d8924ad974556b434a9f7de20d1a5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/new": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0d9d52731a5bba6cc4e3b16f25f3ad2bee3ae8e928dd82a926c348f19bb38f96",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/options.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "36fb920b63f57855c5b33d8fe4f931c1197900cbe869cfca03b317954cfb2d5a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/poll_timeout_counter.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "85620a25db710727ef9d58953f392cb70838e0efb31aa9f4b101b82f78f45234",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/processor.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "926d2490f848a74c87a69752e3a6268337494126fd7219b4cf1822e962e941dd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/adddi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "3b9daf14de7e4a28617ad2e1af4903d13b78be1169b3cc4798d4ca8e1d11a41c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/anddi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "bd50c4369dd25df71b4d40375505e9beb8287360cd07c73c68b6b6113e64ea76",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/ashldi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "5ec835455dc2481f16d624d8e6f699f3889ef8bab84ef5a75647589b75edb84d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/ashrdi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "200a8aea3baa8c544971ec603fe1beed7f11fb714ddaae8ffb2a506777725037",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/cmpdi2.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "f3fb62f0913e2a2dd0a347b1ed5c086185517735fad3efd078234f0a028100a8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/divdi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "a147eeda6e6251303f417eb206881d88d99fbe39c98b916913ebe4ea2a26bb17",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/iordi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "b0c888b7f5619a474b45c1f29b2286188b427be4204c0262c512c4acffeb024a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/lshldi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "423fb9cab6aa9e00051d3cdc386ab48eb80c8f0c7306863959faf17e907cd09a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/lshrdi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "300f2f81b6c181318044ebc9a02d67a91cd649f0deb20d115fe7e1bb9c3aa3f8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/moddi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "ca52deb702b903816fa649abb4c40fd90aee565ce35bb2a3e85308736082bbe8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/muldi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "c923b38ae497ce6da1f11a8543d19aafe159a29244d98a3250deb54fe4cbdfed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/negdi2.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "c5e74a2d3bb3d48d9385c547596e081f570071e45d2076889bfa4e32b973e047",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/notdi2.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "a38bb32377aafde2eb1147537bbbc6a15788c56a76b8c49ca500599b2f74b94e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/qdivrem.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "c11373413b8fdb492199ab9e502742a3cd73bfdd15877949d4ff2c7fea29d123",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/quad.h": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "02e2cb1c95aebf3aa3789427dcd907899a32c000159cba1df9ced46e489db225",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/subdi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "6ea1df180cba2e1e052c7bb8f2740445280a09e20abfdd1f7955a4154f283ba3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/ucmpdi2.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "b3649ac611242feb44a943f138a26588c653b3afb2542eec71d6c76341b6999a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/udivdi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "4c65ac42a5442fa2d479ad9ef1821fb23ef63522a0970ad9763042346849003b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/umoddi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "53dec0f8efe9763ba9c5ad0c6c93f0607b14e77fd1670835b9dcb90db61ccd3a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/quad/xordi3.c": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.spdx package declaration for src/lib/libk/quad",
      "reviewed": true,
      "sha256": "9cb714cd3f6ab8fb6e67a1091c84d7aec67a143bd5633a3b47ea56287af93660",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/riscv/atomic-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bffa70b9c2cda7c2ed90ae2d4cc44f669b7813328c4f93d36054ec21ec41054e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/riscv/div32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "905d80ca9112f8f899b2173ce12b7b9888b172ab8b3660606f9fb0fd4917a6b0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/riscv/mem-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e59b5f8fb271017fed8b5aa8770ebd286d7eea09d023343ca5775538a6b0401f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/riscv/processor-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "389e9fff707c838cb3395ca19e3d936f9a72113a5c5ec0a93bba1ce3040fcb90",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/riscv/scaler_shift-riscv.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ddd77eeccebe3e6c9f70ac2188ac612eef66e1231f52d9584c91c7a6d469940a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/scaler_shift.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b8ed9118d23e3b1b1c7c6f3bee698b738b072313bbcf08bac9a13f1ca25fff66",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/slab_cache.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "32af9d336f341cbcaf240df95ea1cfd4e223cc4a5a1c5a539dcd7fdc2f0e9380",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/std_macros.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "edfaa75a816cdbd1e79ebc2f3aa9dfe8befcc93391443dfce8ccb992aa530289",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/string_buffer.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1255958425a03c10b6897c608712eb8763615a6d5971b6887ca35c230e95beed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/template_math.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1be66f262b0910b7cd4f93d423884a6aab662cab147b810b18107dfecc843e5f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/libk/unique_ptr.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8ac330a8e753a1af2c31cf6a395805ad3c4d95720907c674fbe6626ebf2f7df",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5db5de731ce1f11f4628233fd2dbb8d0d982aaa9c472dccb21b280fdc4cf3d51",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/device.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d81ee82def29115d92aea2b636eca114f5382b1525f2d87628efc6fce48a3067",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/io_regblock.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1d77476667ed9761b520a0b7d8076851bebd57ee7477d91a430c54fb851b8348",
      "kind": "file",
      "non_ascii_lines": [
        "50fa768b8e679a098b30afaef2c3731308982ce65874f2a9ec4641102115ecac"
      ]
    },
    "src/lib/uart/io_regblock_port.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5216181a4a7016a7e76eef84a594f0fa7d74d7f8c1b404933bfea039e27a8d0f",
      "kind": "file",
      "non_ascii_lines": [
        "50fa768b8e679a098b30afaef2c3731308982ce65874f2a9ec4641102115ecac"
      ]
    },
    "src/lib/uart/of1275.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "027ad6ab5fa52e3f146c696c2a005cfb97e37a8fc46b54275ece54f700309a2a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_16550.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bf1e8c134a769e8402d97df835ba25134460ad5380c5ad4c5e57b8fa4cbbfad7",
      "kind": "file",
      "non_ascii_lines": [
        "46104e6a96da380a17a0d0265505baf63458bbeceb0a4a862100e4c0122ef862"
      ]
    },
    "src/lib/uart/uart_16550.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4b657f8a6fda9f7741670d4d36563fdaf979b485a7531b64eeae1c6f01f962b1",
      "kind": "file",
      "non_ascii_lines": [
        "8e2f99f2cdf8382937fcfb622bcaad9063f2ecf559a5e786c0324896b36ba58a"
      ]
    },
    "src/lib/uart/uart_16550_dw.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "52a862c273d757ed6d83bf421619f4dbc6c89dd199f756304b0cc828df8cfd5d",
      "kind": "file",
      "non_ascii_lines": [
        "b658f1bfc86b1eabef8368219631bc98bc001bbdec39fa9de9781da71cf785f9"
      ]
    },
    "src/lib/uart/uart_16550_dw.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8c15d4673d75d1a2bc81535a9cbaa3b9d4c27d67c37148645750251e11066a8",
      "kind": "file",
      "non_ascii_lines": [
        "b658f1bfc86b1eabef8368219631bc98bc001bbdec39fa9de9781da71cf785f9"
      ]
    },
    "src/lib/uart/uart_apb.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e486391638558b220384ac5098a54871a9b231940d3eb99effb7761ae712b921",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_apb.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f0f6c2c1b5421744e3ba5261ef3b278ad5ee6a61a4ba46b7aab78b4a4abcc5e9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_base.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f9556f585e9c7d8d60c97fb4dbb2d3f8e3eb0e96f2d822b4786b44d1a4da6700",
      "kind": "file",
      "non_ascii_lines": [
        "85e3af0cc18338a2ecfc7614f5e335f654e8348e53ee713bb8716398f3632db2"
      ]
    },
    "src/lib/uart/uart_bcm2835.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fa286a95532553fcbdc20d2c5d7d55c290436ae6667cfda3e43657fb993ee026",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_bcm2835.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "567caeb0b984e271e3ab8d0fe20b368012b2c0b72bd1ba165fb4594ce480f6a9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_cadence.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9930aec45c43833b8962c0c52802666851bdde805b1657571c5c1ff9c6052ee9",
      "kind": "file",
      "non_ascii_lines": [
        "75da83c65cb768688a25a5d31b36b8d2fd569a1d3d99d0cd1f4c8319802bb225"
      ]
    },
    "src/lib/uart/uart_cadence.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6bb6f7f42ce8cc214e0cb52dde3ee9bd1d0f6f06dec1ef5628ea107d008660cb",
      "kind": "file",
      "non_ascii_lines": [
        "75da83c65cb768688a25a5d31b36b8d2fd569a1d3d99d0cd1f4c8319802bb225"
      ]
    },
    "src/lib/uart/uart_dcc-v6.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1bc27102a66f43e1b36480b10b4bfc65e111b93205d9edc2aeba73a97ca1a7e6",
      "kind": "file",
      "non_ascii_lines": [
        "8d001a68a6ff73f56278c65f385facdd24dc5b047cdb4372868782e7a45204d7"
      ]
    },
    "src/lib/uart/uart_dcc-v6.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a009f9da33fe36ff164cf47387a05537c89583287f6f2ee7a9eda11e0290fa9f",
      "kind": "file",
      "non_ascii_lines": [
        "8d001a68a6ff73f56278c65f385facdd24dc5b047cdb4372868782e7a45204d7"
      ]
    },
    "src/lib/uart/uart_dm.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6f2882c059da239475d51157e2e691262c0b7a2d26dee7f10691ad08dbaf04c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_dm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0dbca85533ae6b5eb0951875de11b12dabe918df5e7069e852a1ca0aa20bd1a8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_dummy.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cd68010bbb5b17e12272afc31a80817794c93d889005028d25ec6de6c637a5b1",
      "kind": "file",
      "non_ascii_lines": [
        "474d4fbcc5ebcea9af5eef9c7c85a9016a5946dab43fb50dbedeb099d02e1d5e"
      ]
    },
    "src/lib/uart/uart_geni.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9e63fec5c2b689ed7930e1f1ef00a39f900aa3fa0d867f9ab1cd60eb24615727",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_geni.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e30a162ba7133dc38a66f8c77256cd24e900d28e47b59d6e4bab9a55418b885b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_imx.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "db77b20248469cf502ef92ff1ad7d3c74fca7915acfa8df7150f73d1faa94e2b",
      "kind": "file",
      "non_ascii_lines": [
        "724f6c38f58572d7f6f3f6d6043a39abaadf69c4420ec61fc849c260b6169b14"
      ]
    },
    "src/lib/uart/uart_imx.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "66286837f6b8f22eb9ec0021c26fe18197d2e064bd5c91970e173fd5fcf757b6",
      "kind": "file",
      "non_ascii_lines": [
        "46104e6a96da380a17a0d0265505baf63458bbeceb0a4a862100e4c0122ef862"
      ]
    },
    "src/lib/uart/uart_leon3.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3997ab144db535ac04e91d6d1112b2c22a977aa0b95686a71463ed00d20f3765",
      "kind": "file",
      "non_ascii_lines": [
        "3d1d441d5b12c35a91a6cddeae82e7b6739179d585cdb3f03b49275ba26c1c81",
        "bc35435f0097c2ced67773c28f6119b4bac84c75cdea203fa9ba4a499fc94921"
      ]
    },
    "src/lib/uart/uart_leon3.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "821c4df7256fe506ead65694aaea98d16c6a9e947a9937a29e2f70729c4cc31f",
      "kind": "file",
      "non_ascii_lines": [
        "3d1d441d5b12c35a91a6cddeae82e7b6739179d585cdb3f03b49275ba26c1c81",
        "bc35435f0097c2ced67773c28f6119b4bac84c75cdea203fa9ba4a499fc94921"
      ]
    },
    "src/lib/uart/uart_linflex.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "261fc523207a20ed88cb06d070f5d89f5883f83e01e26aaa0d43da456c993fd0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_linflex.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e214d09791f50ae590fb64af8acb53e2dbc635f5a0952f7d74e646b86744ddc5",
      "kind": "file",
      "non_ascii_lines": [
        "ee3fdc18b4095a4bfb64ea39933c6881767718cd7ee2ca02b9ce9922f304fcae"
      ]
    },
    "src/lib/uart/uart_lpuart.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ddd1f25fd330e166a95b76eb4d4a213b0bbcc194ea44716dfd5fb43afd343f76",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_lpuart.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3769115c36ae4e45c6bb0e9859cde021c7e0e12152baae8a487d5dc1f54f9a90",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_mpc52xx.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dd6cad976338b81939a8da9f4833de961c9c67019f3b4e717a8a274b92099ee4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_mpc52xx.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c5c6f4f54b093e52e5f53a8ec5a238a94b58521ccff8f740df198d4d453006d5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_mvebu.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d5f266caf07e05b589055edc1f286986dc9e80d93bedb694df869def034cb27c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_mvebu.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a35bbc78d8ed9302d99da3b3ed66739a1e8c7d4f4f55ba4b66fdd39a2201472c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_of.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6c63b573145f83493218cca8fb0f9589b3925f9e062218e3df056df2a141d248",
      "kind": "file",
      "non_ascii_lines": [
        "85e3af0cc18338a2ecfc7614f5e335f654e8348e53ee713bb8716398f3632db2"
      ]
    },
    "src/lib/uart/uart_of.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8d4b1f4216b83b3f050f0a3cb31fb788d1ab3fe253504a1fdeb85a3bd0dc563d",
      "kind": "file",
      "non_ascii_lines": [
        "8d001a68a6ff73f56278c65f385facdd24dc5b047cdb4372868782e7a45204d7"
      ]
    },
    "src/lib/uart/uart_omap35x.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d4d7a9c3d36450ad01855df51cd7c49459eb8b2ac2208f2929b78feedf3056b6",
      "kind": "file",
      "non_ascii_lines": [
        "85e3af0cc18338a2ecfc7614f5e335f654e8348e53ee713bb8716398f3632db2"
      ]
    },
    "src/lib/uart/uart_omap35x.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ba7823e6ffb68a624baf9944c9ad637abd4fa0396f6c71c73f23ed6a03c1ef73",
      "kind": "file",
      "non_ascii_lines": [
        "8d001a68a6ff73f56278c65f385facdd24dc5b047cdb4372868782e7a45204d7"
      ]
    },
    "src/lib/uart/uart_pl011.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "91cb485d3c5ff075e705db8b9b43274ffa48f88de883cd7a079054e6794f0bde",
      "kind": "file",
      "non_ascii_lines": [
        "85e3af0cc18338a2ecfc7614f5e335f654e8348e53ee713bb8716398f3632db2"
      ]
    },
    "src/lib/uart/uart_pl011.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d72526ea634e22d145fd1a2c2bfbfff28bae96d5d592087987b6db2f5d771194",
      "kind": "file",
      "non_ascii_lines": [
        "8d001a68a6ff73f56278c65f385facdd24dc5b047cdb4372868782e7a45204d7"
      ]
    },
    "src/lib/uart/uart_s3c2410.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ba57cc272b7fe3f5ff898c599e055f7dcd1d4ae661abf42a8643a282f5a9eec5",
      "kind": "file",
      "non_ascii_lines": [
        "8d001a68a6ff73f56278c65f385facdd24dc5b047cdb4372868782e7a45204d7"
      ]
    },
    "src/lib/uart/uart_s3c2410.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "103d8c677db6d36f056ea7c213274153108987a0ad260d4b435959124c377d87",
      "kind": "file",
      "non_ascii_lines": [
        "85e3af0cc18338a2ecfc7614f5e335f654e8348e53ee713bb8716398f3632db2"
      ]
    },
    "src/lib/uart/uart_sa1000.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aa3afad8b3c777ed7b7104a072073b0394e437cf480956d85c1996a9c2ed7091",
      "kind": "file",
      "non_ascii_lines": [
        "46104e6a96da380a17a0d0265505baf63458bbeceb0a4a862100e4c0122ef862"
      ]
    },
    "src/lib/uart/uart_sa1000.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "37310ef77883edafa2043e96a1f55af1db343ade5b0dd46b0f6d0ab703ce7693",
      "kind": "file",
      "non_ascii_lines": [
        "9ad544e1908fe7145ae76060e805c94adfbbfa29e7c163a1540addb85d3443f8"
      ]
    },
    "src/lib/uart/uart_sbi.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "56951f34c4a78791784ea572feb8f47893614aa74999ab36c4a41d952abbfe08",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_sbi.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1ee948aa47219100870e5a1774701213a84dbf529d7cbb478a194edc2c494789",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_sh.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "80f9b1bf35afe2e072000173a0949587550524bbed556abf7aff1eb42e576a86",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_sh.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b5f0744b2dc1cf27e5fa509ce24a67525ba598a193241b5e69883a12aa62ca0f",
      "kind": "file",
      "non_ascii_lines": [
        "0f1e72f11b4ad73062085bfcdcbfc410a0803acc885f466e0c9593b2b7cf38a5"
      ]
    },
    "src/lib/uart/uart_sifive.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ab31933e173f20081290001248bd1a6072d6d182051966aacef954fea7710223",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_sifive.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d81cea502f44b152ece7201ea3a3cc0517e9d4cc0dd151a6810776d7f2f2dd07",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_stm32.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "115b1f49b59e3fad8bb14bae2542098dd7b486b0b74629cada353125524f4fb4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_stm32.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7b087f1ded73f9ea7e3b3e707882609e2a1e67210514d99fa7b1c0e18f30e5c1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_tegra-tcu.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "351139dbaf86c8bff9d0497cf8b5f6a06c58044817a6bbb02859e594ddebf4f2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/lib/uart/uart_tegra-tcu.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2e33807c5782030ffe2d0b84b9fbde19eb9320c1d47f6baee1fddb630155760e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4eb11ccd22cb9e1ff5c3010f8083505f561072d5d723ef8528bd3b7d190691d8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/Makefile.builddir.templ": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1caab3030c739e935afcfe6e46e274b502cd34f191dc867765c44d1333953f7e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.amd64-1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6d577c4d5e4d7dfa7d2de2a1f546175fb99dfd127529793eafa500a6229acc16",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.amd64-2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0f31b16ee8d2a060bed1ea495901a77ddd7fdd50cf2d838b0cd0c6c5571eabab",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.amd64-3-noinl": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "241f6d7347b532dec97abc4ce206ef45e7a4a12cab3757d832940b89cc498fd8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.amd64-dfl": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b59a52c1515fdb22093fafc39bd436be6b72892c5e398a841432c93e7447831",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.amd64-mp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0f31b16ee8d2a060bed1ea495901a77ddd7fdd50cf2d838b0cd0c6c5571eabab",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-a15-mp-hyp-vexpress-1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7cfb312a51d58e59b7553df0b26e6bca0783bf131de78c1ca2204f58d422b6c4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-a9-mp-1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a826788b9f54fa3ba13b92a581061f7eb8fa188fb0159919a6d5069f4e0fa370",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-a9-mp-2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b364ab1b32746ca619aa7f80e1c16086efbad8dfc4f3b3ce4b433cb489b842e1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-a9-mp-vexpress-1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f5724c2b5c04496687bbe83ca994816ce2eac9e1377855bfda5ff2aea44ab94f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-a9-mp-vexpress-2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "afdd6d4529247c08c2f1bfa36e74d508fbf93303f8ca415a1c0c705b88b6d4c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-armada38x": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4d87089cd49b155cb9aaad6c3f768e3d71ff570692a6f437b8ff8cff431c3f0e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-exynos": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c9e9145985022d8188b9bfa272b51604b6ad4253f448dbb393ae5c9649581962",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-fvp_base_r": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c4c2011989eb7193caad2272e04aa7edc67065fea6d6cfb7c55c4da75b93c9a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-gen-pl1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "615b7671e170d82b6238ec57a332c0182277c18f7860e07fc289bc6045593f19",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-gen-pl2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f53b1a8b31c13790ce3191d7d6e57c1a25f10acc41829da61759d861d604c496",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-imx21": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "62b5ae7e612f7986585822dcf8be6ea2a5097f3bd4e31f1622c165927878b7cf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-imx28": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fd198a6d4bc4ed7a67aa0b98645461fceaf4b67919dc8fda53f3d6bb4ac64cf9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-imx35": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6f756b88f51bb2c7b3c435234f4593e4f44b9208db83831ede869a690a58d89b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-imx51": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cc68b5e79eefe47ed5a3c5aab44aa8c9de523dc588e024a748f0864196639589",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-imx6": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cde460af36fb89b61890eb3186eca0f596bc4c04aa269d661b6edc73acfcc1a9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-imx6ul": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f927f44662ab03b8a05e49653c3dea10e6c4e9b1a94160369ac83efa4fa14845",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-imx7": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f9fe3c40b086a87fb4b5d537a8512a0f06040c88214f06a0f19f1a3e5523d233",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-int-1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9116bd8a06b5c735300f1628d2794bd165fbef26ebbb7e342e5e2b07c327ca14",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-int-2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "474f32c2916fb652bf6b18dd3713019bd04aa944e9e013f0f634027f4c7071ae",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-kirkwood": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f2cdff7c4eb993a563af6fba8236b36e0dacc7d6ffe2c98a50e9a2c2efafd27",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-layerscape": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4b65ed4736e3dd9e0959db2820692a87dcc114b88294e07240162ed637403256",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-omap3evm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "055b1967fb1e905e434f593ed06e50449eeda184f00c9c55bb38f5a0fc960ebf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-omap4-panda": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fdd9302418848e6a9a0bfb2151b9628b576840d6666ebc18ad72ac083935b882",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-omap5": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8598f94f20a9052d9484e907ac765d5e2409dbc79761f9939db78cc181320113",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-omap5-hyp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b262976abae4b778034108c832790302ba3b13eba960ed3459562eae20e64cca",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-pxa": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aeb34386f21c889085f02b45ce7762ac3878bf05557a8cc3f4ee58aeed260e5e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-qcom-msm8226": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a8674437822a9b0b909946f3b2b1d17a5ced277f64364cbc6d6ed23cf361a60f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-qcom-msm8909": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "24a5e709f096e763d6576503395e52cc2bb71d6972c5be00462ffcb018fb7990",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-qcom-msm8909-iommu": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ca92a9edd5eb9f1b8c35453301b080682533f951a8e6cce536261c5f5124f997",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-qcom-msm8974": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3d953064fbf7eb1b46609b79532153fe8cb40333c3b28b09da50de2eb79f1b66",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-rpi3": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ebb0a45259c40c2fb4156aa62fd825a5b041af79ff1a19087ffe73ad63ecb7f0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-rpi4": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0199a69e28f16ea9416bc6a00df0296a017c9cfd80e7c5e1448837bfabdb83af",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-rpiz": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "af093a51e4249f564ea38341c7b5177c7f96cbe339d2bab8e6b832c7fdda35a4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-rv-1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b90f8e2ccd3be13727ad9d27b822717eb071113efa0ff6bbfc2c1f731682631e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-rv-2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bb3303a2194b73e74f02c70a64e881cd48a78975962b689b3dbd67ecea33899c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-rv-3": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bd3fc1f892de8e7452c53f0f02ebd51a0fb0e8ed7655d4a6313228dfa8c43026",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-rv-4-noinl": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "12b885bd0e5a8f390c8d0eb794675ef57e7e22aae687fdb72a3fcccc6c505fb5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-s3c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c2c4ec9f2f7c77b6879d10a721e622d083405e6e5e1eeed73b699d6bbb72d92f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-sunxi": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d9edfe2476823d19e7199407d32c26ce666a1e58dbf3d8c801675f7945ff4382",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-t2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c86055e7b898150cca45b94f3cff5334d2d7bb7ca5d15cdb54e42ba2a97c656b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-v6": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bb3303a2194b73e74f02c70a64e881cd48a78975962b689b3dbd67ecea33899c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-v6-mp-eb": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "61beacc61cf89dc79ab89e4fedba3c6988a337c4810779a9044502e87d5e8e52",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-v6-mp-pb": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "de4b84bd9f9d12c1ffbb662e2623df5d33d2cdc35ae4196f2160c79621d83376",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-v7": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dc1c5869c129a25d9dd2579d29f85a5dba303c513ae3144b605ca036decb8b7c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-virt-pl1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9c7f58a7ab75e1d8d1ee5ebb8e44bd97d470b187ad1178e4112ee2167ea5fa3f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-virt-pl2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "53e7f5b9ce351858a5887057ef622385bf0e0d5b93318d0d0cad56c64cf049e5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm-zynq": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ea0accb223d85b5b5cf90475ce600aae256d8ebcde5ff778ea6fdeadeeaac77c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-fvp_base_r": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4336cff1bb92356c6e07a0cfbb6693e6dcb249e17a64d198de92b853564ad6ee",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-gen-el1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "04546ce43ad130f55db30fb6d60a7ab4e44fc7ee3c628a133c485444f8b7094c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-gen-el2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ddd217aff6b32c963441c13d9d43c23c2a04c130a40a2e0e1a28f5d4d06c8da1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-imx8qm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "361770fdbc7af2750bc8e42df62e7a0e67b2a34a908670ea192cb265634ed3dc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-mp-hyp-vexpress": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c82fcf024a3a8c99608aaa851eb0a46a298abb7e33844f6f9c4c97096cb5fa77",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-mp-vexpress": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bd7edd1307c0ff28460121279b6d98682f0c01cee9f63fa506318cf92269c149",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-qcom-msm8916": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d93b4ab710ca46a158bd83f848386340908b0d949148818d5c0b7d0f06a6b850",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-qcom-msm8916-iommu": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ae29e5f1114e162a9540d818958475437cfed01a5aa70e5264f22ac4f545e118",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-qcom-msm8939": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aca268aeb29e697ea1554d140dad1de12e4389d1f24d14499f4279f7a2a2e2ad",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-qcom-msm8939-iommu": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2bc8f8fb54a88f21dcc9ed5d8c65755e8dd25716c520b01cc1140f5e107f6d4b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-qcom-sm8150": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "80e25576ae02022d08caa09258da2bb1f0646d81826e8dd83fb68024a98b842b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-qcom-sm8150-iommu": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dce254c81ed55f0dec580eb28bafab23bac63c2ad611d54aab1939ffc60cfca4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-rcar3": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f599cac396a387decaab3dcb4adf86d56e4d48dcf3dac4f790421552ef987047",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-rpi3": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b03db4623222870f7bf60e6acf18e73be941f2eccb3199e91daec16210a61f4d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-rpi4": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8b0a9e2ba2389e96910e979ae41254e8a3cc596e5ee0597b67fae01070c9ba05",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-s32g": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "11eeac8086fbb7f2471068122a31b1f37f95c657a25a854574169eb607576fc2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-vexpress": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bd7edd1307c0ff28460121279b6d98682f0c01cee9f63fa506318cf92269c149",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-virt-el1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e156b27fcf631d85e23212686516fb22d154f5bf58503b8ed1227322eda80490",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-virt-el2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "18564a6d06c313865b4b0f5d4f983575a211b281f6f354d79726f35242293c33",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.arm64-zynqmp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "faad2cb3984d0b60d2c056767e572ed8c1d4124893fce03bc616618b5c5fd508",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.ia32-1": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e3bcebac4ac5e043cf7e5afb30307d9e20e4cb63f15b68d05602fff22bae2419",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.ia32-2": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1192504dbfba47a21138bd06ca23e771021e0bf77f177721ecf100cd1e0b733e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.ia32-3-noinl": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "387a95ad44914d305b82726aa941f8a66351a7d717d8b1f38b6ae3056cfa8c03",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.ia32-big": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aca462060a81919d1ebb15ccca4e8fa1ad95f744beb80ad5bad1f399c8ed0e35",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.ia32-mp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ba65aa9353f8728b6d8d184c18aa435c443bd4f6098073779639fca5bde08510",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.ia32-ndebug": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d622e7ddd7f1467da43a483879d05d6f443fd113047f5ff30c62c8ff442ff394",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.mips-baikal-mp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "38368fab5a1598ec2e312d851d8ff5502ff254a003dace416460938943f6a56f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.mips-boston-64r6-mp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "704411a67ae875637c81ec7a72acff695884aafe0f5d9e960d23218cc10dcc53",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.mips-ci20": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c37fffafeb041974479a89ccd39685607c8ff71ad87f73077d65c82bb42fc21c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.mips-malta-32r6-mp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e5b8120514c9cb8f8c079888c52caa1784fc3cc6982291154a8e5a6b656bc35e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.mips-malta-64r2-mp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "74aa51ae88ad7a2e0c5f43161ed12f5388bdd3a8440310376627a97b238db7d9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.mips-malta-64r6-mp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7bad6290a4d423f05e4b406a4066a4661be7dccfa25e276ffeb3d93fb517d6f3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.mips-malta-mp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a490096f70ad4160f3e0ff5adccf8c586245db4499c36f45052eca9ff074b7a5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.mips-sead3": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dcc45e8f2ccb3f1068421d077ec9b6b2fce4f4f159a9460ee948934568aa8d10",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.riscv32-virt": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f00e8d2b95b76e1ece805d9dd1ca1f773cb0b05d75bed4cae824068d6e4cccef",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/templates/globalconfig.out.riscv64-virt": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "be6e160541b7b8e0bcccff6a01712a16e0857f16810038fe28a8c22c9f1b7d48",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/coderules/Modules.crtest": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "963cf2244cae5722049972408599a79591e3eb0cdd8bb0b86fc23781a6105b75",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/Modules.utest": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "81f82b882eabdafda5d00202a3f8d93a2a4dbf5647d238fd3103e04ccc4a86ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/framework/README.md": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1350b5eeaa2ed40ed2c1df8fa66e3eeab43a4865e32df115042e17b53cdc16be",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/framework/utest_fw.cpp": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "973e637923de39c69c516e462ff4cf2b6ace96baf11ac705c0d0879cb38ea0bf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/Modules.utest": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d96d6d5a2ee383fdd71c8973ce44244cefef53c3d44ac055bc826d89d9fa93ab",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/common_test_mapdb.cpp": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "693f5360d37fd68af8e50f8e08c9c4bde441038b929bd5d24e99f3e9d348e2e9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/config_map_util": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9eb2087fb14fa8bac036f8b00d3529910efa35c495718297070c200d08c6d8ef",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/config_mapdb": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d87e0fb1244913d515eb252592a72be8e4dfa7707c15bde61a9037c3809e7c1b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_map_util": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b9832a1e170fa02c395fe84d053e9be71ed7de524d1d1abff8f8e40ae0e9bb8d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_map_util-arm-nolpae": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d086f4d219d718b801a18e26989e64faa35846d60653551d0974e7b99a5078d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_map_util-ia32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c91d7be18bde856e01b1eb3d87f42871105d49fff93428f3779c03b9879ac5b4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_map_util-mips-32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3d0e44685a74f7eaf79742b8770727716ccdaecf434139d08f980be38bbd4efd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_map_util-mips-64": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "19b9cb41edcdac09dad860747357bef7c3cba1c676b1d087192c889354ff486f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_map_util-riscv-32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c91d7be18bde856e01b1eb3d87f42871105d49fff93428f3779c03b9879ac5b4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_map_util-riscv-64": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b9832a1e170fa02c395fe84d053e9be71ed7de524d1d1abff8f8e40ae0e9bb8d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_mapdb": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c75883f4bfa64e9a4cd1f5d57dcacfae24415aee74a98ac8655da189a3eaf6e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_mapdb-arm-nolpae": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c75883f4bfa64e9a4cd1f5d57dcacfae24415aee74a98ac8655da189a3eaf6e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_mapdb-ia32": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c75883f4bfa64e9a4cd1f5d57dcacfae24415aee74a98ac8655da189a3eaf6e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_mapdb-mips": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e708df91b8fff6ff1bee26fd4b5b1c372fd994ad994957954926b3d5fd2319f4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/expected_mapdb-riscv": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1c75883f4bfa64e9a4cd1f5d57dcacfae24415aee74a98ac8655da189a3eaf6e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/test_map_util.cpp": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "4e372d3c469aeb738dd0da6b31d2d3295e628c9af6d0dd73328fabf346d7f9f2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/test/utest/mapdb/test_mapdb.cpp": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "e9a44c8d494e1141db1262df0a52d1f32979113cc4461f66ed847402ddf39b7c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/amd64/types-arch.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "956cba20e7f7750f462ab0b0a82271d3aaec21793c64e733672413c7032b92f2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/arm/32/types-arch.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "58e19e70acd5329551948167926e2d7d8d873f3beff25eb21869a3d517c87819",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/arm/64/types-arch.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5e52da2fa6dfacbd96d2c804470cc17bd975d37e64375ce1e83d2d3e7ab19d9e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/arm/asm.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2e93dff1db0aec5cc6dcdc79bd6a9b54debc4768a6f279095c19f49f4d1a1594",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/ia32/types-arch.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "41302eb863125cd54c04e02cbaf43cc8d63a09a898348ffb927d008dfd3d16ae",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/mips/32/types-arch.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2aea35f988b301e5b65e8994a177a8036240c2dbb039d016bc535d0215d0da67",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/mips/64/types-arch.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "22688fdb74bda687a07291914b6a3b4ff74a4e461a4f42a5d7f6cf81d0316fae",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/mips/asm_regs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2c517c0e7f39359f8b0e9c105ebb3c0e45305e6cd17d6ceca618b4b9b811ecf7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/riscv/32/types-arch.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "34371d92c945c9a970f4a339977f2301eba797daa722b9187a1c4cb125c8c4cb",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/riscv/64/types-arch.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "827e5247de40df37143291a86b3a63536b8d2cf07b92c4a3adffe28b3affc02c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/riscv/asm_riscv.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a251cb71e3a376a742867964a6acd05385e171d7cc5f6dd9077f7625f0eccdbc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "src/types/types.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0d079f07d274b9baa0e719bf6466993545f7b9a72f78c49ed95de922fc1fb1d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/backtrace": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "66a1ddc819a80191d65a12c257de135d04b2de756891aabbd234caa090c222f4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/check_diagnostics": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2529909d08697aa6d6673cc4826e6cbeeef955c8e2e0625d412780cb1a6234b6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/checkinitcalls": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c928c4f59b820cb80c7fa6ef4719c2120beced83715d781fffa9afc6cd5283ba",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/circular": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "26542b0ea4bb694e64f433567badfe7117b728c4c925f9c2485c89a8f3ec0f5d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/config-tags": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "791f463b77a54e1862d294b32afb78a8d4f9b52558f0b746ee3533cda11324a1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/configstat": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "674e3a72100b7971598c20eb26af1a3e955a2fdf770c60dbff53115264b1f983",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/gdb/fiasco_gdb_util.py": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1b65dce4e5c566e5952ad49d7cad339a435cd1b8665b53e07562e823100c86ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/gdb/gen_ktrace_events.gdb": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d8e8c36ec77d77080e6c5f9577906441e12873404d7595465a978fb05e269599",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/gdb/interactive.gdb": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7d4594d3a973e4d5df0061cde06c91a64ed282aa7dd2fb7ebaa70148d91b8ddc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/gen_kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8d1cde5253ba072714454357627990af042345fbb209546e1849ae8e89154451",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/gendotdeps": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fd7af6458ffc749c9ef031817ead79524b30efbd04c1f0f823240b558a246b92",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/COPYING": {
      "license": "GPL-2.0-only WITH Linux-syscall-note",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "fb5a425bd3b3cd6071a3a9aff9909a859e7c1158d54d32e07658398cd67eb6a0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/Makefile": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "aaceaacfd59508468f9bed4cffaf6a82d7e9d3929827253b44857a41e17c0c30",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/README": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a80946576917ef74f4668292e94dc403e6d146a3613cc478fc804b3685610164",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Kbuild.include": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "1953e3cb531ea8d93dfd0de7779e89dd4243f550e070d99356887e0121a70de9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "b25f2c1fcd47dbe44203bdaf5917d9deaf87c8a018752805f8448283f5d9e414",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.build": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "f809b9faecae017150b3ac0b999176be0a25efc6725bda566bf20d8f9f7c9414",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.clang": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c385b73ad4c36348bf4a7cd8ddc0f6afb88e4804579f8d5f3f18de0f1fa2c8d7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.clean": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "385225abf868f3075f8f814ea242704adabae1125e28256fae3b019537696591",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.compiler": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "3de828ba8ace97964d3b6ceec8a98d570c6a1c5738d52344199a78add66e01be",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.headersinst": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "a763f07b49b50df48fd47440dd64868874774edba92914ea5fb4fae002564b37",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.host": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "d4219009850204dce60b27baf3b483c0bcdd7c5c999c0ebc6972f5580f3dbabc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.lib": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "2e7d55db33cc8db3d2909d9bac0dc6be08de7b859e7b7ebbd279b42f533068bc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.modinst": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "3063335b53928dbd6358c8c456f30791a98032322f4eb4c7c6c2802be0eb28b9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/Makefile.modpost": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "1816d5dc8cfa39f33cac7c17d28579b04453b979ebf863a334113be907e58b76",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/basic/.gitignore": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "1c490b095a8d8e1c2ddabefd8fb6d1a15ac2ac64d783beb7065cfc3bd87ea792",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/basic/Makefile": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "c246f266cacc723eba76ee78c6a091d864be7c0f9c80a0c8f63fb1033d675eb3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/basic/fixdep.c": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "512a85c24ca2cdd44d1d652e071abc6650cf4776e21979e0a08b421178f59590",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/config": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "a05f1a7669fd88820761bbeb1c3f321cc4c48e65624f9ae39572f58c264f1e85",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/include/array_size.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "90ea8c7000afb1f9ad8504dcc24c1ddcd3c08239787248b617fc632ed3577ce4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/include/hash.h": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "036b553056d9b4728a27658ecdd33e23cd5174bf07b8cbb79a4a91a66c7fda60",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/include/hashtable.h": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "3f3b31f8490d515f62c7a65b69145f39aeae4f3cf7963267f6d697ffd08aa377",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/include/list.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "962c98d2e9cb30f559e4e53a450bacf073cf16f7e250f09073c5a3a3fd4f4f69",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/include/list_types.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "36df90fe1e5b16bff75afbbe2b0018f21eaeca9fe67f95e054cf645f28071356",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/include/xalloc.h": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "c69a8c5116bd0aac41088990401ddcfaffc1b28fe7d649117b7452b8fb5af7fa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/.gitignore": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "cf7b2c8ac89b85b8a02a15d19aaaff2b63f87a6d78c8ff5ce9f0260fe439a7dd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/Makefile": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "d43aaa5e76a1eb4fb186f6dc0f48920183893979d809d234330258eefcb6442c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/conf.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "027d209d2fb12a4350bf629a05f876f065f9254ba788bcf61e68eed135401a0a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/confdata.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "75810864753b4994a17ecc119c4da918c43d29856b02c08d4b524ceae2c78ba7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/expr.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "e1db484d6011e0855ddad833a00ca90ac445e284e8a9cd4608114c51b2f622a2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/expr.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "cce11d519da373fca76f897d8b6a6d1baa61d84d9220dcd5b91e86549afc36aa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/gconf-cfg.sh": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "080339e0f10d0fed364ee6045f218b90fbed67fcd7c2fc53e2f88d2e29697192",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/gconf.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "fcc7fddd99d6f2fa0ae3433eb46606a8a2f8ef2aaadb4cf57605bdc6f3b385d0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/gconf.ui": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ccb10be947b636701f568a65b31bfa201ad9bb2e7f1cb28a589d77de719d5d48",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/back.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e2be85e0af5809a7cfe015a680f98451dc31de6ecd0b3fd6cc60dfd22590500c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/choice_no.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e0b6be03cc47d783d27bb125defe93f3522f95d0efddb6299ffbc929ddfc2437",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/choice_yes.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9cccf11b4e03a8702e8a7041db1d786b30303cb2ad911a6c80026e430344d2d5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/load.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b1b6bf1e8496b12b9cd5a7c858ddd6cf7bdebcdc6d15d259eabd05f4367fb4e2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/menu.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d496aa3fc55508f0b172fc4c34298a841644cff0fce455c226395a993352d90e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/menuback.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2652c9e13c9a8dda84bfe4db7cbbd9d9eeaf737ee8f49f4c34fd5ad9a8169c04",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/save.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "68041300cd11d014f1df18e103b7c6d78e43135f3138512a20398c3e8569bd60",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/single_view.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5df44f4470c2914551c8233af3239171786498e5ddb66b9bc1954520b9398540",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/split_view.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "55721f31549d4619b92cf7fad31da0b97a52f7e7b4f7e49b86d7f6a5eade1958",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/symbol_mod.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b36cecf481399141a0cfc30212ab18715046b161f888da2c829c2167a160d30c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/symbol_no.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dd9174afc8ffda59d3cde22bf0bab9e78e7de4ec82120f98c1fd74891687f21e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/symbol_yes.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "89586e0d9fbf704e9b6afab54c48d3b60411ac1688a485300d797387175b1da3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/icons/tree_view.xpm": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "286164c806cfb332f7204adeb5ee1f645163e0bc10495c0df60968145a3446a3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/internal.h": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "cadb1a49e558de332aef828b9f3e315d5e2f75c4da61e0321655c3b8ecaa29ff",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lexer.l": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "cc33fed7acb53e4a8d40afcb78e700a771fa302610d65fcc5199030497983673",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lkc.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "6babb2eba40c899b9060082ba96261737ba0f7c0e4aaedbf9f5ab7f4d743856c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lkc_proto.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "ef82913bfcd9e431929c1adcbe9b7777d1828191ae08c0ae236f71748ad7debf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lxdialog/BIG.FAT.WARNING": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "73ad660058cb21d83c3d9c12e40d5734dd6cb2b8369ce6200378e08ac11ea3f7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lxdialog/checklist.c": {
      "license": "GPL-2.0-or-later",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "13ee1a6d7dec21313cf9478f5ec8c2b98b1d585a50c9cd07de106ba1065becc7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lxdialog/dialog.h": {
      "license": "GPL-2.0-or-later",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "39813ccd980e42dc910b8070294d65ef38b76326ee229bcd2563d75028263337",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lxdialog/inputbox.c": {
      "license": "GPL-2.0-or-later",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "b5d32eec2b7067d44c943424d1da04caa722fe1b5e671bf663ab70f11e7cc9b4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lxdialog/menubox.c": {
      "license": "GPL-2.0-or-later",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "04d3f716175673de86327a3b525e898961112f0c6abd7cee0efd0f4ee8bf89b8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lxdialog/textbox.c": {
      "license": "GPL-2.0-or-later",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "9d74ba950894702fec79e9c4462ec9c82c2e7f1f10e0b3d5bf93ea4a8c414806",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lxdialog/util.c": {
      "license": "GPL-2.0-or-later",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "10ecdd901d3b59b35725163a972202f1f599920669e18201f6b9766b95db3188",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/lxdialog/yesno.c": {
      "license": "GPL-2.0-or-later",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "4da4dec3cc1ee87b839ce3612c57e47976a658b3144d8b087b1e2621d5991134",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/mconf-cfg.sh": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "3a05180e35f6e60174bde4d91986964571d920b18c75029e097811aa1baf61c1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/mconf.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "21aa06ac1dcc11c2662c4dfc8db753ae514ff940510acbad7e3b097ff2b51b02",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/menu.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "a2028cc88d847d91ea10676eb1bce9d65d16aab44e87be65f09c678eada35aae",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/mnconf-common.c": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "0681901f2ccf1188d624407e0321952bff15989f34b6a583ba2fdee6128989a5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/mnconf-common.h": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "8f24b6108b76594bfb50079623885e1e2ab12183fc182a28f6de4c6a8c861d06",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/nconf-cfg.sh": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "e0f4b29605e09cee76cbf50f0742a9b80f4d6d15c5dd0c74470f8a507b6b1377",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/nconf.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "5909d0b33302c484e6347f521fd940370b15b9f85659749b855c7a9b551f4bb1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/nconf.gui.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "45e71b4f9187a3f525e443a16258d2502ecb7331242cf9cb19ea3a215bbe3d99",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/nconf.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "6ae827d0fc52d9419be83159a3e82be1a246bdae7ebd563d0137cf3b6810ff75",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/parser.y": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "d85cf8412fe2888fce9cc00744b2ad48fdd6a7c19252e411fef773a67454c56b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/preprocess.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "93c62d8634e3d30d71ae5092a6e49212c980837789693643f15434e74717104e",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/preprocess.h": {
      "license": "GPL-2.0-only",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "f7e9581e1d92804acadca02ffdbd298e681cb4d1fb1e04bacb59e0e2a7fe6f9b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/qconf-cfg.sh": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "6539bec5d083f88af344d5af5f2f8cd2c63a497ef9fb7542b0049d43fef30a54",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/qconf.cc": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "9066935739f9e83bb5b55fb9e4fa0dd1f3134978266758b81499a8f3b4ff2604",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/qconf.h": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "6e27491eb0137428a29c60324f288dcb7feab7466863bf2f23d1df447663db61",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/symbol.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "85dc34a5d0d23792bbe032a67f348e9d2bb08fcdf4fe0090789ba133606ff031",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/kconfig/util.c": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "4d840998f0d4768e0ddd9834d607a5d6aecd1413010cec57f91ff324b4c62138",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/pahole-version.sh": {
      "license": "GPL-2.0-only",
      "evidence": "reviewed exact header declaration; standard GPL version selected; no custom grant asserted",
      "reviewed": true,
      "sha256": "7640978c9f22186f8305f7574c5713a731ce5ad9dca6dc2e762f214208208ecc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kconfig/scripts/subarch.include": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e4934004173824330f2f08311607c1d9a5b5b586f236a839a8fdb5b13add32be",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/kobjdeps": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "565917df26908fd3a0b8fc5be84b86f8fc20ec78976d33412f8e5efc8fd5c842",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/migrate_kconfig": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1f833d49e399920735550983d17530f47518de08eaf48bf6e64a3cbe98a74804",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/migrate_kconfig.settings": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a13b2b1bf4e7e39f273f2c814d0dd42dffa505fb8246db0ae60e02db425c579b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/move-if-change": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3a8fe975ae50e35a19f9000daef72ff17bd4746bccb06d0f22859024e93e2e78",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/parsedeps": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a88145c959273fd35f2269d5472346afc1aacefb4a6f4b9e7d1c5316e28074ee",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/COPYING": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "595d6077a558c388a1e98b597e67823bcedb5da0587478e60ea973785b643f70",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/MAINTAINER": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "51f60e7a893421da544ce4cf6cb3ac8838458ea57dc9d0468c17c29740935749",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2d8b5f243e993d7beae11c0c4d4bade64ba690c57f5bf75de5ef66a0429d13bc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/README": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "025072cea3d3ee97effba92e3d3c3278c45432d7af5e3b8f0c3e22eea400f560",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/TODO": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "584b7ca3d842c192404b6ca6c8a798f7bd1c56d85460b24e6485f5cc717f89d7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/doc/Doxyfile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5bfa2784f3c9389680833915461c4100913a935f9c798eedf17b29705bfac480",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/doc/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3089082c911cd49813b822a7807b58bbc9fb084fee023eaaa6da72e8f067fcd1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/doc/manpage.dox": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d2e4a154bf57476940673381dec5574acb7db8f4b04c978b88b15b6757ab6c33",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/src/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "07cab16a0d27c6117febabba1fa35a36ebdc99f939ca08238379c464330d2b73",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/src/preprocess": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "06cd44a10ae966f07258dbd33a86d60bbd3a2e7a53c90f3c68e68d3ac06067a5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "74400ce7e910e8d76601f700a8e9e171d644b586e8ab323607dc81c6dd29621b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/c-preproc.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e189b2e3f29479338d5b78d6d90a65a7aa99a7ffa6d3c93953838d575eb5c865",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/combine.pl": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0183814cd0e221a6da97b8f2766a9b73e618e27d9212ac089ffefa381468afec",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/comment_in_string.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e7b252e6c444d38333b194e8ca75169ee58b09e64f625ade793f518e673cdbfa",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/default_args.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "52a3b47eb9ddc3eb18b10969ed51209682b7c1b9de1531177a6d60fb8145d2b3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/dropsection-ext.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a297a1895701fc4e1587ec7a7dbb42e3ca911b38ab39669a1f3d771b14237501",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/dropsection.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c886419c5c8bfb15f620da409f8bb344a951c646a98b729d95b8a1116fb02cb5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/explicit.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0e7afdb043f8fa77f91e4468694526000f1841c5b9903ce07f4d793b2529d423",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/extension_inherit.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a8283f6c60c3ee5c57127db14be3454d82105030c9267c6c766289972f586996",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/extern_c.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "906905f69a1455178d2c6cae0e15bb3b66ce402cfdd88b1504ff61d12cc833bf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/func_defs.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9c8d6fe65df7731c754a519feb5e57ec15ab2ac61ddc6f3b185c64a943d1f96b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/implement_default.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3012fa7711957841d50d612f6179543ae9e2be682d4385d49c2c7ebdfdac64cc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/implement_default_err.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a28af264311b9e16128b764c57c9b41054699eb59c190315f61e1f995b79374d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/implement_template.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eec515ec9c5a7d691b1d9c640459b85eb0eec70d72401ea9c392f31dfc2ac32d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/inline.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "19f6592e0faba59f1b10881c04940fe2919649da2ef31969c0a79c4cfae7d189",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/interface.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "218854fab463cba15c61c92a665f46f804610920733c301dc0ef6790f38c09fe",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/line.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c6b354e5f2a6b16f6d12521114add7d4633af02ebab161bce98be00be803a496",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/mapping.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bfe5d3d375a0b603767a124b6fadf9e6c485ed93b3e06aa172f6e6c5da703251",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/multifile1.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1bba4d0b3a2d9155521471943a8a67f649043c561f4f376903acddb9cd30ac5a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/multifile2.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a801f2a24bbe0be85c0984825ae18f07f42f7367d100c5701040188fc62feba0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/nested_class.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b0eae062ae5e2a5ac7a0d925cbac5faca39345b6a03257498182376cdd00a62f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/noinline.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "263b3ec2e835886a5004ebb6daaca448b983443351b8d5a9c133c08fd284b1e2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/operator.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3ecd85f186d3a2d4c49f0c36177403d79ef64b0813c0b71a6bba346ad18f9e22",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/parser.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ed6ffb492fdb990900830bcb64dcad3bd41e9c4e73c37682e11634ad34d6a7b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/static.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2a6e1e868a514ad64c4a4ecc550098130541f1e1d9a64c0f10de2164068571fd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/tag_enabled.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6d83043a05c89815c82bf83dc3332af668f11475130dbb8c0844558280d37934",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/template.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cc5eb7c12b537e188f3e1e11abd5300756c71724359e41d253f4a5da5138b5a0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/template_base_class.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "389cc9bfcfb1939135d1e5cf2ff5a2191927ca6e934a251bd23001dd48f17723",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/variable.cpp": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dd2e1d55e4083273b2c4110a6b04a935602495dc71eb4299fc0c9c3a17dc17c7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/c-preproc.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3acd02103c569e000135f6a302eb39f8ca9a1bd251cedf305b851ec20a473832",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/c-preproc.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5341fe4bb484d8e8769af19279c968deb526d17e47dbd4b951bb0d76ef220198",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/c-preproc_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aed284551f684b8ae5df30a3c3476041b473bb41d64cbcdb5d037c34cc5935c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/comment_in_string.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c7b816a1e086d10f8ab198be30408f8512ebfa9eb23d9d97dc5e000c25eee48a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/comment_in_string.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fb23308433113daeddaeaffe2456b0256b58fe62eacfba11127def4f9b04fd3f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/comment_in_string_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5b4100e76b03bbab6ed867f3afb76e66b4737f6d81b8861f3e6cb4823432fd8b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/default_args.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0d012a632565c9d6a6a0f24b331f791fb9d7ed58d32cca788f69cac9f776e9b3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/default_args.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9cb26469e10ba93dc4c12614d7f87868b965fd119405617e5c9e684edfca09a3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/default_args_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7ad8660fe6466ffdb214d3b60e837a6a5b8c1f80199bce8a8af3ae45a8e5eb79",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_multi1-ext.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "77a1275794c6e0c0bd6c45a92f78f14b813d14cc4a8acc5351b3ec13fac7960f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_multi1.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e9bd82a9032c6fa690d5f5b0184fccb4d09123d181650b31ee636b477b9b6afd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_multi1.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bbb1c3668469a4930b1b81cd4ba6e01659283f56eed79570273982f28118b896",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_multi1_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5e30a89ecc8b6e27f17c08012a0f244ae84dfb6f9192766b1a86705122906730",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_multi2-ext.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d8649589d57e1991d83b9c0f6e0191b73766dc4a38602d8d7bb444a4ab634855",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_multi2.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bff632211bca202bea09f4237454e838276f1ce9b9127d1b69fba2364899b217",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_multi2.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8c509adf25ea65b5f08b12c88cfe4378fc18e712faf968c0e170139e30de8277",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_multi2_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "4b340da603a60173f2e91b0ef93941ba32f7e2090ce445e4da778a980c17fbda",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single1.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5dc1aab443e30f3c12c2f2fc4ade4ea5a8b912443d164540682f40809e011383",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single1.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bbb1c3668469a4930b1b81cd4ba6e01659283f56eed79570273982f28118b896",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single1_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e0f26f2a59ecceb49a45504b90e31e7f91988919fb2df18ea22eff180ace5ad3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single2.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2f1be694d199dfc5a39db1915be879ca0c620326da9e4e9d0f645444bec3e370",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single2.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5c604f6a9a323eac1c724deeb98f045df1005673622fc74fd78e492aa21b4ddc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single2_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "543996e2de56ab015173406340e32f45c1686076e46364ba9fd499c95e3c6239",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single3.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f8939abf4d7fda9b2b4c5f7b9b49b84a6807278ca9f6f3fb89154244b9b48d17",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single3.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bbb1c3668469a4930b1b81cd4ba6e01659283f56eed79570273982f28118b896",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/drop_single3_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "76a89ab3f16ddd7c7a1de80f8c31aa8227d8d7a0d2bb2b069001cf8db32022a3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/explicit.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "af33c000340dc8cd8373cd5c3f37858c22bb572deb6f4196bad09e329f410045",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/explicit.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e79b86f391337d3704e674711331a22d58d0290fa8c03bc6aac041597a1de0d9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/explicit_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cf09b818ac7405919ea1a20a2a55d6b8e58ac71014a7557a5ce7cfdce0be9c50",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/extension_inherit.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "adf10e526c36728cd4cd6a644089adfdc2b029fb4c9ff6a407f00c30513ae765",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/extension_inherit.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5a02419fba00f14aaed78029353dca80e0e8d988b701686c5d94366811790a94",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/extension_inherit_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b79c176038a959536f21882757867a3fdd4741b78a80743ac45b64e9fed9c186",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/extern_c.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bb69caf1917cb37d7a437690a160a6d782815595dcfe487326d5c4f99675c074",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/extern_c.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dc602136b061b8d6a3c8899714a3dd83c1343ad0ec230dd85c5d79acc2c6498a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/extern_c_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c46739130990ce7472e79952002a9b649340160eb402b273eb1f5bfa23afaf23",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/func_defs.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d8e14dbd28f9b6ad41c0e7c633ec3acac8203b8559a84f44d642d1aaa6f48379",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/func_defs.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "85943cc98a985675ef83be0e7f3f1cdc83a4732602d183299ae242bb58056d72",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/func_defs_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "27f4ab48dbba1b86cc02e052ed5afbf406f7a4302207cd7462af3ab469f74221",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/implement_default.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6fb16add7fdcd12f2ff3496d9590f811a9e7664925ecacd49809aad1ea66875c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/implement_default.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d473a0ce04b769504d1a211db25c765da7698b2784ce29ab1e8ee175710238d5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/implement_default.stderr": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8816203d1513659444c2c97f304235d2d66e140e272505f57f1ba29800c02ce9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/implement_default_err.stderr": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5f062d8aaa5a4fa8ba3df6e254612cb0799541efc497a2f2e3cc97dababd4fc7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/implement_default_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ffc38d60081c880d00f0df92c3a9d6cd132f36285725a5e40d1cae3595137029",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/implement_template.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "837f56fdf6e1ea165e89899d49e77af21f6a02cd56f6ad15df1d8d78beca38c9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/implement_template.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7a17e1d64b566267f6b35b002c361bff2699565146beeebf0ab509e8aaf929ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/implement_template_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ef29e55b9939d2c7459b3bc8fd9ddf5136d3f4446de4e99cc4817738a745a8a1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/inline.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0372e88e441ca25bf6f887cde067c2be986d8647792fb727f4a21f00620b5bfc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/inline.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c4b8b5a18dc0918117827671517ed662a8df3ece9aa4319ce9d138c720672a50",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/inline_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0fd7454001164d0fe14dbf503791cc78e07b00c00cec40c02acba4ed8e9e99e0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/inline_noinline.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3493d4285b1f6b73d2dd4a73b956fc3783f92cbf0c196c3e6d5753e349d0c2af",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/inline_noinline.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "526c6263983229f3bad81fdfb99d22de24d83317637d2ec412574547ae846faf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/inline_noinline_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7b7096b5fe95a2751a10a59c8a81d8e2303551ebac2e9aed6b609d35125b9fb7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/interface.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6cad213a0d20ed0baef72ac12768740fefd3fc0b00ca9a8f75045be1ac19671c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/interface_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9391162a006b780cead3b577013453fe7340e7dd56d8dd3212ba061b7b00a615",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/interfacepublic.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dd36e3dbecb205c4b7d8e721b90cb68674f05c515443d95401606ab017115465",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d9d7207b2027462485a6bf6579d7e6a3f6d9f110c43810673bb374624edebfed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2f29f96c4d4f1dd88a9b1af2c80187bec328bab1a29eaa72f070145ef0b1bf16",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "82c0221a3312d4046660333c2e03bddfa2b5d8bfa64a62fc0294e723d3b1a15b",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line_nh.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2e784259c40615806f090e14d99403d43ade082c53db532a83210291b9ef14df",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line_nh.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b6fa8bdc0cccd9225cb2d1c8807c05f6110692fca295c14e6fdc7188d4606b18",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line_nh_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "376f62c4b2e97c6cade5e3ef38e67b4e771b128f68c120d96e62728421b33fc3",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line_not.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "733f128625b99801449bd702ab53a6eea8c124d912ab8591ba676f6014bd602d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line_not.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b6fa8bdc0cccd9225cb2d1c8807c05f6110692fca295c14e6fdc7188d4606b18",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/line_not_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e35060e8c57137e9649fd535e68bf6f0a660d2ddbdfabf4e25fb374c2a9061ed",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/mapping.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1e4ad215d8d4459f03641bf18986e179ab495fb59ee96561baf74b66e7f816ad",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/mapping.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2b1ce1cb6b4f1a16c00df42348d4e61e7483e1ec58d043725b85c2508f9e04de",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/mapping_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a62afecf7b553112c613be6ed732892cdc266e275af6a8cd15e045a5148a81b5",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/mapping_inline.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e4178a321b11ab13e716ea5b47e22c501a25adc0dbad19e9d2dd4cf55d66b2a6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/mapping_inline.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b837c771b9169a0efd3731c0f4ca637020cdb3d61d0e90c4040dc09ded341d05",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/mapping_inline_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "59c76a0732318593ad38038788ace86ee76cb81eb9a2503fe2d850dde4221e5c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/multifile-part1.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "043800629d56c6818f1ea0b7ccf45fe3b40c9595e129001b9000bdb823c133b4",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/multifile-part2.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "07f9f2196fe727964849c7e7d1818d30f402d44847053627fe09ef3949e0d503",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/multifile.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2750938db12a2381d2958c30f2eb59d0fae7b0499bbc2481b4d781a7a8fe97dc",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/multifile.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a760d66222518d15b667400b3c2c3e577a8a15dafe59f99d0533735e7777a1f7",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/multifile_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "06310fd7c8418334247d3bd19019bd8a6b1c3b9e096065b4162df8eb93492fe6",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/nested_class.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bfd265214e6aa44872b12593b57e276e23a420e701a0e2e60c64867f9edab879",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/nested_class.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "eb11c9403400984c3f3632cd0fa7dfb25d85484f8e894c12061d131caa025149",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/nested_class_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e8acace4a5086c29eaccc09ae09a7da44e306c8f2834b42a843fb09a599d3fa1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/noinline.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b5ef1e0d8d745f276da434af9cae7390120457a31668ad0aa438f895a3edc547",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/noinline.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dc602136b061b8d6a3c8899714a3dd83c1343ad0ec230dd85c5d79acc2c6498a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/noinline_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d46339f47dc7f328179e69958b0fcb966317b6284b674b61c13b38e218547666",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/operator.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "180c0a710217ba69cf2b022daa078ad3bd14027277cf3baef29f3ec75151bf6c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/operator.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "f33e64a0c94b5b111c25ee425783f258e38da4f18687c369018c7c62bbed7307",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/operator_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3173cacf54814434e48a2afbb0ab3c36fe89a8fe90348b211d3e90d5b5adcba9",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/parser.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "97f5bff97f0bb976f46bce32a376922ed32ab4063aae831fb930f2300fa6ed04",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/parser.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "cce937601f8e42a38f49aba7f4ef45459950a5ca1e78378bd3907c6379051092",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/parser_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3a5768aa19ad3f7e9fd087d2b89060fd75f761d526a6e1ab8e5aa8814d0b9123",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/parser_noinline.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bbd19ab64979e792cbb914ef6c1b11a01fa9404e29ce2f3a7abb44066b6c7d16",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/parser_noinline.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2e0f4ac29e9c202c88063c52a21e40e6aa4269e3ea95d21906b9f3273fcd2203",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/parser_noinline_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6a752a7d03636048f5d5aa674f6e744b74e89d242ff4da605a8b7868eec6cabf",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/random.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2488ea412199882591f4e9496fc072f1818185eb3319c8a526c7399823c163b2",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/random.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bd32422361b33203df0f38b808599316b202f2093c336310b9df6ac2b0b8e30f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/random_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "932d9da7440f628caa9ed4b63a54252e95082d6c58effd0143c49698f2390cce",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/random_inline.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1e1975eb65d551f933028d6be86b90717af1c490c3b35ec28a1e3a5c51e418cd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/random_inline.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "127906f8470bc12a20500f35f496e6f8ad7220ae491638b067a00fd24d664564",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/random_inline_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "aade192a8a5b70104c4f95828c09b00e089aa40822e0fe3301bfd9412408134c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/static.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b63094139369ba4de95a0c1a198ec6abb0f8ca81c3d7ecb6c96ea73e078c3fa8",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/static.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dc602136b061b8d6a3c8899714a3dd83c1343ad0ec230dd85c5d79acc2c6498a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/static_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "1052ad0f53098c3c673c078a53a78a62548606ddeff7b10550bc4e6d1fe3922f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/tag_enabled.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "63fe9b28820920ab15a8bcd58812fc65e87eb105b2a3e18fc7b291255fe1368a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/tag_enabled.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "803d31cbb2e39c9f34ea714cb545cafad99f31524f1fffcb7ae84cb5c306fd6d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/tag_enabled_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "9f40ce745547807d5fbcb3f61d94203cb9a7c25b3ab47cb5b2a2c64767cd2f90",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "00a4c45e643d25adb818be6e48f937c86249280c42b941edcf0a62ad6e75865d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2bdc39d46d3ea72c76d91d7e22dc7042f629da95641181fd95b5bd93dc20f63f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template_base_class.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "2d11b09580057eb7458b9e0c96fb8c4fcd3a926f3afa500c2753ae2ef1eb9be0",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template_base_class.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ba835cfb39fe2d0363694ee9dc3efd48189a7dbf533d900c823524ddf2d88e0c",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template_base_class_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "b3773069bceadcfa7f38b093fbf9d90ee9a2dc175cec3ff0437235b8bd85ad20",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ec2af23c682fb692c1a4f55ba60aa1d0224e40248ed65f4ad768639e0b99223d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template_inline.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "ca83929c875ea2bb1bdfd1b8bf9b20dc60cc8e7b959600f5e72beb80abcd79db",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template_inline.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "7d381145628514caa348ff2c36bd45e831e297e8fe537c9b2700562d232bde3d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/template_inline_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "6f82440ece7aa4ae54bb4f83c23e282ac622a0d3818dcc3811b914e126127920",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/variable.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8757048fcc5a48dd4e31e484045e9e09342cf3d17708d57ac1cb0fef639a1960",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/variable.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "dc602136b061b8d6a3c8899714a3dd83c1343ad0ec230dd85c5d79acc2c6498a",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/preprocess/test/verify/variable_i.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "bf8df6c92d4f33345ced6630b28bf57f85f0a358f832fcaecbaf2de8b7a42e46",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/sandbox": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "af5cc323c6c699e7f75414d99d0c2710c0ba07b9f3fd482241ebef4024ef6150",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/showdeps": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c8e9a414ea858d9f6384f7a5496328fcdb8bb297cefddc5cfb269b34aa29ef61",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "tool/split_config": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "0fba194d9073780ddacb82cd05371498be14e90b3535752f3a6cddbf14e5973d",
      "kind": "file",
      "non_ascii_lines": [

      ]
    }
  },
  "changes": {
  }
}
```
