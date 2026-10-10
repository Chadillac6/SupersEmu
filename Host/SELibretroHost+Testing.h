// Test-only hooks for SELibretroHost. Not part of the app's bridging header.
#pragma once
#include "libretro.h"
#include "SECoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Makes an extra core (e.g. a stub) loadable by `initWithCoreID:`. Call before creating the host.
void SELibretroHostRegisterCore(const char *identifier, const SECoreAPI *(*api)(void));

#ifdef __cplusplus
}
#endif
