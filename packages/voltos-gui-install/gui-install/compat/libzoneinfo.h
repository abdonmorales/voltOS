/*
 * VoltOS: the parts of Solaris's libzoneinfo(3LIB) API the installer uses,
 * implemented in zoneinfo-linux.c over the IANA tz database files
 * (/usr/share/zoneinfo/zone.tab and iso3166.tab).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef _LIBZONEINFO_H
#define	_LIBZONEINFO_H

#ifdef __cplusplus
extern "C" {
#endif

#define	_TZBUFLEN	128
#define	_CCBUFLEN	32

struct tz_coord {
	int	lat_sign;
	int	lat_degree;
	int	lat_minute;
	int	lat_second;
	int	long_sign;
	int	long_degree;
	int	long_minute;
	int	long_second;
};

struct tz_timezone {
	char			tz_name[_TZBUFLEN];
	char			tz_oname[_TZBUFLEN];
	char			*tz_id_desc;
	char			*tz_display_desc;
	struct tz_coord		tz_coord;
	struct tz_timezone	*tz_next;
	void			*tz_reserved;
};

struct tz_country {
	char			ctry_code[_CCBUFLEN];
	char			*ctry_id_desc;
	char			*ctry_display_desc;
	int			ctry_status;
	struct tz_country	*ctry_next;
	void			*ctry_reserved;
};

struct tz_continent {
	char			ctnt_name[_TZBUFLEN];
	char			*ctnt_id_desc;
	char			*ctnt_display_desc;
	struct tz_continent	*ctnt_next;
	void			*ctnt_reserved;
};

int	get_tz_continents(struct tz_continent **);
int	get_tz_countries(struct tz_country **, struct tz_continent *);
int	get_timezones_by_country(struct tz_timezone **, struct tz_country *);
int	free_tz_continents(struct tz_continent *);
int	free_tz_countries(struct tz_country *);
int	free_timezones(struct tz_timezone *);
char	*get_system_tz(char *root);

#ifdef __cplusplus
}
#endif

#endif /* _LIBZONEINFO_H */
