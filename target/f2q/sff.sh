# Copyright (c) 2026 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SEC Floating Feature configuration file for Galaxy Z Fold2 5G (f2q)
#
# Base values come from stock F916BXXS7KXH1 floating_feature.xml (UN1CA merges them automatically).
# The source firmware (Galaxy S22) is not a foldable, and in cover-only mode the inner panel is hidden,
# so fold-specific UX is turned off ("KEY=" deletes the entry). Extra brightness is not enabled:
# stock F916B does not support it and the r8q brightness tables do not match the Fold2 panels.
SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_FOLDABLE_TYPE_FOLD=
SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_HALF_FOLDED_MODE=
SEC_FLOATING_FEATURE_SIP_CONFIG_FOLD_UX_VERSION=
