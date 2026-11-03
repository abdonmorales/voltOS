/*
 * VoltOS: the Caiman orchestrator (liborchestrator) API on Linux.
 *
 * The OpenSolaris installer's screens talk to the system only through
 * the om_* functions below.  On VoltOS:
 *
 *   - target discovery lists whole disks with lsblk(8), leaving out the
 *     disk the live medium runs from;
 *   - om_perform_install() writes a voltos-install(8) configuration file and
 *     runs "pkexec voltos-install --config FILE", turning the stages it logs
 *     into the milestones and percentages the installation screen shows;
 *   - languages and locales come from glibc's list of supported locales and
 *     the LC_IDENTIFICATION section of each locale's source file.
 *
 * SPDX-License-Identifier: MIT
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <glib.h>
#include <glib/gstdio.h>
#include "orchestrator_api.h"

#define	VOLTOS_INSTALL	"/usr/bin/voltos-install"
#define	I18N_SUPPORTED	"/usr/share/i18n/SUPPORTED"
#define	I18N_LOCALES	"/usr/share/i18n/locales"
#define	LIVE_BOOTMNT	"/run/archiso/bootmnt"

/* VoltOS needs 16 GB; 32 GB leaves room for boot environments. */
#define	MIN_SIZE_MB	(16 * 1024)
#define	RECOMMENDED_MB	(32 * 1024)

static int16_t om_errno;
static disk_info_t *disks;
static int ndisks;

/* --- name/value list --------------------------------------------------- */

struct nvlist {
	GHashTable *values;	/* name -> string */
};

int
nvlist_alloc(nvlist_t **nvl, unsigned int flag, int kmflag)
{
	(void) flag;
	(void) kmflag;
	*nvl = g_new0(nvlist_t, 1);
	(*nvl)->values = g_hash_table_new_full(g_str_hash, g_str_equal,
	    g_free, g_free);
	return (0);
}

void
nvlist_free(nvlist_t *nvl)
{
	if (nvl == NULL)
		return;
	g_hash_table_destroy(nvl->values);
	g_free(nvl);
}

int
nvlist_add_string(nvlist_t *nvl, const char *name, const char *value)
{
	if (nvl == NULL || name == NULL || value == NULL)
		return (EINVAL);
	g_hash_table_replace(nvl->values, g_strdup(name), g_strdup(value));
	return (0);
}

int
nvlist_add_uint8(nvlist_t *nvl, const char *name, uint8_t value)
{
	gchar buf[8];
	g_snprintf(buf, sizeof (buf), "%u", value);
	return (nvlist_add_string(nvl, name, buf));
}

int
nvlist_add_boolean_value(nvlist_t *nvl, const char *name, boolean_t value)
{
	return (nvlist_add_string(nvl, name, value ? "1" : "0"));
}

int
nvlist_lookup_string(nvlist_t *nvl, const char *name, char **value)
{
	char *v = nvl ? g_hash_table_lookup(nvl->values, name) : NULL;
	if (v == NULL)
		return (ENOENT);
	*value = v;
	return (0);
}

int
nvlist_lookup_uint8(nvlist_t *nvl, const char *name, uint8_t *value)
{
	char *v;
	if (nvlist_lookup_string(nvl, name, &v) != 0)
		return (ENOENT);
	*value = (uint8_t)atoi(v);
	return (0);
}

int
nvlist_lookup_boolean_value(nvlist_t *nvl, const char *name,
    boolean_t *value)
{
	char *v;
	if (nvlist_lookup_string(nvl, name, &v) != 0)
		return (ENOENT);
	*value = (strcmp(v, "1") == 0) ? B_TRUE : B_FALSE;
	return (0);
}

/* --- errors ------------------------------------------------------------- */

int16_t
om_get_error(void)
{
	return (om_errno);
}

void
om_set_error(int16_t err)
{
	om_errno = err;
}

boolean_t
om_is_valid_failure_code(int16_t err_code)
{
	return (err_code == OM_INITIAL_INSTALL_FAILED ||
	    err_code == OM_CANT_EXEC || err_code == OM_NO_INSTALL_TARGET ||
	    err_code == OM_BAD_INPUT) ? B_TRUE : B_FALSE;
}

