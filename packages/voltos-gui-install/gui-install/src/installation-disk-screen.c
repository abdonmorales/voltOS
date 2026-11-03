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
 * Copyright (c) 2007, 2010, Oracle and/or its affiliates. All rights reserved.
 * Portions Copyright 2026 Abdon Morales.
 *
 * The Disk screen.  As in the OpenSolaris installer, the disks found by
 * target discovery are shown as a row of icons with their size and type,
 * and the chosen one is described below.  VoltOS always installs to a
 * whole disk (GPT, an EFI system partition and a ZFS pool), so the fdisk
 * partition editor of the original screen is not offered.
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <string.h>
#include <glib/gi18n.h>
#include <gtk/gtk.h>
#include "callbacks.h"
#include "installation-profile.h"
#include "interface-globals.h"
#include "window-graphics.h"
#include "installation-disk-screen.h"

static gint numdisks = 0;
static gint activedisk = -1;
static disk_info_t **alldiskinfo = NULL;
static GtkWidget **diskbuttons = NULL;
static GtkWidget *scanningbox = NULL;

static gboolean
disk_is_too_small(disk_info_t *diskinfo)
{
	return (orchestrator_om_get_disk_sizegb(diskinfo) <
	    orchestrator_om_get_mininstall_sizegb(FALSE));
}

static const gchar *
disk_icon_name(disk_info_t *diskinfo)
{
	switch (diskinfo->disk_type) {
	case OM_DTYPE_USB:
	case OM_DTYPE_FIREWIRE:
		return ("drive-removable-media");
	case OM_DTYPE_MMC:
		return ("media-flash");
	default:
		return ("drive-harddisk");
	}
}

/* The disk icon, with an error emblem when the disk is too small. */
static GtkWidget *
create_diskbutton_icon(disk_info_t *diskinfo)
{
	GtkIconTheme *theme = gtk_icon_theme_get_default();
	GdkPixbuf *disk, *emblem;
	GtkWidget *image;

	/* 48 pixels, as the original: GTK_ICON_SIZE_DIALOG looks too small */
	disk = gtk_icon_theme_load_icon(theme, disk_icon_name(diskinfo), 48,
	    GTK_ICON_LOOKUP_FORCE_SIZE, NULL);
	if (disk == NULL)
		disk = gtk_icon_theme_load_icon(theme, "drive-harddisk", 48,
		    GTK_ICON_LOOKUP_FORCE_SIZE, NULL);
	if (disk == NULL)
		return (gtk_image_new_from_icon_name("drive-harddisk",
		    GTK_ICON_SIZE_DIALOG));
	if (disk_is_too_small(diskinfo)) {
		GdkPixbuf *copy = gdk_pixbuf_copy(disk);
		g_object_unref(disk);
		disk = copy;
		emblem = gtk_icon_theme_load_icon(theme, "dialog-error", 16,
		    GTK_ICON_LOOKUP_FORCE_SIZE, NULL);
		if (emblem != NULL) {
			gint w = gdk_pixbuf_get_width(disk);
			gint h = gdk_pixbuf_get_height(disk);
			gdk_pixbuf_composite(emblem, disk, w - 16, h - 16, 16, 16,
			    w - 16, h - 16, 1, 1, GDK_INTERP_BILINEAR, 255);
			g_object_unref(emblem);
		}
	}
	image = gtk_image_new_from_pixbuf(disk);
	g_object_unref(disk);
	return (image);
}

/* "<size> <type>", e.g. "500.1GB SATA" */
static gchar *
disk_viewport_create_disk_label(guint disknum)
{
	gfloat size = orchestrator_om_get_total_disk_sizegb(alldiskinfo[disknum]);
	gchar *type = orchestrator_om_get_disk_type(alldiskinfo[disknum]);
	const gchar *units = "GB";
	gchar *label;

	if (size > GBPERTB) {
		size /= GBPERTB;
		units = "TB";
	}
	label = g_strdup_printf("%.1f%s %s", size, units, type);
	g_free(type);
	return (label);
}

static gchar *
disk_viewport_create_disk_tiptext(guint disknum)
{
	disk_info_t *diskinfo = alldiskinfo[disknum];
	gfloat size = orchestrator_om_get_total_disk_sizegb(diskinfo);
	gchar *type = orchestrator_om_get_disk_type(diskinfo);
	const gchar *units = "GB";
	gchar *text;

	if (size > GBPERTB) {
		size /= GBPERTB;
		units = "TB";
	}
	text = g_strdup_printf(_("Size: %.1f%s\n"
	    "Type: %s\n"
	    "Vendor: %s\n"
	    "Device: %s"),
	    size, units, type,
	    orchestrator_om_get_disk_vendor(diskinfo),
	    orchestrator_om_get_disk_devicename(diskinfo));
	g_free(type);
	return (text);
}

