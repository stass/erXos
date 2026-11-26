// Modified by erXos: the kernel debugger's parts are deleted (docs/design-debugger.md).
// ### How to create a tracebuffer entry ###
//
// If you only need a temporary debugging aid then you can use one of
// the standard kernel logging events:
//
//   LOG_MSG(Context *context, const char *msg)
//     - context is something like context_of(this) or current_context()
//       or 0 if there is no context available
//     - msg should be displayed in the tracebuffer view
//
//   LOG_MSG_3VAL(Context *context, const char *msg,
//                Mword val1, Mword val2, Mword val3)
//     - context and msg can be used the same way LOG_MSG does
//     - val1, val2, and val3 are values that will be displayed in
//       the tracebuffer view as hexadecimal values
//
//
#pragma once

#include "globalconfig.h"


#define LOG_TRACE_COND(name, sc, ctx, fmt, cond, ...) static_cast<void>(0)
#define LOG_TRACE(name, sc, ctx, fmt, ...)     static_cast<void>(0)
#define LOG_CONTEXT_SWITCH                     static_cast<void>(0)
#define LOG_TRAP                               static_cast<void>(0)
#define LOG_TRAP_N(n)                          static_cast<void>(0)
#define LOG_TRAP_CN(c, n)                      static_cast<void>(0)
#define LOG_SCHED_SAVE(n)                      static_cast<void>(0)
#define LOG_SCHED_LOAD(n)                      static_cast<void>(0)
#define LOG_MSG(ctx, txt)                      static_cast<void>(0)
#define LOG_MSG_3VAL(ctx, txt, v1, v2, v3)     static_cast<void>(0)



#define CNT_CONTEXT_SWITCH	static_cast<void>(0)
#define CNT_ADDR_SPACE_SWITCH	static_cast<void>(0)
#define CNT_IRQ			static_cast<void>(0)
#define CNT_PAGE_FAULT		static_cast<void>(0)
#define CNT_IO_FAULT		static_cast<void>(0)
#define CNT_SCHEDULE		static_cast<void>(0)
#define CNT_EXC_IPC             static_cast<void>(0)

// FIXME: currently unused entries below
#define CNT_IPC_LONG		static_cast<void>(0)
#define CNT_TASK_CREATE		static_cast<void>(0)
#define CNT_IOBMAP_TLB_FLUSH	static_cast<void>(0)