char *
om_get_failure_source(int16_t err_code)
{
	switch (err_code) {
	case OM_CANT_EXEC:
		return ("pkexec");
	default:
		return ("voltos-install");
	}
}

char *
om_get_failure_reason(int16_t err_code)
{
	switch (err_code) {
	case OM_CANT_EXEC:
		return ("voltos-install could not be started");
	case OM_NO_INSTALL_TARGET:
		return ("no disk was chosen");
	case OM_BAD_INPUT:
		return ("a setting contains characters the installer cannot use");
	default:
		return ("voltos-install failed; see the installation log");
	}
}

/* --- single instance --------------------------------------------------- */

om_proc_return_t
om_process_running(void)
{
	static int lockfd = -1;
	gchar *path;

	if (lockfd >= 0)
		return (OM_PROC_NOT_RUNNING);
	path = g_build_filename(g_get_user_runtime_dir(), "gui-install.lock",
	    NULL);
	lockfd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
	g_free(path);
	if (lockfd < 0)
		return (OM_PROC_INFO_ERR);
	if (flock(lockfd, LOCK_EX | LOCK_NB) != 0) {
		close(lockfd);
		lockfd = -1;
		return (OM_PROC_ALREADY_RUNNING);
	}
	return (OM_PROC_NOT_RUNNING);
}

uid_t
om_get_user_uid(void)
{
	return (getuid());
}

/* --- target discovery --------------------------------------------------- */

/* The whole disk the live medium was booted from ("" if none). */
static gchar *
live_medium_disk(void)
{
	gchar *out = NULL, *src, *parent = NULL;
	gchar *argv1[] = { "findmnt", "-no", "SOURCE", LIVE_BOOTMNT, NULL };

	if (!g_spawn_sync(NULL, argv1, NULL, G_SPAWN_SEARCH_PATH |
	    G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, &out, NULL, NULL, NULL))
		return (g_strdup(""));
	src = g_strstrip(out);
	if (*src != '\0') {
		gchar *argv2[] = { "lsblk", "-no", "PKNAME", src, NULL };
		if (g_spawn_sync(NULL, argv2, NULL, G_SPAWN_SEARCH_PATH |
		    G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, &parent, NULL,
		    NULL, NULL)) {
			gchar *nl = strchr(parent, '\n');
			if (nl)
				*nl = '\0';
			g_strstrip(parent);
		}
	}
	g_free(out);
	if (parent == NULL || *parent == '\0') {
		g_free(parent);
		return (g_strdup(""));
	}
	src = g_strconcat("/dev/", parent, NULL);
	g_free(parent);
	return (src);
}

/* Unescape lsblk -P values (\xHH). */
static gchar *
lsblk_unescape(const gchar *s)
{
	GString *out = g_string_new(NULL);
	while (*s) {
		if (s[0] == '\\' && s[1] == 'x' && g_ascii_isxdigit(s[2]) &&
		    g_ascii_isxdigit(s[3])) {
			g_string_append_c(out, (gchar)(g_ascii_xdigit_value(s[2]) *
			    16 + g_ascii_xdigit_value(s[3])));
			s += 4;
		} else {
			g_string_append_c(out, *s++);
		}
	}
	return (g_strstrip(g_string_free(out, FALSE)));
}

static om_disk_type_t
disk_type_from(const gchar *tran, const gchar *name)
{
	if (g_strcmp0(tran, "sata") == 0)
		return (OM_DTYPE_SATA);
	if (g_strcmp0(tran, "ata") == 0)
		return (OM_DTYPE_ATA);
	if (g_strcmp0(tran, "nvme") == 0)
		return (OM_DTYPE_NVME);
	if (g_strcmp0(tran, "usb") == 0)
		return (OM_DTYPE_USB);
	if (g_strcmp0(tran, "sas") == 0 || g_strcmp0(tran, "scsi") == 0 ||
	    g_strcmp0(tran, "spi") == 0 || g_strcmp0(tran, "iscsi") == 0)
		return (OM_DTYPE_SCSI);
	if (g_strcmp0(tran, "fc") == 0)
		return (OM_DTYPE_FIBRE);
	if (g_strcmp0(tran, "ieee1394") == 0)
		return (OM_DTYPE_FIREWIRE);
	if (g_strcmp0(tran, "mmc") == 0 || g_str_has_prefix(name, "mmcblk"))
		return (OM_DTYPE_MMC);
	if (g_str_has_prefix(name, "vd"))
		return (OM_DTYPE_VIRTIO);
	return (OM_DTYPE_UNKNOWN);
}

