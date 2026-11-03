/*
 * VoltOS: libglade's glade_xml_new() over GtkBuilder (see glade-compat.h).
 *
 * SPDX-License-Identifier: MIT
 */
#include <string.h>
#include <glib.h>
#include "config.h"
#include "glade-compat.h"

GladeXML *
glade_xml_new(const char *fname, const char *root, const char *domain)
{
	GtkBuilder *builder = gtk_builder_new();
	GError *error = NULL;
	GPtrArray *ids = g_ptr_array_new_with_free_func(g_free);
	gchar *path, *text = NULL;
	GRegex *re;
	GMatchInfo *mi;

	gtk_builder_set_translation_domain(builder,
	    domain ? domain : GETTEXT_PACKAGE);
	if (g_str_has_suffix(fname, ".glade")) {
		gchar *base = g_strndup(fname, strlen(fname) - 6);
		path = g_strconcat(base, ".ui", NULL);
		g_free(base);
	} else
		path = g_strdup(fname);

	if (root == NULL) {
		if (!gtk_builder_add_from_file(builder, path, &error))
			goto fail;
		goto done;
	}
	/*
	 * Objects the tree refers to without containing them (adjustments,
	 * models) must be requested as well.
	 */
	g_ptr_array_add(ids, g_strdup(root));
	if (g_file_get_contents(path, &text, NULL, NULL)) {
		re = g_regex_new("class=\"(GtkAdjustment|GtkListStore|"
		    "GtkTreeStore|GtkSizeGroup|GtkTextBuffer)\" id=\"([^\"]+)\"",
		    0, 0, NULL);
		g_regex_match(re, text, 0, &mi);
		while (g_match_info_matches(mi)) {
			g_ptr_array_add(ids, g_match_info_fetch(mi, 2));
			g_match_info_next(mi, NULL);
		}
		g_match_info_free(mi);
		g_regex_unref(re);
		g_free(text);
	}
	g_ptr_array_add(ids, NULL);
	if (!gtk_builder_add_objects_from_file(builder, path,
	    (gchar **)ids->pdata, &error))
		goto fail;
done:
	g_ptr_array_free(ids, TRUE);
	g_free(path);
	return (builder);
fail:
	g_warning("%s: %s", path, error->message);
	g_error_free(error);
	g_ptr_array_free(ids, TRUE);
	g_free(path);
	g_object_unref(builder);
	return (NULL);
}
