# typed: true
# frozen_string_literal: true

require_relative 'payment_methods'
require_relative 'versioning/version_change'
require_relative 'versioning/changes/amount_received_rename'
require_relative 'versioning/changes/last_payment_error_object'
require_relative 'versioning/changes/expandable_payment_method'
require_relative 'versioning/registry'
require_relative 'versioning/expander'
require_relative 'versioning/engine'
require_relative 'versioning/changelog'

module Clearinghouse
  # API versioning after Stripe's model (Brandur Leach, "APIs as infrastructure:
  # future-proofing Stripe with versioning", 2017, https://stripe.com/blog/api-versioning).
  # Versions are dates. Code renders the latest shape only, and version change
  # modules walk it back to the caller's version. See docs/design/api.md.
  module Versioning
    extend T::Sig

    Json = T.type_alias { T::Hash[String, T.untyped] }

    # The version the API launched at. Every later version is the date of a change.
    INITIAL_VERSION = '2026-01-01'

    # Every change the API has shipped. Adding one: write the class under
    # versioning/changes/, list it here, add golden files (UPDATE_GOLDEN=1) and
    # regenerate docs/api-changelog.md with bin/changelog.
    sig { returns(Registry) }
    def self.registry
      @registry ||= T.let(
        Registry.new(initial: INITIAL_VERSION, changes: [
                       Changes::AmountReceivedRename.new,
                       Changes::LastPaymentErrorObject.new,
                       Changes::ExpandablePaymentMethod.new
                     ]),
        T.nilable(Registry)
      )
    end

    # Loaders for every expandable field. The payments work registers
    # latest_charge and friends here.
    sig { returns(Expander) }
    def self.default_expander
      Expander.new.register('payment_intent', 'payment_method') { |id, _context| PaymentMethods.to_api(id) }
    end

    sig { returns(Engine) }
    def self.engine
      @engine ||= T.let(Engine.new(registry: registry, expander: default_expander), T.nilable(Engine))
    end

    sig { returns(String) }
    def self.latest = registry.latest

    sig { params(object: Json, version: String, expand: T::Array[String], context: T.untyped).returns(Json) }
    def self.render(object, version, expand: [], context: nil)
      engine.render(object, version, expand: expand, context: context)
    end

    sig { params(event: Json, version: String, context: T.untyped).returns(Json) }
    def self.render_event(event, version, context: nil)
      engine.render_event(event, version, context: context)
    end
  end
end
