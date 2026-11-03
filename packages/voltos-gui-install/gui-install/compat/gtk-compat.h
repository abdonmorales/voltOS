/*
 * VoltOS: GTK 2 names the OpenSolaris installer uses, mapped to their GTK 3
 * replacements.  Included ahead of every source file (meson.build), so the
 * imported code builds against both toolkits unchanged.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef GTK_COMPAT_H
#define	GTK_COMPAT_H

#include <gtk/gtk.h>

#if GTK_CHECK_VERSION(3, 0, 0)

typedef GType GtkType;

#define	GTK_OBJECT(o)			G_OBJECT(o)
#define	GTK_WIDGET_VISIBLE(w)		gtk_widget_get_visible(GTK_WIDGET(w))
#define	GTK_WIDGET_SENSITIVE(w)		gtk_widget_get_sensitive(GTK_WIDGET(w))
#define	GTK_WIDGET_IS_SENSITIVE(w)	gtk_widget_is_sensitive(GTK_WIDGET(w))
#define	GTK_WIDGET_REALIZED(w)		gtk_widget_get_realized(GTK_WIDGET(w))
#define	GTK_WIDGET_MAPPED(w)		gtk_widget_get_mapped(GTK_WIDGET(w))
#define	GTK_WIDGET_DRAWABLE(w)		gtk_widget_is_drawable(GTK_WIDGET(w))
#define	GTK_WIDGET_HAS_FOCUS(w)		gtk_widget_has_focus(GTK_WIDGET(w))
#define	GTK_WIDGET_CAN_FOCUS(w)		gtk_widget_get_can_focus(GTK_WIDGET(w))
#define	GTK_WIDGET_STATE(w)		gtk_widget_get_state(GTK_WIDGET(w))
#define	GTK_WIDGET_TOPLEVEL(w)		gtk_widget_is_toplevel(GTK_WIDGET(w))

#define	gtk_combo_box_new_text()	gtk_combo_box_text_new()
#define	gtk_combo_box_append_text(c, t) \
	gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(c), (t))
#define	gtk_combo_box_prepend_text(c, t) \
	gtk_combo_box_text_prepend_text(GTK_COMBO_BOX_TEXT(c), (t))
#define	gtk_combo_box_remove_text(c, p) \
	gtk_combo_box_text_remove(GTK_COMBO_BOX_TEXT(c), (p))
#define	gtk_combo_box_get_active_text(c) \
	gtk_combo_box_text_get_active_text(GTK_COMBO_BOX_TEXT(c))

/* Key names lost their compatibility aliases in GTK 3 */
#ifndef GDK_Return
#define	GDK_Return	GDK_KEY_Return
#define	GDK_KP_Enter	GDK_KEY_KP_Enter
#define	GDK_space	GDK_KEY_space
#define	GDK_Escape	GDK_KEY_Escape
#define	GDK_Tab		GDK_KEY_Tab
#define	GDK_Left	GDK_KEY_Left
#define	GDK_Right	GDK_KEY_Right
#define	GDK_Up		GDK_KEY_Up
#define	GDK_Down	GDK_KEY_Down
#define	GDK_Insert	GDK_KEY_Insert
#define	GDK_v		GDK_KEY_v
#define	GDK_V		GDK_KEY_V
#endif

#define	gtk_widget_size_request(w, r) \
	gtk_widget_get_preferred_size((w), NULL, (r))

#endif /* GTK 3 */

#endif /* GTK_COMPAT_H */
