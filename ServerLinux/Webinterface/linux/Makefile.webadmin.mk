# Carracho Web Admin - Linux Makefile integration
#
# Einbinden aus ServerLinux/Makefile, z.B.:
#
#   include ../Webinterface/linux/Makefile.webadmin.mk
#
# Danach `webadmin-helper` zu deinem normalen Server-Build hinzufügen, z.B.:
#
#   native: webadmin-helper $(SERVER_BIN)
#   native-werror: webadmin-helper $(SERVER_BIN)
#
# Falls Webinterface an einer anderen Stelle liegt:
#   WEBADMIN_ROOT := /pfad/zum/Webinterface
#   include $(WEBADMIN_ROOT)/linux/Makefile.webadmin.mk

WEBADMIN_ROOT ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
WEBADMIN_BUILD_SCRIPT ?= $(WEBADMIN_ROOT)/scripts/build-linux-helper.sh
WEBADMIN_DIST_DIR ?= $(WEBADMIN_ROOT)/dist/linux
WEBADMIN_HELPER ?= $(WEBADMIN_DIST_DIR)/carracho-web-admin-helper

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec
DESTDIR ?=

.PHONY: webadmin-helper webadmin-install webadmin-uninstall webadmin-clean

webadmin-helper:
	@echo "==> Building Carracho Web Admin helper"
	@CARRACHO_WEBADMIN_DIST_DIR="$(WEBADMIN_DIST_DIR)" "$(WEBADMIN_BUILD_SCRIPT)"

webadmin-install: webadmin-helper
	@echo "==> Installing Web Admin helper"
	@install -d "$(DESTDIR)$(LIBEXECDIR)/carracho"
	@install -m 0755 "$(WEBADMIN_HELPER)" \
		"$(DESTDIR)$(LIBEXECDIR)/carracho/carracho-web-admin-helper"

webadmin-uninstall:
	@rm -f "$(DESTDIR)$(LIBEXECDIR)/carracho/carracho-web-admin-helper"

webadmin-clean:
	@rm -rf "$(WEBADMIN_ROOT)/dist/linux"
	@rm -rf "$(WEBADMIN_ROOT)/.linux-build"
