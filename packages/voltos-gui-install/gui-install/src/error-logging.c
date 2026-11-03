/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */
/*
 * Copyright 2008 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 */
/*
 * Copyright (c) 2007, 2010, Oracle and/or its affiliates. All rights reserved.
 * Portions Copyright 2026 Abdon Morales.
 *
 * Logging.  The original sent GLib messages to Solaris's liblogsvc and
 * printed the fdisk partition tables while debugging; on VoltOS messages
 * go to standard error with the program name, which the session journal
 * keeps.
 */

#include <stdio.h>
#include <config.h>
#include <glib.h>
#include "error-logging.h"

static void
gui_error_logging_handler(const gchar *log_domain, GLogLevelFlags log_level,
    const gchar *message, gpointer user_data)
{
	const gchar *level;

	switch (log_level & G_LOG_LEVEL_MASK) {
	case G_LOG_LEVEL_ERROR:
		level = "error";
		break;
	case G_LOG_LEVEL_CRITICAL:
		level = "critical";
		break;
	case G_LOG_LEVEL_WARNING:
		level = "warning";
		break;
	case G_LOG_LEVEL_DEBUG:
		/* Debug output only with G_MESSAGES_DEBUG set, as in GLib. */
		if (g_getenv("G_MESSAGES_DEBUG") == NULL)
			return;
		level = "debug";
		break;
	default:
		level = "info";
		break;
	}
	fprintf(stderr, "%s: %s%s%s: %s\n", (const gchar *)user_data,
	    log_domain ? log_domain : "", log_domain ? " " : "", level,
	    message);
}

void
gui_error_logging_init(gchar *name)
{
	g_log_set_default_handler(gui_error_logging_handler, (gpointer)name);
}
