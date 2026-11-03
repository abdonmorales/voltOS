/*
 * VoltOS: Solaris libzoneinfo(3LIB) API subset over the IANA tz database.
 *
 * Continents are the first component of the zone names ("America/Chicago"
 * belongs to America), countries come from zone.tab and their names from
 * iso3166.tab, and each time zone carries zone.tab's coordinates for the
 * installer's world map.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <glib.h>
#include "libzoneinfo.h"

#define	ZONEINFO	"/usr/share/zoneinfo"

typedef struct {
	gchar *cc;		/* ISO 3166 country code */
	gchar *coord;		/* +DDMM+DDDMM or +DDMMSS+DDDMMSS */
	gchar *tz;		/* e.g. America/Chicago */
	gchar *comment;		/* e.g. Central (most areas) */
} ZoneEntry;

static GPtrArray *zones;	/* of ZoneEntry */
static GHashTable *countries;	/* cc -> country name */

static const struct {
	const char *name;
	const char *desc;
} continent_names[] = {
	{ "Africa", "Africa" },
	{ "America", "Americas" },
	{ "Antarctica", "Antarctica" },
	{ "Arctic", "Arctic Ocean" },
	{ "Asia", "Asia" },
	{ "Atlantic", "Atlantic Ocean" },
	{ "Australia", "Australia" },
	{ "Europe", "Europe" },
	{ "Indian", "Indian Ocean" },
	{ "Pacific", "Pacific Ocean" },
};

static void
load(void)
{
	gchar *text, **lines, **l;

	if (zones != NULL)
		return;
	zones = g_ptr_array_new();
	countries = g_hash_table_new(g_str_hash, g_str_equal);

	if (g_file_get_contents(ZONEINFO "/iso3166.tab", &text, NULL, NULL)) {
		lines = g_strsplit(text, "\n", -1);
		for (l = lines; *l; l++) {
			gchar **f;
			if (**l == '#' || **l == '\0')
				continue;
			f = g_strsplit(*l, "\t", 2);
			if (f[0] && f[1])
				g_hash_table_insert(countries, g_strdup(f[0]),
				    g_strdup(f[1]));
			g_strfreev(f);
		}
		g_strfreev(lines);
		g_free(text);
	}

	if (g_file_get_contents(ZONEINFO "/zone.tab", &text, NULL, NULL)) {
		lines = g_strsplit(text, "\n", -1);
		for (l = lines; *l; l++) {
			gchar **f;
			ZoneEntry *z;
			if (**l == '#' || **l == '\0')
				continue;
			f = g_strsplit(*l, "\t", 4);
			if (f[0] && f[1] && f[2]) {
				z = g_new0(ZoneEntry, 1);
				z->cc = g_strdup(f[0]);
				z->coord = g_strdup(f[1]);
				z->tz = g_strdup(f[2]);
				z->comment = g_strdup(f[3] ? f[3] : "");
				g_ptr_array_add(zones, z);
			}
			g_strfreev(f);
		}
		g_strfreev(lines);
		g_free(text);
	}
}

static gboolean
zone_in_continent(ZoneEntry *z, const char *continent)
{
	size_t n = strlen(continent);
	return (strncmp(z->tz, continent, n) == 0 && z->tz[n] == '/');
}

int
get_tz_continents(struct tz_continent **list)
{
	struct tz_continent *head = NULL, *tail = NULL, *c;
	int i, n = 0;
	guint j;

	load();
	for (i = 0; i < (int)G_N_ELEMENTS(continent_names); i++) {
		gboolean used = FALSE;
		for (j = 0; j < zones->len && !used; j++)
			used = zone_in_continent(g_ptr_array_index(zones, j),
			    continent_names[i].name);
		if (!used)
			continue;
		c = g_new0(struct tz_continent, 1);
		g_strlcpy(c->ctnt_name, continent_names[i].name, _TZBUFLEN);
		c->ctnt_id_desc = g_strdup(continent_names[i].desc);
		if (tail)
			tail->ctnt_next = c;
		else
			head = c;
		tail = c;
		n++;
	}
	*list = head;
	return (n);
}

static gint
compare_country(gconstpointer a, gconstpointer b)
{
	const struct tz_country *x = *(struct tz_country * const *)a;
	const struct tz_country *y = *(struct tz_country * const *)b;
	return (g_utf8_collate(x->ctry_id_desc, y->ctry_id_desc));
}

