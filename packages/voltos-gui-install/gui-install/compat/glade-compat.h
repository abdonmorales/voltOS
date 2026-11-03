/*
 * VoltOS: libglade's API on top of GtkBuilder.
 *
 * The OpenSolaris installer was written against libglade 2, which GTK 3
 * does not have.  Its UI files were converted to GtkBuilder format
 * (tools/glade2builder.py), and these few definitions let the screen code
 * keep calling glade_xml_new() / glade_xml_get_widget() unchanged.  The same
 * code builds against GTK 2.12+ (GtkBuilder exists there too).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef GLADE_COMPAT_H
#define	GLADE_COMPAT_H

#include <gtk/gtk.h>

typedef GtkBuilder GladeXML;

/*
 * Build the widget tree rooted at "root" (and nothing else) from "fname",
 * as libglade did; "fname" may name the old .glade file, the .ui file next
 * to it is loaded.
 */
GladeXML	*glade_xml_new(const char *fname, const char *root,
		    const char *domain);

#define	glade_xml_get_widget(xml, name) \
	((GtkWidget *)gtk_builder_get_object((xml), (name)))
#define	glade_xml_signal_autoconnect(xml) \
	gtk_builder_connect_signals((xml), NULL)
#define	glade_init()	((void)0)

#endif /* GLADE_COMPAT_H */
