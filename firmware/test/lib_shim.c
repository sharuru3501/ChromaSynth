/* Shared-library shim so that Python (ctypes) can drive the C core: tools/bridge_c.py */
#include "bridge_core.h"

size_t br_sizeof(void)
{
    return sizeof(bridge_t);
}