static void
discover_disks(void)
{
	gchar *argv[] = { "lsblk", "-P", "-d", "-b", "-o",
	    "NAME,PATH,SIZE,TYPE,RO,RM,TRAN,VENDOR,MODEL,SERIAL,PTTYPE", NULL };
	gchar *out = NULL, **lines, **l, *skip;
	GRegex *re;
	disk_info_t *tail = NULL;

	disks = NULL;
	ndisks = 0;
	if (!g_spawn_sync(NULL, argv, NULL, G_SPAWN_SEARCH_PATH |
	    G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, &out, NULL, NULL, NULL)) {
		om_set_error(OM_TD_DISCOVERY_FAILED);
		return;
	}
	skip = live_medium_disk();
	re = g_regex_new("([A-Z]+)=\"([^\"]*)\"", 0, 0, NULL);
	lines = g_strsplit(out, "\n", -1);
	for (l = lines; *l; l++) {
		GMatchInfo *mi;
		GHashTable *f = g_hash_table_new_full(g_str_hash, g_str_equal,
		    g_free, g_free);
		const gchar *name, *path, *vendor, *model;
		disk_info_t *d;
		guint64 bytes;

		g_regex_match(re, *l, 0, &mi);
		while (g_match_info_matches(mi)) {
			gchar *raw = g_match_info_fetch(mi, 2);
			g_hash_table_insert(f, g_match_info_fetch(mi, 1),
			    lsblk_unescape(raw));
			g_free(raw);
			g_match_info_next(mi, NULL);
		}
		g_match_info_free(mi);

		name = g_hash_table_lookup(f, "NAME");
		path = g_hash_table_lookup(f, "PATH");
		if (name == NULL || path == NULL ||
		    g_strcmp0(g_hash_table_lookup(f, "TYPE"), "disk") != 0 ||
		    g_strcmp0(g_hash_table_lookup(f, "RO"), "1") == 0 ||
		    g_str_has_prefix(name, "zram") ||
		    g_strcmp0(path, skip) == 0) {
			g_hash_table_destroy(f);
			continue;
		}
		bytes = g_ascii_strtoull(g_hash_table_lookup(f, "SIZE"),
		    NULL, 10);
		d = g_new0(disk_info_t, 1);
		d->disk_name = g_strdup(path);
		d->disk_device_path = g_strdup(path);
		d->disk_size_total = (uint32_t)(bytes / (1024 * 1024));
		d->disk_size = d->disk_size_total;
		d->disk_size_sec = bytes / 512;
		d->disk_type = disk_type_from(g_hash_table_lookup(f, "TRAN"),
		    name);
		vendor = g_hash_table_lookup(f, "VENDOR");
		model = g_hash_table_lookup(f, "MODEL");
		/* virtio and some NVMe disks report a PCI vendor ID, not a name */
		if (vendor && g_str_has_prefix(vendor, "0x"))
			vendor = NULL;
		if (vendor && *vendor && model && *model)
			d->vendor = g_strdup_printf("%s %s", vendor, model);
		else if (model && *model)
			d->vendor = g_strdup(model);
		else if (vendor && *vendor)
			d->vendor = g_strdup(vendor);
		else if (d->disk_type == OM_DTYPE_VIRTIO)
			d->vendor = g_strdup("Virtual disk");
		else
			d->vendor = g_strdup(OM_UNKNOWN_STRING);
		d->serial_number = g_strdup(g_hash_table_lookup(f, "SERIAL"));
		d->removable = g_strcmp0(g_hash_table_lookup(f, "RM"), "1") == 0;
		if (g_strcmp0(g_hash_table_lookup(f, "PTTYPE"), "gpt") == 0)
			d->label = OM_LABEL_GPT;
		else if (g_strcmp0(g_hash_table_lookup(f, "PTTYPE"), "dos") == 0)
			d->label = OM_LABEL_FDISK;
		d->boot_disk = B_FALSE;
		if (tail)
			tail->next = d;
		else
			disks = d;
		tail = d;
		ndisks++;
		g_hash_table_destroy(f);
	}
	g_strfreev(lines);
	g_regex_unref(re);
	g_free(skip);
	g_free(out);
	if (ndisks == 0)
		om_set_error(OM_NO_DISKS_FOUND);
}

