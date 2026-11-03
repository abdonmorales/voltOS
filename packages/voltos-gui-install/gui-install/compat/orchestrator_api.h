/*
 * VoltOS: the Caiman orchestrator API (liborchestrator) as the installer's
 * screens use it, implemented for Linux in orchestrator-linux.c.  Disks
 * come from lsblk, the installation itself is voltos-install (run through
 * pkexec), and locales from glibc's list of supported locales.
 *
 * Type, constant and function names follow the original
 * usr/src/lib/liborchestrator/orchestrator_api.h so the screen code stays
 * as it was; the Solaris-only parts (fdisk partitions, VTOC slices, upgrade
 * of existing installs) are gone.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef _ORCHESTRATOR_API_H
#define	_ORCHESTRATOR_API_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { B_FALSE = 0, B_TRUE = 1 } boolean_t;

typedef int16_t		om_handle_t;

typedef enum {
	OM_TARGET_TARGET_DISCOVERY = 0,
	OM_SYSTEM_VALIDATION,
	OM_INSTALL_TYPE,
	OM_UPGRADE_TYPE,
	OM_TOOLS_INSTALL_TYPE
} om_callback_type_t;

typedef enum {
	OM_DISK_DISCOVERY = 0,
	OM_PARTITION_DISCOVERY,
	OM_SLICE_DISCOVERY,
	OM_UPGRADE_TARGET_DISCOVERY,
	OM_INSTANCE_DISCOVERY,
	OM_TARGET_INSTANTIATION,
	OM_UPGRADE_CHECK,
	OM_SOFTWARE_UPDATE,
	OM_POSTINSTAL_TASKS,
	OM_INSTALLER_FAILED
} om_milestone_type_t;

typedef struct om_callback_info {
	int			num_milestones;
	om_milestone_type_t	curr_milestone;
	om_callback_type_t	callback_type;
	int16_t			percentage_done;
	const char		*message;
} om_callback_info_t;

typedef void (*om_callback_t)(om_callback_info_t *, uintptr_t);

typedef enum {
	OM_DTYPE_UNKNOWN = 0,
	OM_DTYPE_ATA,
	OM_DTYPE_SCSI,
	OM_DTYPE_FIBRE,
	OM_DTYPE_USB,
	OM_DTYPE_SATA,
	OM_DTYPE_FIREWIRE,
	OM_DTYPE_NVME,
	OM_DTYPE_VIRTIO,
	OM_DTYPE_MMC
} om_disk_type_t;

typedef enum {
	OM_CTYPE_UNKNOWN = 0,
	OM_CTYPE_SOLARIS,
	OM_CTYPE_LINUXSWAP,
	OM_CTYPE_LINUX
} om_content_type_t;

typedef enum {
	OM_LABEL_UNKNOWN = 0,
	OM_LABEL_VTOC,
	OM_LABEL_GPT,
	OM_LABEL_FDISK
} om_disklabel_type_t;

typedef enum {
	OM_PROC_SUCCESS,
	OM_PROC_INFO_ERR,
	OM_PROC_DIR_ERR,
	OM_PROC_ALREADY_RUNNING,
	OM_PROC_NOT_RUNNING
} om_proc_return_t;

typedef enum {
	OM_INITIAL_INSTALL = 1,
	OM_UPGRADE
} om_install_type_t;

typedef struct disk_info {
	char			*disk_name;	/* e.g. /dev/nvme0n1 */
	char			*disk_volname;
	char			*disk_devid;
	char			*disk_device_path;
	uint32_t		disk_size;	/* usable size in MB */
	uint32_t		disk_size_total; /* total size in MB */
	om_disk_type_t		disk_type;
	char			*vendor;	/* vendor and model */
	boolean_t		boot_disk;
	om_disklabel_type_t	label;
	boolean_t		removable;
	char			*serial_number;
	uint32_t		disk_cyl_size;
	uint64_t		disk_size_sec;
	struct disk_info	*next;
} disk_info_t;

typedef struct locale_info {
	char			*locale_name;
	char			*locale_desc;
	boolean_t		def_locale;
	struct locale_info	*next;
} locale_info_t;

