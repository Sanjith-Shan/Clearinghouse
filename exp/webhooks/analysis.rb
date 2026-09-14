# typed: true
# frozen_string_literal: true

require 'json'

module Experiments
  module Webhooks
    # Turns one run's hostile-server log and database into the numbers experiment 6
    # reports. The server log is the ground truth for what arrived and when; the
    # database supplies when each event was created and which endpoints it was for.
    #
    # Time to delivery for a (healthy endpoint, event) pair is the wall time of the
    # first 200 the endpoint sent for that event, minus the event's created_at. Both
    # come from the same machine's clock (Clock::Real everywhere in this experiment).
    class Analysis
      extend T::Sig

      Topology = T.type_alias { T::Hash[Integer, [String, String, String]] }

      sig { params(db: Sequel::Database, topology: Topology, log_path: String).void }
      def initialize(db:, topology:, log_path:)
        @db = db
        @topology = topology
        @lines = T.let(File.readlines(log_path).map { |line| JSON.parse(line) }, T::Array[T::Hash[String, T.untyped]])
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def summary
        delivery_numbers.merge(
          'events' => @db[:events].count,
          'signature_failures' => @lines.count { |line| line['sig'] == false },
          'requests_by_kind' => @lines.group_by { |line| line['kind'] }.transform_values(&:length).sort.to_h,
          'deliveries_by_kind' => deliveries_by_kind,
          'breakers_by_kind' => breakers_by_kind
        )
      end

      # Time to delivery, overall and by when the event was created (10 s windows from
      # the first event), missing pairs, and duplicates, for healthy endpoints only.
      sig { returns(T::Hash[String, T.untyped]) }
      def delivery_numbers
        expected = expected_pairs
        received = first_receipts
        counts = expected.keys.map { |pair| received.fetch(pair, [0.0, 0]).last }
        ttds = expected.filter_map do |pair, created_at|
          (receipt = received[pair]) && [created_at, receipt.first - created_at]
        end
        duplicates = counts.sum { |count| [count - 1, 0].max }
        {
          'healthy_pairs_expected' => expected.length, 'healthy_pairs_received' => ttds.length,
          'missing' => expected.length - ttds.length, 'ttd_s' => Analysis.distribution(ttds.map(&:last)),
          'ttd_by_window_s' => windows(ttds), 'healthy_receipts' => counts.sum, 'duplicates' => duplicates,
          'duplicate_rate' => ttds.empty? ? nil : (duplicates.to_f / ttds.length).round(6)
        }
      end

      sig { params(ttds: T::Array[[Float, Float]]).returns(T::Array[T::Hash[String, T.untyped]]) }
      def windows(ttds)
        return [] if ttds.empty?

        start = T.must(ttds.map(&:first).min)
        ttds.group_by { |created_at, _| ((created_at - start) / 10).floor }.sort.map do |window, group|
          { 'from_s' => window * 10, 'pairs' => group.length }.merge(Analysis.distribution(group.map(&:last)))
        end
      end

      # Nearest-rank percentiles, in seconds, rounded to the millisecond.
      sig { params(values: T::Array[Float]).returns(T::Hash[String, T.nilable(Float)]) }
      def self.distribution(values)
        sorted = values.sort
        pick = lambda do |q|
          next nil if sorted.empty?

          sorted.fetch([(q * sorted.length).ceil - 1, 0].max).round(3)
        end
        { 'p50' => pick.call(0.50), 'p90' => pick.call(0.90), 'p99' => pick.call(0.99), 'max' => sorted.last&.round(3),
          'mean' => sorted.empty? ? nil : (sorted.sum / sorted.length).round(3) }
      end

      private

      # [endpoint number, event id] => event created_at (as a Float), for every event and
      # every healthy endpoint of its merchant.
      sig { returns(T::Hash[[Integer, String], Float]) }
      def expected_pairs
        healthy = Hash.new { |hash, key| hash[key] = [] }
        @topology.each { |number, (_, merchant, kind)| healthy[merchant] << number if kind == 'healthy' }
        pairs = {}
        @db[:events].select(:id, :merchant_id, :created_at).each do |event|
          healthy[event[:merchant_id]].each { |number| pairs[[number, event[:id]]] = event[:created_at].to_f }
        end
        pairs
      end

      # [endpoint number, event id] => [first 200's wall time, number of 200s].
      sig { returns(T::Hash[[Integer, String], [Float, Integer]]) }
      def first_receipts
        receipts = {}
        @lines.each do |line|
          next unless line['status'] == 200

          key = [line['ep'], line['evt']]
          first, count = receipts[key]
          receipts[key] = [first ? [first, line['t']].min : line['t'], count.to_i + 1]
        end
        receipts
      end

      sig { returns(T::Hash[String, T::Hash[String, Integer]]) }
      def deliveries_by_kind
        kinds = @topology.values.to_h { |(id, _, kind)| [id, kind] }
        counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        @db[:webhook_deliveries].group_and_count(:endpoint_id, :status).each do |row|
          counts[kinds.fetch(row[:endpoint_id])][row[:status]] += row[:count]
        end
        counts.sort.to_h.transform_values { |by_status| by_status.sort.to_h }
      end

      sig { returns(T::Hash[String, T::Hash[String, Integer]]) }
      def breakers_by_kind
        kinds = @topology.values.to_h { |(id, _, kind)| [id, kind] }
        counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        @db[:webhook_endpoints].select(:id, :breaker_state).each do |row|
          counts[kinds.fetch(row[:id])][row[:breaker_state]] += 1
        end
        counts.sort.to_h.transform_values { |by_state| by_state.sort.to_h }
      end
    end
  end
end