int
get_tz_countries(struct tz_country **list, struct tz_continent *ctnt)
{
	GPtrArray *found;
	GHashTable *seen;
	struct tz_country *c;
	guint j;
	int n;

	load();
	found = g_ptr_array_new();
	seen = g_hash_table_new(g_str_hash, g_str_equal);
	for (j = 0; j < zones->len; j++) {
		ZoneEntry *z = g_ptr_array_index(zones, j);
		const gchar *name;
		if (!zone_in_continent(z, ctnt->ctnt_name) ||
		    g_hash_table_contains(seen, z->cc))
			continue;
		g_hash_table_add(seen, z->cc);
		c = g_new0(struct tz_country, 1);
		g_strlcpy(c->ctry_code, z->cc, _CCBUFLEN);
		name = g_hash_table_lookup(countries, z->cc);
		c->ctry_id_desc = g_strdup(name ? name : z->cc);
		c->ctry_reserved = g_strdup(ctnt->ctnt_name);
		g_ptr_array_add(found, c);
	}
	g_ptr_array_sort(found, compare_country);
	*list = NULL;
	for (j = found->len; j > 0; j--) {
		c = g_ptr_array_index(found, j - 1);
		c->ctry_next = *list;
		*list = c;
	}
	n = found->len;
	g_ptr_array_free(found, TRUE);
	g_hash_table_destroy(seen);
	return (n);
}

/* Parse "+DDMM" / "+DDMMSS" (lat) or "+DDDMM" / "+DDDMMSS" (long). */
static const char *
parse_coord(const char *s, int degdigits, int *sign, int *deg, int *min,
    int *sec)
{
	int len;
	char buf[4];

	*sign = (*s == '-') ? -1 : 1;
	s++;
	len = 0;
	while (s[len] >= '0' && s[len] <= '9')
		len++;
	memcpy(buf, s, degdigits);
	buf[degdigits] = '\0';
	*deg = atoi(buf);
	memcpy(buf, s + degdigits, 2);
	buf[2] = '\0';
	*min = atoi(buf);
	*sec = 0;
	if (len >= degdigits + 4) {
		memcpy(buf, s + degdigits + 2, 2);
		buf[2] = '\0';
		*sec = atoi(buf);
	}
	return (s + len);
}

int
get_timezones_by_country(struct tz_timezone **list, struct tz_country *ctry)
{
	struct tz_timezone *head = NULL, *tail = NULL, *t;
	struct tz_coord *c;
	const char *p;
	guint j;
	int n = 0;

	load();
	for (j = 0; j < zones->len; j++) {
		ZoneEntry *z = g_ptr_array_index(zones, j);
		if (strcmp(z->cc, ctry->ctry_code) != 0)
			continue;
		if (ctry->ctry_reserved != NULL &&
		    !zone_in_continent(z, ctry->ctry_reserved))
			continue;
		t = g_new0(struct tz_timezone, 1);
		g_strlcpy(t->tz_name, z->tz, _TZBUFLEN);
		g_strlcpy(t->tz_oname, z->tz, _TZBUFLEN);
		if (*z->comment) {
			t->tz_id_desc = g_strdup(z->comment);
		} else {
			/* "America/Argentina/Buenos_Aires" -> "Buenos Aires" */
			gchar *city = g_strdup(strrchr(z->tz, '/') + 1);
			g_strdelimit(city, "_", ' ');
			t->tz_id_desc = city;
		}
		c = &t->tz_coord;
		p = parse_coord(z->coord, 2, &c->lat_sign, &c->lat_degree,
		    &c->lat_minute, &c->lat_second);
		(void) parse_coord(p, 3, &c->long_sign, &c->long_degree,
		    &c->long_minute, &c->long_second);
		if (tail)
			tail->tz_next = t;
		else
			head = t;
		tail = t;
		n++;
	}
	*list = head;
	return (n);
}

int
free_tz_continents(struct tz_continent *c)
{
	while (c) {
		struct tz_continent *next = c->ctnt_next;
		g_free(c->ctnt_id_desc);
		g_free(c->ctnt_display_desc);
		g_free(c);
		c = next;
	}
	return (0);
}

int
free_tz_countries(struct tz_country *c)
{
	while (c) {
		struct tz_country *next = c->ctry_next;
		g_free(c->ctry_id_desc);
		g_free(c->ctry_display_desc);
		g_free(c->ctry_reserved);
		g_free(c);
		c = next;
	}
	return (0);
}

int
free_timezones(struct tz_timezone *t)
{
	while (t) {
		struct tz_timezone *next = t->tz_next;
		g_free(t->tz_id_desc);
		g_free(t->tz_display_desc);
		g_free(t);
		t = next;
	}
	return (0);
}

/*
 * The time zone /etc/localtime points at, e.g. "Europe/Berlin", in a
 * malloc()ed string the caller frees (as with Solaris's get_system_tz()).
 */
char *
get_system_tz(char *root)
{
	char tz[PATH_MAX];
	gchar *path = g_build_filename(root ? root : "/", "etc/localtime",
	    NULL);
	gchar *target = g_file_read_link(path, NULL);
	const char *p;

	g_free(path);
	g_strlcpy(tz, "UTC", sizeof (tz));
	if (target != NULL) {
		p = strstr(target, "zoneinfo/");
		if (p != NULL)
			g_strlcpy(tz, p + strlen("zoneinfo/"), sizeof (tz));
		g_free(target);
	}
	return (strdup(tz));
}