typedef struct lang_info {
	locale_info_t		*locale_info;
	boolean_t		def_lang;
	char			*lang;		/* e.g. "en" */
	int			n_locales;
	char			*lang_name;	/* e.g. "English" */
	struct lang_info	*next;
} lang_info_t;

/* Minimal name/value list (Solaris libnvpair subset) */
typedef struct nvlist nvlist_t;
#define	NV_UNIQUE_NAME	0x1
int	nvlist_alloc(nvlist_t **, unsigned int, int);
void	nvlist_free(nvlist_t *);
int	nvlist_add_string(nvlist_t *, const char *, const char *);
int	nvlist_add_uint8(nvlist_t *, const char *, uint8_t);
int	nvlist_add_boolean_value(nvlist_t *, const char *, boolean_t);
int	nvlist_lookup_string(nvlist_t *, const char *, char **);
int	nvlist_lookup_uint8(nvlist_t *, const char *, uint8_t *);
int	nvlist_lookup_boolean_value(nvlist_t *, const char *, boolean_t *);

#define	OM_SUCCESS	0
#define	OM_FAILURE	-1
#define	OM_UNKNOWN_STRING	"unknown"

#define	OM_ATTR_INSTALL_TYPE		"install_type"
#define	OM_ATTR_DISK_NAME		"disk_name"
#define	OM_ATTR_TIMEZONE_INFO		"timezone"
#define	OM_ATTR_DEFAULT_LOCALE		"default_locale"
#define	OM_ATTR_HOST_NAME		"host_name"
#define	OM_ATTR_ROOT_PASSWORD		"root_password"
#define	OM_ATTR_USER_NAME		"user_name"
#define	OM_ATTR_LOGIN_NAME		"login_name"
#define	OM_ATTR_USER_PASSWORD		"user_password"
#define	OM_ATTR_LOCALES_LIST		"locales_list"
#define	OM_ATTR_INSTALL_TEST		"install_test"
#define	OM_ATTR_KEYMAP			"keymap"

/* Error codes (subset) */
#define	OM_TD_DISCOVERY_FAILED			101
#define	OM_NO_DISKS_FOUND			103
#define	OM_NO_INSTALL_TARGET			201
#define	OM_INITIAL_INSTALL_FAILED		206
#define	OM_NO_HOSTNAME				215
#define	OM_NO_LNAME				217
#define	OM_NO_UPASSWD				218
#define	OM_ERROR_THREAD_CREATE			901
#define	OM_CANT_EXEC				1001
#define	OM_BAD_INPUT				999

/* Target discovery */
om_handle_t	om_initiate_target_discovery(om_callback_t td_cb);
disk_info_t	*om_get_disk_info(om_handle_t handle, int *total);
void		om_free_disk_info(om_handle_t handle, disk_info_t *dinfo);
disk_info_t	*om_duplicate_disk_info(om_handle_t handle, disk_info_t *dinfo);
disk_info_t	**om_convert_linked_disk_info_to_array(om_handle_t handle,
		    disk_info_t *dinfo, int total);

/* Installation */
int		om_perform_install(nvlist_t *uchoices, om_callback_t inst_cb);
uint64_t	om_get_min_size(char *media, char *distro);
uint64_t	om_get_recommended_size(char *media, char *distro);
uid_t		om_get_user_uid(void);
char		*om_encrypt_passwd(char *passwd, char *username);
const char	*om_get_install_log(void);

/* Locales */
lang_info_t	*om_get_install_lang_info(int *total);
lang_info_t	*om_get_lang_info(int *total);
int		om_set_install_lang_by_value(lang_info_t *localep);
int		om_set_install_lang_by_name(char *lang);
void		om_free_lang_info(lang_info_t *langp);
void		om_free_locale_info(locale_info_t *localep);

/* Time zone */
int		om_set_time_zone(char *timezone);

/* Errors */
int16_t		om_get_error(void);
void		om_set_error(int16_t err);
char		*om_get_failure_source(int16_t err_code);
char		*om_get_failure_reason(int16_t err_code);
boolean_t	om_is_valid_failure_code(int16_t err_code);

/* Single instance */
om_proc_return_t	om_process_running(void);

#ifdef __cplusplus
}
#endif

#endif	/* _ORCHESTRATOR_API_H */