static gboolean
discovery_done(gpointer data)
{
	om_callback_t cb = (om_callback_t)data;
	om_callback_info_t info = { 0 };
	int m;

	discover_disks();
	/* Report every discovery milestone complete, as Caiman did. */
	for (m = OM_DISK_DISCOVERY; m <= OM_UPGRADE_TARGET_DISCOVERY; m++) {
		info.num_milestones = 4;
		info.curr_milestone = m;
		info.callback_type = OM_TARGET_TARGET_DISCOVERY;
		info.percentage_done = 100;
		cb(&info, 0);
	}
	return (G_SOURCE_REMOVE);
}

om_handle_t
om_initiate_target_discovery(om_callback_t td_cb)
{
	if (td_cb == NULL)
		return (OM_FAILURE);
	g_idle_add(discovery_done, (gpointer)td_cb);
	return (1);
}

disk_info_t *
om_get_disk_info(om_handle_t handle, int *total)
{
	(void) handle;
	*total = ndisks;
	return (disks);
}

disk_info_t *
om_duplicate_disk_info(om_handle_t handle, disk_info_t *dinfo)
{
	disk_info_t *d;

	(void) handle;
	if (dinfo == NULL)
		return (NULL);
	d = g_memdup2(dinfo, sizeof (*dinfo));
	d->disk_name = g_strdup(dinfo->disk_name);
	d->disk_volname = g_strdup(dinfo->disk_volname);
	d->disk_devid = g_strdup(dinfo->disk_devid);
	d->disk_device_path = g_strdup(dinfo->disk_device_path);
	d->vendor = g_strdup(dinfo->vendor);
	d->serial_number = g_strdup(dinfo->serial_number);
	d->next = NULL;
	return (d);
}

void
om_free_disk_info(om_handle_t handle, disk_info_t *dinfo)
{
	(void) handle;
	while (dinfo) {
		disk_info_t *next = dinfo->next;
		g_free(dinfo->disk_name);
		g_free(dinfo->disk_volname);
		g_free(dinfo->disk_devid);
		g_free(dinfo->disk_device_path);
		g_free(dinfo->vendor);
		g_free(dinfo->serial_number);
		g_free(dinfo);
		dinfo = next;
	}
}

disk_info_t **
om_convert_linked_disk_info_to_array(om_handle_t handle, disk_info_t *dinfo,
    int total)
{
	disk_info_t **a = g_new0(disk_info_t *, total + 1);
	int i;

	(void) handle;
	for (i = 0; i < total && dinfo; i++, dinfo = dinfo->next)
		a[i] = dinfo;
	return (a);
}

uint64_t
om_get_min_size(char *media, char *distro)
{
	(void) media;
	(void) distro;
	return (MIN_SIZE_MB);
}

uint64_t
om_get_recommended_size(char *media, char *distro)
{
	(void) media;
	(void) distro;
	return (RECOMMENDED_MB);
}

/* --- installation ------------------------------------------------------- */

typedef struct {
	om_callback_t	cb;
	GIOChannel	*err;
	guint		errwatch;
	FILE		*log;
	gchar		*config;
	int		milestone;
	int		percent;
	gchar		*message;
	guint		creep;
	gboolean	copying;
} Install;

static gchar *install_log_path;

