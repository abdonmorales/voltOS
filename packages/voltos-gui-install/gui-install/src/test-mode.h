/*
 * VoltOS: automated test mode for gui-install (see test-mode.c).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef __TEST_MODE_H
#define	__TEST_MODE_H

#include <glib.h>

/* TRUE when VOLTOS_INSTALLER_TEST names a disk to install on. */
gboolean	test_mode_enabled(void);

/* Start walking through the screens (call once the main window is up). */
void		test_mode_start(void);

#endif /* __TEST_MODE_H */