static void
disk_selection_set_active_disk(gint disknum)
{
	InstallationDiskWindowXML *w = &MainWindow.InstallationDiskWindow;
	disk_info_t *diskinfo;
	gchar *markup, *size;

	activedisk = disknum;
	diskinfo = alldiskinfo[disknum];
	size = disk_viewport_create_disk_label(disknum);

	if (disk_is_too_small(diskinfo)) {
		markup = g_markup_printf_escaped(
		    _("<span font=\"Bold\">This disk is too small.</span> "
		    "%s needs at least %.1fGB."),
		    DISTRO_NAME, orchestrator_om_get_mininstall_sizegb(TRUE));
		gtk_widget_show(w->diskerrorimage);
		gtk_widget_hide(w->diskwarningimage);
		gtk_widget_hide(w->diskwarninghbox);
		gtk_widget_set_sensitive(glade_xml_get_widget(
		    MainWindow.installationdiskwindowxml, "partitioningvbox"),
		    FALSE);
	} else {
		markup = g_markup_printf_escaped(
		    _("<span font=\"Bold\">%s</span>  %s (%s)"),
		    orchestrator_om_get_disk_vendor(diskinfo), size,
		    orchestrator_om_get_disk_devicename(diskinfo));
		gtk_widget_hide(w->diskerrorimage);
		gtk_widget_hide(w->diskwarningimage);
		gtk_widget_show(w->diskwarninghbox);
		gtk_widget_set_sensitive(glade_xml_get_widget(
		    MainWindow.installationdiskwindowxml, "partitioningvbox"),
		    TRUE);
	}
	gtk_label_set_markup(GTK_LABEL(w->diskstatuslabel), markup);
	gtk_widget_show(w->diskstatuslabel);
	g_free(markup);
	g_free(size);
}

static void
installationdisk_diskbutton_toggled(GtkWidget *widget, gpointer user_data)
{
	if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(widget)))
		disk_selection_set_active_disk(GPOINTER_TO_INT(user_data));
}

/* An icon radio button: disk picture above its size and type. */
static GtkWidget *
disk_toggle_button_new_with_label(const gchar *label, disk_info_t *diskinfo,
    GtkWidget *group)
{
	GtkWidget *button, *vbox, *buttonlabel, *image;

	button = group ? gtk_radio_button_new_from_widget(
	    GTK_RADIO_BUTTON(group)) : gtk_radio_button_new(NULL);
	/* Don't draw the check box indicator of the normal radiobutton */
	gtk_toggle_button_set_mode(GTK_TOGGLE_BUTTON(button), FALSE);
	gtk_button_set_relief(GTK_BUTTON(button), GTK_RELIEF_NONE);

	vbox = gtk_vbox_new(FALSE, 0);
	image = create_diskbutton_icon(diskinfo);
	gtk_box_pack_start(GTK_BOX(vbox), image, TRUE, TRUE, 0);
	buttonlabel = gtk_label_new(label);
	gtk_box_pack_end(GTK_BOX(vbox), buttonlabel, FALSE, FALSE, 0);
	gtk_container_add(GTK_CONTAINER(button), vbox);
	gtk_widget_show_all(button);
	return (button);
}

static void
disk_viewport_diskbuttons_init(GtkViewport *viewport)
{
	GtkWidget *hbuttonbox;
	gint disknum;

	hbuttonbox = gtk_hbox_new(FALSE, 36);
	gtk_container_set_border_width(GTK_CONTAINER(hbuttonbox), 6);
	diskbuttons = g_new0(GtkWidget *, numdisks);
	for (disknum = 0; disknum < numdisks; disknum++) {
		gchar *label = disk_viewport_create_disk_label(disknum);
		gchar *tip = disk_viewport_create_disk_tiptext(disknum);

		diskbuttons[disknum] = disk_toggle_button_new_with_label(label,
		    alldiskinfo[disknum], disknum > 0 ? diskbuttons[0] : NULL);
		gtk_widget_set_tooltip_text(diskbuttons[disknum], tip);
		g_free(label);
		g_free(tip);
		gtk_box_pack_start(GTK_BOX(hbuttonbox), diskbuttons[disknum],
		    FALSE, FALSE, 0);
		g_signal_connect(G_OBJECT(diskbuttons[disknum]), "toggled",
		    G_CALLBACK(installationdisk_diskbutton_toggled),
		    GINT_TO_POINTER(disknum));
	}
	gtk_widget_show(hbuttonbox);
	gtk_container_add(GTK_CONTAINER(viewport), hbuttonbox);
}

