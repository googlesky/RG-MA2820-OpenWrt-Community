# Security policy

Do not disclose credentials, private flash contents, calibration data, or
private SSH keys in a public issue. For a security-sensitive report, use
GitHub's private vulnerability reporting feature for this repository.

Firmware installation can make an AP unreachable and may require physical
UART recovery. The project cannot guarantee safe operation on an unverified
board or vendor release. Preserve complete backups and test from RAM first.

The default first-boot login is `root` / `root` and the setup WLAN is open so
an owner can recover an unconfigured AP. Isolate it during provisioning and
replace both defaults immediately.

Cluster RPCs authenticate requests and responses with HMAC-SHA256 and reject
recent repeated mutation nonces. Their HTTP transport is not confidential.
Keep AP management on a trusted wired VLAN, do not publish the cluster CGI endpoint,
and assume a passive observer on that VLAN can see a Wi-Fi secret while a new
profile is being distributed. See [docs/CLUSTER.md](docs/CLUSTER.md).
