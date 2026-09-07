#!/bin/bash
# =============================================================================
# fix-odr-connector.sh
# RETIRED — no longer called by step2-dynamic-routing.sh.
#
# History:
#   Originally patched plugin-cfg.xml to switch the ODR <Connector> from
#   HTTPS:9443 to HTTP:9080, assuming the controller served the dynamicRouting
#   endpoint on plain HTTP. Investigation showed the controller issues a 302
#   redirect HTTP → HTTPS for /ibm/api/dynamicRouting, so the ODR library
#   (which does not follow redirects) could never connect on HTTP.
#
#   The generated plugin-cfg.xml with HTTPS connector + keyring property is
#   correct as-is. dynamicRouting setup --autoAcceptCertificates installs the
#   collective CA into plugin-key.kdb, which is the trusted keyring the
#   connector uses — no patching required.
#
# This script is kept as a no-op for reference. It performs no changes.
# =============================================================================

echo "fix-odr-connector.sh: nothing to do (connector patching no longer required)"
