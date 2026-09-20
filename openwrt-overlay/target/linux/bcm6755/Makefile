# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

ARCH:=arm
BOARD:=bcm6755
BOARDNAME:=Broadcom BCM6755/BCM47622
FEATURES:=dt nand ramdisk
CPU_TYPE:=cortex-a7
SUBTARGETS:=generic

KERNEL_PATCHVER:=6.18

define Target/Description
	Build RAM-boot recovery images for Broadcom BCM6755/BCM47622 devices.
endef

include $(INCLUDE_DIR)/target.mk

KERNELNAME:=Image dtbs

DEFAULT_PACKAGES += fdt-utils nand-utils ubi-utils

$(eval $(call BuildTarget))
