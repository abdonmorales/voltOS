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
 * Portions Copyright 2026 Abdon Morales (VoltOS: whole-disk installs).
 */

#ifndef __INSTALLATION_DISK_SCREEN_H
#define	__INSTALLATION_DISK_SCREEN_H

#ifdef __cplusplus
extern "C" {
#endif

#include <gtk/gtk.h>

typedef struct _InstallationDiskWindowXML {
	GtkWidget *diskselectiontoplevel;
	GtkWidget *custompartitioningvbox;
	GtkWidget *disksviewport;
	GtkWidget *diskselectionhscrollbar;
	GtkWidget *diskerrorimage;
	GtkWidget *diskwarningimage;
	GtkWidget *diskstatuslabel;
	GtkWidget *diskwarninghbox;
} InstallationDiskWindowXML;

/* Glade XML referenced callback functions */
void		installationdisk_wholediskradio_toggled(GtkWidget *widget,
				gpointer user_data);
void		installationdisk_partitiondiskradio_toggled(GtkWidget *widget,
				gpointer user_data);

/* UI initialisation functions */
void		installationdisk_xml_init(void);
void		installationdisk_ui_init(void);
gboolean	installationdisk_validate(void);
void		installation_disk_store_data(void);
void		installationdisk_screen_set_default_focus(gboolean back_button);

/* For the automated test: select the disk with this device name. */
gboolean	installationdisk_select_by_name(const gchar *name);

#ifdef __cplusplus
}
#endif

#endif /* __INSTALLATION_DISK_SCREEN_H */
