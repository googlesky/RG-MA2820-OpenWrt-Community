# TODO

- [x] Replace the generic r34 provisioning identity source. The owner's two
      factory calibration files share the `et0macaddr` placeholder; the new
      source derives a full 12-hex-digit node ID from each unit's validated
      2.4 GHz radio MAC. Replace unavailable `cksum` with target-tested
      `sha256sum` for the link-local address. The regression uses one shared
      placeholder across three simulated APs, and isolated `/tmp` tests on
      AP3 produced a unique ID/address and verified calibration copy, host-key
      generation, and mDNS without changing the running r33 configuration.
- [x] Propagate the twelve-digit identity through overlay migration, A/B
      health, Wi-Fi configuration, and recovery-image validation. Remove the
      unavailable `cksum` dependency from both Wi-Fi fallback channels and
      management DHCP election. Regression tests now exercise each rejection
      path; the older six-digit identity cannot silently pass a new first boot.
- [ ] Boot the complete corrected generic image on AP3 and verify Ethernet,
      Wi-Fi, SSH, LuCI, clustering, LEDs, and a return to the current r33
      system. Offline audits and isolated provisioning do not prove boot. Keep
      the previous system intact; establish UART/RAM-boot and an exact rollback
      path before any persistent conversion.
- [ ] Document and validate migration from the owner's legacy r33 A/B format
      2 to generic format 3. The legacy updater and recovery bootstrap
      reject `DEVICE_ID='auto'` and `SYSTEM_FORMAT='3'`, so the generic system
      SquashFS is not a routine A/B update from r33. Do not use the full web
      image as a routine updater or claim a network-only rollback until an
      exact migration and recovery path has been exercised.
- [ ] Establish redistribution rights for the generated web image before
      publishing it. The image embeds owner-supplied RGOS/Broadcom binaries;
      the public source tree intentionally does not contain those components.
- [ ] Replace the historical fixed `build_date` inside the EWEB metadata with
      a release-specific value while preserving reproducible builds and vendor
      upload compatibility. This does not affect the current CRC/layout audit.
- [ ] Detect and handle rare hash collisions in the derived link-local address
      and 8-bit fallback-DHCP subnet when scaling a community cluster beyond
      the three simulated test nodes. IDs themselves use the full radio MAC.
