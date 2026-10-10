#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include "../../../Vendor/cores/mupen64plus_next/libretro-common/glsym/glsym_es3.c"
#else
#include "../../../Vendor/cores/mupen64plus_next/libretro-common/glsym/glsym_gl.c"
#endif
