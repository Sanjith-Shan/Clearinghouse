# typed: strict
# frozen_string_literal: true

# Webhooks: endpoints, the events outbox they read, and delivery.
# See docs/design/webhooks.md and docs/design/webhook-security.md.
require_relative 'ids'
require_relative 'db'
require_relative 'events'
require_relative 'versioning'
require_relative 'webhooks/security'
require_relative 'webhooks/event_types'
require_relative 'webhooks/endpoints'
