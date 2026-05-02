#ifndef _SBS_EXTERNAL_OBJC_H_
#define _SBS_EXTERNAL_OBJC_H_

#include <cstdint>
#import <Metal/Metal.h>

void preFlushCallback(id<MTLCommandBuffer>, void*);
void preCommitCallback(id<MTLCommandBuffer>, void*, void*, void*);

#endif
