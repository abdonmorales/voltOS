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

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <math.h>
#include <glib/gi18n.h>
#include "string.h"

#include "orchestrator-wrappers.h"

#define	NODEFAULTLANGLABEL N_("No default language support")

static float
round_up_to_tenths(float value)
{
	float newval;

	newval = roundf((value)*10.0) / 10.0;
	if (newval < value)
		newval += 0.1;
	return (newval);
}

disk_info_t **
orchestrator_om_get_disk_info(
    om_handle_t handle,
    gint *numdisks)
{
	gint numberofdisks = 0;
	disk_info_t **alldiskinfo = NULL;
	disk_info_t *infoptr = om_get_disk_info(handle, &numberofdisks);
	alldiskinfo = om_convert_linked_disk_info_to_array(handle,
	    infoptr,
	    numberofdisks);
	*numdisks = numberofdisks;
	return (alldiskinfo);
}

disk_info_t *
orchestrator_om_duplicate_disk_info(disk_info_t *dinfo)
{
	g_return_val_if_fail(dinfo != NULL, NULL);
	return (om_duplicate_disk_info(omhandle, dinfo));
}

gfloat
orchestrator_om_round_mbtogb(uint32_t sizemb)
{
	gchar *sizembstr = NULL;
	gfloat retsize = 0;

	sizembstr = g_strdup_printf("%.1f",
	    sizemb > 0 ? (gfloat)sizemb/MBPERGB : 0);
	retsize = atof(sizembstr);
	g_free(sizembstr);

	return (retsize);
}

gchar *
orchestrator_om_get_disk_type(disk_info_t *diskinfo)
{
	gchar *type = NULL;
	g_return_val_if_fail(diskinfo != NULL, NULL);

	switch (diskinfo->disk_type) {
		case OM_DTYPE_ATA:
			type = g_strdup(_("ATA"));
			break;
		case OM_DTYPE_SCSI:
			type = g_strdup(_("SCSI"));
			break;
		case OM_DTYPE_FIBRE:
			type = g_strdup(_("Fibre"));
			break;
		case OM_DTYPE_USB:
			type = g_strdup(_("USB"));
			break;
		case OM_DTYPE_SATA:
			type = g_strdup(_("SATA"));
			break;
		case OM_DTYPE_FIREWIRE:
			type = g_strdup(_("IEEE1394"));
			break;
		case OM_DTYPE_NVME:
			type = g_strdup(_("NVMe"));
			break;
		case OM_DTYPE_VIRTIO:
			type = g_strdup(_("VirtIO"));
			break;
		case OM_DTYPE_MMC:
			type = g_strdup(_("MMC"));
			break;
		default:
			type = g_strdup(_("Unknown"));
			break;
	}
	return (type);
}

guint64
orchestrator_om_get_disk_sizemb(disk_info_t *dinfo)
{
	g_return_val_if_fail(dinfo != NULL, -1);
	return (dinfo->disk_size);
}

guint64
orchestrator_om_get_total_disk_sizemb(disk_info_t *dinfo)
{
	g_return_val_if_fail(dinfo != NULL, -1);
	return (dinfo->disk_size_total);
}

gfloat
orchestrator_om_get_disk_sizegb(disk_info_t *dinfo)
{
	g_return_val_if_fail(dinfo != NULL, (gfloat)-1);
	return ((gfloat)(dinfo->disk_size)/MBPERGB);
}

gfloat
orchestrator_om_get_total_disk_sizegb(disk_info_t *dinfo)
{
	g_return_val_if_fail(dinfo != NULL, (gfloat)-1);
	return ((gfloat)(dinfo->disk_size_total)/MBPERGB);
}

const gchar*
orchestrator_om_get_disk_devicename(disk_info_t *diskinfo)
{
	g_return_val_if_fail(diskinfo != NULL, NULL);
	return (diskinfo->disk_name);
}

const gchar*
orchestrator_om_get_disk_vendor(disk_info_t *diskinfo)
{
	g_return_val_if_fail(diskinfo != NULL, NULL);
	return (diskinfo->vendor);
}

gboolean
orchestrator_om_disk_is_bootdevice(disk_info_t *diskinfo)
{
	g_return_val_if_fail(diskinfo != NULL, FALSE);
	return (diskinfo->boot_disk);
}

guint64
orchestrator_om_get_mininstall_sizemb(void)
{
	return (guint64)om_get_min_size(NULL, NULL);
}

gfloat
orchestrator_om_get_mininstall_sizegb(gboolean roundup)
{
	gfloat minsize;

	minsize = ((gfloat)om_get_min_size(NULL, NULL)/MBPERGB);
	if (roundup == FALSE)
		return (minsize);
	else
		return ((gfloat)round_up_to_tenths(minsize));
}

