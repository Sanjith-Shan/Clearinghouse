# typed: strict
# frozen_string_literal: true

# Webhook signing, the secrets behind it, and the SSRF-safe egress path.
# See docs/design/webhook-security.md.
require_relative 'signature'
require_relative 'secret_rotation'
require_relative 'egress/ip_policy'
require_relative 'egress/target'
require_relative 'egress/resolver'
require_relative 'egress/outcome'
require_relative 'safe_http'