/* The first disk big enough for VoltOS, or else the first disk. */
static gint
get_default_disk_index(void)
{
	gint i;

	for (i = 0; i < numdisks; i++)
		if (!disk_is_too_small(alldiskinfo[i]))
			return (i);
	return (numdisks > 0 ? 0 : -1);
}

static gboolean
disk_discovery_monitor(gpointer user_data)
{
	InstallationDiskWindowXML *w = &MainWindow.InstallationDiskWindow;
	gint chosendisk;

	/* Wait until target discovery has finished. */
	if (MainWindow.MileStoneComplete[OM_UPGRADE_TARGET_DISCOVERY] == FALSE)
		return (TRUE);

	alldiskinfo = orchestrator_om_get_disk_info(omhandle, &numdisks);
	if (scanningbox) {
		gtk_widget_destroy(scanningbox);
		scanningbox = NULL;
	}
	if (numdisks == 0) {
		gchar *markup = g_strdup_printf("<span font=\"Bold\">%s</span>",
		    _("No disks were found."));
		gtk_label_set_markup(GTK_LABEL(w->diskstatuslabel), markup);
		g_free(markup);
		gtk_widget_show(w->diskerrorimage);
		gtk_widget_show(w->diskstatuslabel);
		gtk_widget_hide(glade_xml_get_widget(
		    MainWindow.installationdiskwindowxml, "partitioningvbox"));
		return (FALSE);
	}
	disk_viewport_diskbuttons_init(GTK_VIEWPORT(w->disksviewport));

	chosendisk = get_default_disk_index();
	gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(diskbuttons[chosendisk]),
	    TRUE);
	disk_selection_set_active_disk(chosendisk);
	if (gtk_widget_get_visible(w->diskselectiontoplevel))
		gtk_widget_grab_focus(diskbuttons[chosendisk]);
	gtk_widget_show(glade_xml_get_widget(
	    MainWindow.installationdiskwindowxml, "partitioningvbox"));
	return (FALSE);
}

static void
disk_viewport_ui_init(GtkViewport *viewport)
{
	GtkWidget *label, *spinner;
	gchar *markup;

	markup = g_strdup_printf("<span font=\"Bold\">%s</span>",
	    _("Finding Disks"));
	label = gtk_label_new(NULL);
	gtk_label_set_markup(GTK_LABEL(label), markup);
	g_free(markup);

	spinner = gtk_spinner_new();
	gtk_widget_set_size_request(spinner, 32, 32);
	gtk_spinner_start(GTK_SPINNER(spinner));

	scanningbox = gtk_vbox_new(FALSE, 6);
	gtk_box_pack_start(GTK_BOX(scanningbox), label, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(scanningbox), spinner, FALSE, FALSE, 0);
	gtk_widget_show_all(scanningbox);
	gtk_container_add(GTK_CONTAINER(viewport), scanningbox);
}

void
installationdisk_xml_init(void)
{
	InstallationDiskWindowXML *w = &MainWindow.InstallationDiskWindow;
	GladeXML *xml;

	xml = MainWindow.installationdiskwindowxml =
	    glade_xml_new(GLADEDIR "/" INSTALLATIONDISKFILENAME, DISKNODE, NULL);
	w->diskselectiontoplevel = glade_xml_get_widget(xml,
	    "diskselectiontoplevel");
	w->custompartitioningvbox = glade_xml_get_widget(xml,
	    "custompartitioningvbox");
	w->disksviewport = glade_xml_get_widget(xml, "disksviewport");
	w->diskselectionhscrollbar = glade_xml_get_widget(xml,
	    "diskselectionhscrollbar");
	w->diskerrorimage = glade_xml_get_widget(xml, "diskerrorimage");
	w->diskwarningimage = glade_xml_get_widget(xml, "diskwarningimage");
	w->diskstatuslabel = glade_xml_get_widget(xml, "diskstatuslabel");
	w->diskwarninghbox = glade_xml_get_widget(xml, "diskwarninghbox");
	glade_xml_signal_autoconnect(xml);
}