const char *
om_get_install_log(void)
{
	/* The installer's log viewer shows this file (interface-globals.h). */
	if (install_log_path == NULL)
		install_log_path = g_strdup("/tmp/gui-install.log");
	return (install_log_path);
}

static void
report(Install *in, int milestone, int percent, const char *message)
{
	om_callback_info_t info = { 0 };

	in->milestone = milestone;
	in->percent = percent;
	if (message != NULL) {
		g_free(in->message);
		in->message = g_strdup(message);
	}
	info.num_milestones = 3;
	info.curr_milestone = milestone;
	info.callback_type = OM_INSTALL_TYPE;
	info.percentage_done = percent;
	info.message = in->message;
	in->cb(&info, 0);
}

/* The copy is the long stage; move the bar slowly while it runs. */
static gboolean
creep(gpointer data)
{
	Install *in = data;

	if (!in->copying)
		return (G_SOURCE_CONTINUE);
	if (in->percent < 80)
		report(in, OM_SOFTWARE_UPDATE, in->percent + 1, NULL);
	return (G_SOURCE_CONTINUE);
}

/* voltos-install's progress messages, in order. */
static void
stage(Install *in, const gchar *msg)
{
	if (g_str_has_prefix(msg, "Partitioning")) {
		report(in, OM_TARGET_INSTANTIATION, 10, msg);
	} else if (g_str_has_prefix(msg, "Creating ZFS pool")) {
		report(in, OM_TARGET_INSTANTIATION, 60, msg);
	} else if (g_str_has_prefix(msg, "Copying the system")) {
		report(in, OM_TARGET_INSTANTIATION, 100, NULL);
		in->copying = TRUE;
		report(in, OM_SOFTWARE_UPDATE, 1, "Copying VoltOS to the disk");
	} else if (g_str_has_prefix(msg, "Configuring")) {
		in->copying = FALSE;
		report(in, OM_SOFTWARE_UPDATE, 85, "Configuring the new system");
	} else if (g_str_has_prefix(msg, "Finishing")) {
		in->copying = FALSE;
		report(in, OM_SOFTWARE_UPDATE, 95,
		    "Installing the boot loader (ZFSBootMenu)");
	}
}

static gboolean
read_stderr(GIOChannel *ch, GIOCondition cond, gpointer data)
{
	Install *in = data;
	gchar *line = NULL;
	gsize len;
	GIOStatus st;

	(void) cond;
	st = g_io_channel_read_line(ch, &line, &len, NULL, NULL);
	if (st == G_IO_STATUS_AGAIN)
		return (G_SOURCE_CONTINUE);
	if (st != G_IO_STATUS_NORMAL || line == NULL) {
		g_free(line);
		in->errwatch = 0;
		return (G_SOURCE_REMOVE);
	}
	if (in->log) {
		fputs(line, in->log);
		fflush(in->log);
	}
	g_strchomp(line);
	if (g_str_has_prefix(line, "[voltos-install] ")) {
		const gchar *msg = line + strlen("[voltos-install] ");
		if (!g_str_has_prefix(msg, "+ "))
			stage(in, msg);
	}
	g_free(line);
	return (G_SOURCE_CONTINUE);
}

static void
install_exited(GPid pid, gint status, gpointer data)
{
	Install *in = data;
	om_callback_info_t info = { 0 };

	g_spawn_close_pid(pid);
	/* Drain what is left of the log. */
	if (in->errwatch != 0)
		g_source_remove(in->errwatch);
	while (read_stderr(in->err, G_IO_IN, in) == G_SOURCE_CONTINUE)
		;
	g_io_channel_unref(in->err);
	if (in->creep)
		g_source_remove(in->creep);
	if (in->config) {
		(void) g_unlink(in->config);
		g_free(in->config);
	}
	if (in->log)
		fclose(in->log);

	if (g_spawn_check_wait_status(status, NULL)) {
		report(in, OM_SOFTWARE_UPDATE, 100, NULL);
		report(in, OM_POSTINSTAL_TASKS, 100, NULL);
	} else {
		om_set_error(OM_INITIAL_INSTALL_FAILED);
		info.num_milestones = 3;
		info.curr_milestone = -1;
		info.callback_type = OM_INSTALL_TYPE;
		info.percentage_done = OM_INITIAL_INSTALL_FAILED;
		in->cb(&info, 0);
	}
	g_free(in->message);
	g_free(in);
}

