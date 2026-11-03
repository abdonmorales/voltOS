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
 * Copyright 2007 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <gtk/gtk.h>
#include "window-graphics.h"

/*
 * VoltOS: the original read the window size from GConf keys that the
 * live medium set for its screen; GTK 3 has no GConf, so use the default
 * size, shrunk to fit small screens.
 */
void
window_graphics_set_size_properties(GtkWidget *window)
{
	GdkScreen *screen = gtk_widget_get_screen(window);
	gint width = DEFWIDTH, height = DEFHEIGHT;

	if (screen != NULL) {
		width = MIN(width, gdk_screen_get_width(screen) - 40);
		height = MIN(height, gdk_screen_get_height(screen) - 80);
	}
	gtk_window_set_default_size(GTK_WINDOW(window), width, height);
}

void
window_graphics_dialog_set_size_properties(GtkWidget *dialog)
{
	gtk_window_set_default_size(GTK_WINDOW(dialog),
						DEFDIALOGWIDTH, DEFDIALOGHEIGHT);
}

void
window_graphics_dialog_set_wm_properties(GtkWidget *dialog)
{
	GdkWindow *gdkwindow = NULL;

	if (!GTK_WIDGET_REALIZED(dialog)) {
		gtk_widget_realize(dialog);
	}

	gdkwindow = gtk_widget_get_window(dialog);

	if (gdkwindow) {
		gdk_window_set_functions(gdkwindow,
				GDK_FUNC_MOVE|GDK_FUNC_RESIZE|GDK_FUNC_CLOSE);
	}
}

void
window_graphics_dialog_set_properties(GtkWidget *dialog)
{
	GdkWindow *gdkwindow = NULL;

	if (!GTK_WIDGET_REALIZED(dialog)) {
		window_graphics_dialog_set_size_properties(dialog);
		window_graphics_dialog_set_wm_properties(dialog);
	}

	gdkwindow = gtk_widget_get_window(dialog);
	if (gdkwindow) {
		gdk_window_raise(gdkwindow);
	}
}
