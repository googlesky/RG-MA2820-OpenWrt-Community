# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk

define Build/bcm6755-cfe-kernel
	$(TOPDIR)/scripts/bcm6755-cfe-kernel.py \
		--input-file $@ \
		--output-file $@.new \
		--load-addr 0xc0008000 \
		--entry-addr 0xc0008000
	mv $@.new $@
endef

define Device/Default
  DEVICE_DTS_DIR := ../dts
  KERNEL_NAME := Image
  KERNEL := kernel-bin | lzma | bcm6755-cfe-kernel
  KERNEL_INITRAMFS := kernel-bin | lzma | bcm6755-cfe-kernel
  KERNEL_SUFFIX := -kernel.lz
  KERNEL_INITRAMFS_SUFFIX := -kernel.lz
endef

define Device/ruijie_rg-ma2820t
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-MA2820(T)
  DEVICE_VARIANT := hardware 1.0, RAM recovery
  DEVICE_DTS := bcm947622-ruijie-rg-ma2820t
  DEVICE_PACKAGES := nand-utils ubi-utils
endef
TARGET_DEVICES += ruijie_rg-ma2820t

$(eval $(call BuildImage))
