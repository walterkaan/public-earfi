/* Hand-written config for the RoomCast Go proof.
   Float build, portable C only: no ARM or x86 assembly, no DNN/DRED.
   Opus 1.6.1. See COPYING (BSD). */
#ifndef ROOMCAST_OPUS_CONFIG_H
#define ROOMCAST_OPUS_CONFIG_H

#define OPUS_BUILD 1
#define VAR_ARRAYS 1
#define FLOAT_APPROX 1

#define HAVE_LRINT 1
#define HAVE_LRINTF 1
#define HAVE_ALLOCA_H 1
#define HAVE_DLFCN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define STDC_HEADERS 1

#define PACKAGE_NAME "opus"
#define PACKAGE_VERSION "1.6.1"
#define PACKAGE_STRING "opus 1.6.1"

#endif
