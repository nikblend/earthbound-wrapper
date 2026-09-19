//
//  BridgingHeader.h
//  EarthboundWrapper
//
//  What Swift sees of the C world.
//
//  Note what is *not* here: `libretro.h`. That header is included only from
//  EBCoreGlue.c, which is why the Swift side never has to deal with libretro's
//  variadic log function pointer, its `INT_MAX`-sentinel enums, or its nested
//  descriptor structs. The core's command numbers and joypad ids that Swift does
//  need are mirrored in Sources/Core/LibretroConstants.swift and static-asserted
//  against the real header on the C side.
//

#ifndef EARTHBOUND_WRAPPER_BRIDGING_HEADER_H
#define EARTHBOUND_WRAPPER_BRIDGING_HEADER_H

#include "EBCoreGlue.h"

#endif /* EARTHBOUND_WRAPPER_BRIDGING_HEADER_H */