/* Read KEYMAP from the live system's console settings. */
static gchar *
current_keymap(void)
{
	gchar *text = NULL, *keymap = NULL, **lines, **l;

	if (g_file_get_contents("/etc/vconsole.conf", &text, NULL, NULL)) {
		lines = g_strsplit(text, "\n", -1);
		for (l = lines; *l; l++)
			if (g_str_has_prefix(*l, "KEYMAP="))
				keymap = g_strdup(*l + strlen("KEYMAP="));
		g_strfreev(lines);
		g_free(text);
	}
	if (keymap == NULL || *keymap == '\0') {
		g_free(keymap);
		keymap = g_strdup("us");
	}
	return (keymap);
}

static gboolean
put(GString *conf, const char *key, const char *value)
{
	if (value == NULL || *value == '\0')
		return (TRUE);
	if (strchr(value, '\n') != NULL)
		return (FALSE);
	g_string_append_printf(conf, "%s=%s\n", key, value);
	return (TRUE);
}

int
om_perform_install(nvlist_t *uchoices, om_callback_t inst_cb)
{
	GString *conf;
	gchar *disk = NULL, *s, *keymap, *locale = NULL, *fullname = NULL;
	gchar *path;
	gchar *argv[6];
	gint fd, errfd, i = 0;
	GPid pid;
	GError *error = NULL;
	Install *in;
	boolean_t test = B_FALSE;
	gboolean ok = TRUE;

	if (inst_cb == NULL || uchoices == NULL) {
		om_set_error(OM_BAD_INPUT);
		return (OM_FAILURE);
	}
	if (nvlist_lookup_string(uchoices, OM_ATTR_DISK_NAME, &disk) != 0) {
		om_set_error(OM_NO_INSTALL_TARGET);
		return (OM_FAILURE);
	}

	conf = g_string_new("# Written by gui-install\n");
	ok &= put(conf, "DISK", disk);
	if (nvlist_lookup_string(uchoices, OM_ATTR_HOST_NAME, &s) == 0)
		ok &= put(conf, "HOSTNAME", s);
	if (nvlist_lookup_string(uchoices, OM_ATTR_LOGIN_NAME, &s) == 0)
		ok &= put(conf, "USERNAME", s);
	if (nvlist_lookup_string(uchoices, OM_ATTR_USER_NAME, &fullname) == 0)
		ok &= put(conf, "FULLNAME", fullname);
	if (nvlist_lookup_string(uchoices, OM_ATTR_USER_PASSWORD, &s) == 0)
		ok &= put(conf, "PASSWORD", s);
	if (nvlist_lookup_string(uchoices, OM_ATTR_TIMEZONE_INFO, &s) == 0)
		ok &= put(conf, "TIMEZONE", s);
	if (nvlist_lookup_string(uchoices, OM_ATTR_DEFAULT_LOCALE,
	    &locale) == 0) {
		/* The installed system always uses a UTF-8 locale. */
		if (strcmp(locale, "C") == 0 || strcmp(locale, "POSIX") == 0)
			ok &= put(conf, "LOCALE", "C.UTF-8");
		else
			ok &= put(conf, "LOCALE", locale);
	}
	if (nvlist_lookup_string(uchoices, OM_ATTR_KEYMAP, &s) == 0) {
		ok &= put(conf, "KEYMAP", s);
	} else {
		keymap = current_keymap();
		ok &= put(conf, "KEYMAP", keymap);
		g_free(keymap);
	}
	ok &= put(conf, "REBOOT", "no");
	if (!ok) {
		g_string_free(conf, TRUE);
		om_set_error(OM_BAD_INPUT);
		return (OM_FAILURE);
	}

	fd = g_file_open_tmp("voltos-install-XXXXXX.conf", &path, &error);
	if (fd < 0) {
		g_warning("%s", error->message);
		g_clear_error(&error);
		g_string_free(conf, TRUE);
		om_set_error(OM_CANT_EXEC);
		return (OM_FAILURE);
	}
	(void) fchmod(fd, 0600);
	if (write(fd, conf->str, conf->len) != (ssize_t)conf->len) {
		close(fd);
		(void) g_unlink(path);
		g_free(path);
		g_string_free(conf, TRUE);
		om_set_error(OM_CANT_EXEC);
		return (OM_FAILURE);
	}
	close(fd);
	g_string_free(conf, TRUE);

	(void) nvlist_lookup_boolean_value(uchoices, OM_ATTR_INSTALL_TEST,
	    &test);
	if (test) {
		/* CAIMAN_DUMMY_INSTALL=1: show what would be installed. */
		g_message("dummy install, configuration in %s", path);
		argv[i++] = "cat";
		argv[i++] = path;
	} else {
		if (getuid() != 0)
			argv[i++] = "pkexec";
		argv[i++] = VOLTOS_INSTALL;
		argv[i++] = "--config";
		argv[i++] = path;
	}
	argv[i] = NULL;

	in = g_new0(Install, 1);
	in->cb = inst_cb;
	in->config = path;
	in->log = fopen(om_get_install_log(), "w");
	if (!g_spawn_async_with_pipes(NULL, argv, NULL,
	    G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD |
	    G_SPAWN_STDOUT_TO_DEV_NULL, NULL, NULL, &pid, NULL, NULL,
	    &errfd, &error)) {
		g_warning("%s", error->message);
		g_clear_error(&error);
		(void) g_unlink(path);
		g_free(path);
		if (in->log)
			fclose(in->log);
		g_free(in);
		om_set_error(OM_CANT_EXEC);
		return (OM_FAILURE);
	}
	in->err = g_io_channel_unix_new(errfd);
	g_io_channel_set_close_on_unref(in->err, TRUE);
	in->errwatch = g_io_add_watch(in->err, G_IO_IN | G_IO_HUP | G_IO_ERR,
	    read_stderr, in);
	g_child_watch_add(pid, install_exited, in);
	in->creep = g_timeout_add_seconds(3, creep, in);
	report(in, OM_TARGET_INSTANTIATION, 0, "Preparing the disk");
	return (OM_SUCCESS);
}