void
installationdisk_ui_init(void)
{
	InstallationDiskWindowXML *w = &MainWindow.InstallationDiskWindow;
	GladeXML *xml = MainWindow.installationdiskwindowxml;
	GtkAdjustment *adj;
	gchar *text;
	GdkColor backcolour;

	text = g_strdup_printf(_("Recommended size: %lluGB Minimum: %.1fGB"),
	    (unsigned long long)orchestrator_om_get_recommended_sizegb(),
	    orchestrator_om_get_mininstall_sizegb(TRUE));
	gtk_label_set_text(GTK_LABEL(MainWindow.screentitlesublabel2), text);
	g_free(text);

	text = g_strdup_printf(_("<span font=\"Bold\">%s is installed on a "
	    "whole disk: a ZFS pool with boot environments.</span>"),
	    DISTRO_NAME);
	gtk_label_set_markup(GTK_LABEL(glade_xml_get_widget(xml,
	    "partitioningchoicelabel")), text);
	g_free(text);

	/* Scroll the row of disks with the scroll bar below it. */
	adj = gtk_range_get_adjustment(GTK_RANGE(w->diskselectionhscrollbar));
#if GTK_CHECK_VERSION(3, 0, 0)
	gtk_scrollable_set_hadjustment(GTK_SCROLLABLE(w->disksviewport), adj);
#else
	gtk_viewport_set_hadjustment(GTK_VIEWPORT(w->disksviewport), adj);
#endif

	disk_viewport_ui_init(GTK_VIEWPORT(w->disksviewport));
	gtk_box_pack_start(GTK_BOX(MainWindow.screencontentvbox),
	    w->diskselectiontoplevel, TRUE, TRUE, 0);

	gdk_color_parse(WHITE_COLOR, &backcolour);
	gtk_widget_modify_bg(w->disksviewport, GTK_STATE_NORMAL, &backcolour);

	/* Only whole-disk installs: no partition editor. */
	gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(glade_xml_get_widget(xml,
	    "wholediskradio")), TRUE);
	gtk_widget_hide(glade_xml_get_widget(xml, "partitiondiskhbox"));
	gtk_widget_hide(w->custompartitioningvbox);
	gtk_widget_hide(glade_xml_get_widget(xml, "partitioningvbox"));
	gtk_widget_hide(w->diskerrorimage);
	gtk_widget_hide(w->diskwarningimage);

	g_timeout_add(200, disk_discovery_monitor, NULL);
}

void
installationdisk_wholediskradio_toggled(GtkWidget *widget, gpointer user_data)
{
}

void
installationdisk_partitiondiskradio_toggled(GtkWidget *widget,
    gpointer user_data)
{
}

gboolean
installationdisk_validate(void)
{
	if (activedisk < 0 || numdisks == 0) {
		gui_install_prompt_dialog(FALSE, FALSE, FALSE, GTK_MESSAGE_ERROR,
		    _("No disk is selected"),
		    _("Select the disk to install on."));
		return (FALSE);
	}
	if (disk_is_too_small(alldiskinfo[activedisk])) {
		gchar *msg = g_strdup_printf(
		    _("%s needs a disk of at least %.1fGB."), DISTRO_NAME,
		    orchestrator_om_get_mininstall_sizegb(TRUE));
		gui_install_prompt_dialog(FALSE, FALSE, FALSE, GTK_MESSAGE_ERROR,
		    _("The selected disk is too small"), msg);
		g_free(msg);
		return (FALSE);
	}
	return (TRUE);
}

void
installation_disk_store_data(void)
{
	disk_info_t *diskinfo = alldiskinfo[activedisk];

	InstallationProfile.diskname = diskinfo->disk_name;
	g_free(InstallationProfile.disktype);
	InstallationProfile.disktype = orchestrator_om_get_disk_type(diskinfo);
	InstallationProfile.disksize =
	    orchestrator_om_get_total_disk_sizegb(diskinfo);
	InstallationProfile.installpartsize = InstallationProfile.disksize;
	InstallationProfile.dinfo = diskinfo;
}

void
installationdisk_screen_set_default_focus(gboolean back_button)
{
	if (activedisk >= 0 && diskbuttons != NULL)
		gtk_widget_grab_focus(diskbuttons[activedisk]);
}

gboolean
installationdisk_select_by_name(const gchar *name)
{
	gint i;

	for (i = 0; i < numdisks; i++) {
		if (g_strcmp0(alldiskinfo[i]->disk_name, name) == 0) {
			gtk_toggle_button_set_active(
			    GTK_TOGGLE_BUTTON(diskbuttons[i]), TRUE);
			disk_selection_set_active_disk(i);
			return (TRUE);
		}
	}
	return (FALSE);
}