guint64
orchestrator_om_get_recommended_sizemb(void)
{
	return (guint64)om_get_recommended_size(NULL, NULL);
}

guint64
orchestrator_om_get_recommended_sizegb(void)
{
	return (((guint64)om_get_recommended_size(NULL, NULL) + MBPERGB / 2) /
	    MBPERGB);
}

/* language stuff */
static locale_info_t cposix = {
	"C",
	N_("C/POSIX"),
	B_TRUE,
	NULL
};

static lang_info_t nodefault = {
	&cposix,
	B_FALSE,
	NULL, /* translated string to be set later */
	1,
	NULL, /* translated string to be set later */
	NULL
};

static gint
language_cmp(
    gconstpointer a,
    gconstpointer b)
{
	lang_info_t *t1 = (lang_info_t *)a;
	lang_info_t *t2 = (lang_info_t *)b;
	gint ret = 0;

	ret = g_utf8_collate(t1->lang_name, t2->lang_name);

	return (ret);
}

gint
orchestrator_om_get_install_languages(
    GList **languages,
    gint *total)
{
	gint ret = OM_SUCCESS;
	lang_info_t *info;

	g_assert(languages != NULL);
	g_assert(total != NULL);

	info = om_get_install_lang_info(total);
	*languages = NULL;
	while (info) {
		*languages = g_list_append(*languages, info);
		info = info->next;
	}
	*languages = g_list_sort(*languages, language_cmp);

	return (ret);
}

gint
orchestrator_om_get_available_languages(GList **languages, gint *total)
{
	gint ret = OM_SUCCESS;
	lang_info_t *info;

	g_assert(languages != NULL);
	g_assert(total != NULL);

	info = om_get_lang_info(total);
	*languages = NULL;
	while (info) {
		*languages = g_list_append(*languages, info);
		info = info->next;
	}
	*languages = g_list_sort(*languages, language_cmp);
	/*
	 * Add C/Posix to the language list
	 */
	if (nodefault.lang_name == NULL)
		nodefault.lang_name = g_strdup(_(NODEFAULTLANGLABEL));
	if (nodefault.lang == NULL)
		nodefault.lang = g_strdup(_(NODEFAULTLANGLABEL));
	*languages = g_list_prepend(*languages, &nodefault);
	(*total)++;

	return (ret);
}

gchar *
orchestrator_om_language_get_name(lang_info_t *language)
{
	if (!language)
		return (NULL);
	else if (language->lang_name)
		return (language->lang_name);
	else if (language->lang)
		return (language->lang);
	else /* This should not happen */
		return (_("Unknown Language"));
}

gchar *
orchestrator_om_language_get_code(lang_info_t *language)
{
	if (!language)
		return (NULL);
	else
		return (language->lang);
}

void
orchestrator_om_free_language(lang_info_t *language)
{
	om_free_lang_info(language);
}

locale_info_t *
orchestrator_om_language_get_locales(lang_info_t *language)
{
	if (!language)
		return (NULL);
	else
		return (language->locale_info);
}

gint
orchestrator_om_language_get_locale_count(lang_info_t *language)
{
	if (!language)
		return 0;
	else
		return (language->n_locales);
}

gboolean
orchestrator_om_language_is_default(lang_info_t *language)
{
	if (!language || !language->def_lang)
		return (FALSE);
	else
		return (TRUE);
}

gchar *
orchestrator_om_locale_get_name(locale_info_t *locale)
{
	if (!locale)
		return (NULL);
	else
		return (locale->locale_name);
}

gchar *
orchestrator_om_locale_get_desc(locale_info_t *locale)
{
	if (!locale)
		return (NULL);
	else
		return (locale->locale_desc);
}

gboolean
orchestrator_om_locale_is_default(locale_info_t *locale)
{
	if (!locale || !locale->def_locale)
		return (FALSE);
	else
		return (TRUE);
}

locale_info_t *
orchestrator_om_locale_get_cposix(void)
{
	return (&cposix);
}

gboolean
orchestrator_om_locale_is_cposix(locale_info_t *locale)
{
	return (locale == &cposix);
}

gboolean
orchestrator_om_locale_is_utf8(locale_info_t *locale)
{
	gchar *str = NULL;

	str = g_strstr_len(locale->locale_name,
	    strlen(locale->locale_name), "UTF-8");
	return (str != NULL);
}

void
orchestrator_om_free_locale(locale_info_t *locale)
{
	om_free_locale_info(locale);
}

void
orchestrator_om_set_install_lang_by_value(lang_info_t *locale_info)
{
	om_set_install_lang_by_value(locale_info);
}

void
orchestrator_om_set_install_lang_by_name(char *lang_name)
{
	om_set_install_lang_by_name(lang_name);
}

int
orchestrator_om_perform_install(
    nvlist_t *uchoices,
    om_callback_t callback)
{
	return (om_perform_install(uchoices, callback));
}