/*
 * voltos-install sets the password with chpasswd(8), which hashes it, so
 * the plain text is passed through (in a 0600 file removed afterwards).
 */
char *
om_encrypt_passwd(char *passwd, char *username)
{
	(void) username;
	return (passwd);
}

static gchar *chosen_timezone;

int
om_set_time_zone(char *timezone)
{
	g_free(chosen_timezone);
	chosen_timezone = g_strdup(timezone);
	/* Interpret the date and time the user enters in this zone. */
	if (timezone != NULL) {
		gchar *tz = g_strconcat(":", timezone, NULL);
		g_setenv("TZ", tz, TRUE);
		g_free(tz);
	}
	return (OM_SUCCESS);
}

/* --- languages and locales ---------------------------------------------- */

/* LC_IDENTIFICATION's "language" and "territory" for a locale source. */
static void
locale_identity(const gchar *source, gchar **language, gchar **territory)
{
	gchar *path = g_build_filename(I18N_LOCALES, source, NULL);
	gchar *text = NULL, **lines, **l;

	*language = *territory = NULL;
	if (g_file_get_contents(path, &text, NULL, NULL)) {
		gboolean in_id = FALSE;
		lines = g_strsplit(text, "\n", -1);
		for (l = lines; *l; l++) {
			gchar *t = g_strstrip(*l);
			gchar **target = NULL;
			if (g_str_has_prefix(t, "LC_IDENTIFICATION"))
				in_id = TRUE;
			else if (g_str_has_prefix(t, "END LC_IDENTIFICATION"))
				break;
			if (!in_id)
				continue;
			if (g_str_has_prefix(t, "language "))
				target = language;
			else if (g_str_has_prefix(t, "territory "))
				target = territory;
			if (target != NULL && *target == NULL) {
				gchar *q1 = strchr(t, '"'), *q2;
				if (q1 && (q2 = strchr(q1 + 1, '"')) != NULL)
					*target = g_strndup(q1 + 1, q2 - q1 - 1);
			}
		}
		g_strfreev(lines);
		g_free(text);
	}
	g_free(path);
}

