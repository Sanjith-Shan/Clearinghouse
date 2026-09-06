# typed: ignore # rubocop:disable Sorbet/TrueSigil
# frozen_string_literal: true

# The library carries Sorbet sigs so `srb tc` checks it, but a client library must not
# make its users install sorbet-runtime. When sorbet-runtime is already loaded (as it
# is inside the Clearinghouse repo and its specs) the sigs are real and checked at
# runtime. When it is not, `sig` is a no-op and its block is never evaluated, so the
# T.nilable and friends inside it are never looked up. The code outside sig blocks
# uses no T.* helpers for the same reason.
unless defined?(T::Sig)
  module T
    module Sig # rubocop:disable Style/Documentation
      def sig(*, &); end
    end
  end
end
