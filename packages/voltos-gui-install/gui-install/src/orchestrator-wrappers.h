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
 * Copyright (c) 2008, 2010, Oracle and/or its affiliates. All rights reserved.
 */

#ifndef __ORCHESTRATOR_WRAPPERS_H
#define	__ORCHESTRATOR_WRAPPERS_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <glib.h>
#include <orchestrator_api.h>

#define	MBPERGB	1024
#define	GBPERTB	1024

/* Global target discovery handle */
extern om_handle_t	omhandle;

/* Function declarations */
om_handle_t
orchestrator_om_start_discovery(om_callback_t callback);

disk_info_t	**
orchestrator_om_get_disk_info(om_handle_t handle,
    gint *numdisks);

disk_info_t	*
orchestrator_om_duplicate_disk_info(disk_info_t *dinfo);

gchar *
orchestrator_om_get_disk_type(disk_info_t *diskinfo);

gfloat
orchestrator_om_round_mbtogb(uint32_t sizemb);

guint64
orchestrator_om_get_disk_sizemb(disk_info_t *dinfo);

gfloat
orchestrator_om_get_disk_sizegb(disk_info_t *dinfo);

const gchar *
orchestrator_om_get_disk_devicename(disk_info_t *diskinfo);

const gchar *
orchestrator_om_get_disk_vendor(disk_info_t *diskinfo);

gboolean
orchestrator_om_disk_is_bootdevice(disk_info_t *diskinfo);

guint64
orchestrator_om_get_mininstall_sizemb(void);

gfloat
orchestrator_om_get_mininstall_sizegb(gboolean roundup);

guint64
orchestrator_om_get_recommended_sizemb(void);

guint64
orchestrator_om_get_recommended_sizegb(void);

guint64
orchestrator_om_get_total_disk_sizemb(disk_info_t *dinfo);

gfloat
orchestrator_om_get_total_disk_sizegb(disk_info_t *dinfo);

/* language support */
gint
orchestrator_om_get_install_languages(
    GList **locales,
	gint *total);

gint
orchestrator_om_get_available_languages(
    GList **locales,
    gint *total);

gchar *
orchestrator_om_language_get_name(lang_info_t *language);

gchar *
orchestrator_om_language_get_code(lang_info_t *language);

locale_info_t *
orchestrator_om_language_get_locales(lang_info_t *language);

gboolean
orchestrator_om_language_is_default(lang_info_t *language);

void
orchestrator_om_free_language(lang_info_t *language);

gint
orchestrator_om_language_get_locale_count(lang_info_t *language);

gchar *
orchestrator_om_locale_get_name(locale_info_t *locale);

gchar *
orchestrator_om_locale_get_desc(locale_info_t *locale);

int
orchestrator_om_perform_install(
    nvlist_t *uchoices,
    om_callback_t callback);

gboolean
orchestrator_om_locale_is_default(locale_info_t *locale);

locale_info_t *
orchestrator_om_locale_get_cposix(void);

gboolean
orchestrator_om_locale_is_cposix(locale_info_t *locale);

gboolean
orchestrator_om_locale_is_utf8(locale_info_t *locale);

void
orchestrator_om_free_locale(locale_info_t *locale);

void
orchestrator_om_set_install_lang_by_value(lang_info_t *locale_info);

void
orchestrator_om_set_install_lang_by_name(char *lang_name);

#ifdef __cplusplus
}
#endif

#endif /* __ORCHESTRATOR_WRAPPERS_H */