static lang_info_t *languages;
static int nlanguages;

static void
load_languages(void)
{
	gchar *text = NULL, **lines, **l;
	GHashTable *bylang;
	lang_info_t *tail = NULL;

	if (languages != NULL)
		return;
	bylang = g_hash_table_new(g_str_hash, g_str_equal);
	if (!g_file_get_contents(I18N_SUPPORTED, &text, NULL, NULL))
		text = g_strdup("en_US.UTF-8 UTF-8\n");
	lines = g_strsplit(text, "\n", -1);
	for (l = lines; *l; l++) {
		gchar **f = g_strsplit(*l, " ", 2), *name, *source, *code;
		gchar *language = NULL, *territory = NULL;
		lang_info_t *lang;
		locale_info_t *loc, **pp;

		/* Only UTF-8 locales: "de_DE.UTF-8 UTF-8", "sr_RS@latin UTF-8" */
		if (f[0] == NULL || f[1] == NULL ||
		    strcmp(f[1], "UTF-8") != 0) {
			g_strfreev(f);
			continue;
		}
		name = f[0];
		/* Source file: name without the codeset (keep @modifier). */
		source = g_strdup(name);
		{
			gchar *dot = strchr(source, '.');
			if (dot) {
				gchar *at = strchr(dot, '@');
				if (at)
					memmove(dot, at, strlen(at) + 1);
				else
					*dot = '\0';
			}
		}
		code = g_strndup(name, strcspn(name, "_.@"));
		locale_identity(source, &language, &territory);

		lang = g_hash_table_lookup(bylang, code);
		if (lang == NULL) {
			lang = g_new0(lang_info_t, 1);
			lang->lang = g_strdup(code);
			lang->lang_name = g_strdup(language ? language : code);
			lang->def_lang = strcmp(code, "en") == 0;
			g_hash_table_insert(bylang, lang->lang, lang);
			if (tail)
				tail->next = lang;
			else
				languages = lang;
			tail = lang;
			nlanguages++;
		}
		loc = g_new0(locale_info_t, 1);
		/* glibc's SUPPORTED spells some UTF-8 names in lower case. */
		loc->locale_name = g_strdup(name);
		if (language && territory)
			loc->locale_desc = g_strdup_printf("%s (%s)", language,
			    territory);
		else
			loc->locale_desc = g_strdup(name);
		loc->def_locale = strcmp(name, "en_US.UTF-8") == 0;
		for (pp = &lang->locale_info; *pp; pp = &(*pp)->next)
			;
		*pp = loc;
		lang->n_locales++;

		g_free(language);
		g_free(territory);
		g_free(source);
		g_free(code);
		g_strfreev(f);
	}
	g_strfreev(lines);
	g_free(text);
	g_hash_table_destroy(bylang);
}

lang_info_t *
om_get_lang_info(int *total)
{
	load_languages();
	*total = nlanguages;
	return (languages);
}

/* The installer itself is in English. */
lang_info_t *
om_get_install_lang_info(int *total)
{
	static lang_info_t english;
	static locale_info_t en_us = { "en_US.UTF-8", "English (United States)",
	    B_TRUE, NULL };

	english.locale_info = &en_us;
	english.def_lang = B_TRUE;
	english.lang = "en";
	english.n_locales = 1;
	english.lang_name = "English";
	*total = 1;
	return (&english);
}

int
om_set_install_lang_by_value(lang_info_t *localep)
{
	(void) localep;
	return (OM_SUCCESS);
}

int
om_set_install_lang_by_name(char *lang)
{
	(void) lang;
	return (OM_SUCCESS);
}

/* The lists are loaded once and shared; nothing to free per caller. */
void
om_free_lang_info(lang_info_t *langp)
{
	(void) langp;
}

void
om_free_locale_info(locale_info_t *localep)
{
	(void) localep;
}
