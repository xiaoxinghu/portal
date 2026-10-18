/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The standalone checks' bridging header: the core's own interface, which
   emacs.c uses in the module, so the checks drive views and the pipe as
   Emacs does. */
#include "../native/Core/channel.h"
#include "../native/Core/input.h"
#include "../native/Core/shortcuts.h"
#include "../native/Core/status.h"
#include "../native/Core/views.h"
#include "../native/Core/web.h"
