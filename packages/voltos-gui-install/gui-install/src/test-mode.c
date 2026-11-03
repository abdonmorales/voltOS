/*
 * VoltOS: automated test mode for gui-install.
 *
 * With VOLTOS_INSTALLER_TEST=<disk> in the environment the installer
 * drives its own screens the way a user would: it selects that disk,
 * keeps the detected time zone and the default locale, creates the user
 * "volt" with password "volt", accepts the licence and installs.  The
 * outcome ("ok" or "failed: ...") is written to
 * /tmp/voltos-installer-test.result.  Dialogs are answered "OK"
 * automatically (gui_install_prompt_dialog()).  It erases the disk
 * without asking; tools/smoke-qemu.sh uses it in a virtual machine.
 *
 * SPDX-License-Identifier: MIT
 */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <stdio.h>
#include <gtk/gtk.h>
#include "callbacks.h"
#include "interface-globals.h"
#include "installation-disk-screen.h"
#include "test-mode.h"

#define	TEST_RESULT	"/tmp/voltos-installer-test.result"
#define	DISK_WAIT	60	/* seconds to wait for target discovery */

extern InstallScreen InstallCurrScreen;

static const gchar *test_disk;
static gint ticks;

gboolean
test_mode_enabled(void)
{
	if (test_disk == NULL)
		test_disk = g_getenv("VOLTOS_INSTALLER_TEST");
	return (test_disk != NULL && *test_disk != '\0');
}

static void
test_result(const gchar *text)
{
	FILE *f = fopen(TEST_RESULT, "w");

	g_message("test mode: %s", text);
	if (f != NULL) {
		fprintf(f, "%s\n", text);
		fclose(f);
	}
}

static void
next(void)
{
	on_nextbutton_clicked(GTK_BUTTON(MainWindow.nextbutton), NULL);
}

static gboolean
step(gpointer data)
{
	static InstallScreen last = NUMSCREENS;
	static gint same = 0;

	ticks++;
	/* A screen that refuses to move on means validation failed. */
	if (InstallCurrScreen == last && InstallCurrScreen != DISK_SCREEN &&
	    InstallCurrScreen != INSTALLATION_SCREEN) {
		if (++same > 3) {
			gchar *msg = g_strdup_printf("failed: stuck on screen %d",
			    InstallCurrScreen);
			test_result(msg);
			g_free(msg);
			return (G_SOURCE_REMOVE);
		}
	} else {
		same = 0;
	}
	last = InstallCurrScreen;

	switch (InstallCurrScreen) {
	case WELCOME_SCREEN:
	case TIMEZONE_SCREEN:
	case LANGUAGE_SCREEN:
		next();
		break;
	case DISK_SCREEN:
		if (!installationdisk_select_by_name(test_disk)) {
			if (ticks * 2 > DISK_WAIT) {
				test_result("failed: disk not offered");
				return (G_SOURCE_REMOVE);
			}
			break;
		}
		next();
		break;
	case USER_SCREEN:
		gtk_entry_set_text(GTK_ENTRY(MainWindow.UsersWindow.usernameentry),
		    "Volt Test");
		gtk_entry_set_text(GTK_ENTRY(
		    MainWindow.UsersWindow.loginnameentry), "volt");
		gtk_entry_set_text(GTK_ENTRY(
		    MainWindow.UsersWindow.userpassword1entry), "volt");
		gtk_entry_set_text(GTK_ENTRY(
		    MainWindow.UsersWindow.userpassword2entry), "volt");
		gtk_entry_set_text(GTK_ENTRY(
		    MainWindow.UsersWindow.hostnameentry), "voltos");
		next();
		break;
	case CONFIRMATION_SCREEN:
		gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(
		    MainWindow.ConfirmationWindow.licensecheckbutton), TRUE);
		on_installbutton_clicked(GTK_BUTTON(MainWindow.installbutton),
		    NULL);
		break;
	case INSTALLATION_SCREEN:
		/* The install runs; the screen moves on by itself. */
		break;
	case FAILURE_SCREEN:
		test_result("failed: voltos-install");
		return (G_SOURCE_REMOVE);
	case FINISH_SCREEN:
		test_result("ok");
		return (G_SOURCE_REMOVE);
	default:
		break;
	}
	return (G_SOURCE_CONTINUE);
}

void
test_mode_start(void)
{
	if (!test_mode_enabled())
		return;
	g_message("test mode: installing on %s", test_disk);
	(void) remove(TEST_RESULT);
	g_timeout_add_seconds(2, step, NULL);
}
