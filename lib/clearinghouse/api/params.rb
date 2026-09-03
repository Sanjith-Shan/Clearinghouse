# typed: true
# frozen_string_literal: true

require 'json'
require 'rack'

module Clearinghouse
  module Api
    # Request parameters, from a form-encoded or JSON body plus the query string.
    #
    # Form bodies are what Stripe's API speaks, including bracketed nesting:
    # `metadata[order_id]=6735` and `expand[]=payment_method`. Rack's nested query
    # parser already handles that, so both encodings end up as the same Hash and the
    # endpoint cannot tell them apart. The typed readers coerce form strings ("2000")
    # into the declared type and raise a parameter error naming the parameter.
    class Params
      extend T::Sig

      JSON_TYPES = %w[application/json].freeze
      FORM_TYPES = %w[application/x-www-form-urlencoded multipart/form-data].freeze

      METADATA_MAX_KEYS = 50
      METADATA_MAX_KEY_LENGTH = 40
      METADATA_MAX_VALUE_LENGTH = 500
      EXPAND_MAX_DEPTH = 4

      # A permitted parameter is a name, or a Hash of name => permitted sub-names for
      # a nested object whose keys are fixed. A name listed in `free_form` (metadata)
      # accepts any keys.
      Permitted = T.type_alias { T.any(String, T::Hash[String, T::Array[T.untyped]]) }

      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :raw

      # `prefix` names a nested object, so its readers report `shipping[name]`.
      sig { params(raw: T::Hash[String, T.untyped], prefix: T.nilable(String)).void }
      def initialize(raw, prefix: nil)
        @raw = raw
        @prefix = prefix
      end

      # The nested object `name` as Params of its own (empty when absent).
      sig { params(name: String).returns(Params) }
      def nested(name)
        value = fetch(name, false)
        return Params.new({}, prefix: full(name)) if value.nil?
        raise Errors::InvalidRequestError.invalid_parameter(full(name), 'must be an object.') unless value.is_a?(Hash)

        Params.new(value, prefix: full(name))
      end

      sig { params(request: Rack::Request).returns(Params) }
      def self.from_request(request)
        query = parse_form { request.GET }
        body = parse_body(request)
        new(query.merge(body))
      end

      sig { params(request: Rack::Request).returns(T::Hash[String, T.untyped]) }
      def self.parse_body(request)
        media_type = request.media_type
        # Rack parses (and caches) form bodies itself, and Sinatra has already asked
        # it to by the time a route runs, so the raw stream may be consumed.
        return parse_form { request.POST } if media_type.nil? || FORM_TYPES.include?(media_type)

        raw = read_raw(request)
        return {} if raw.strip.empty?
        unless JSON_TYPES.include?(media_type)
          raise Errors::InvalidRequestError.new(
            "Unsupported Content-Type #{media_type}. Send application/x-www-form-urlencoded or application/json.",
            code: 'body_invalid'
          )
        end

        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          raise Errors::InvalidRequestError.new('Invalid JSON in request body.', code: 'body_invalid')
        end
        unless parsed.is_a?(Hash)
          raise Errors::InvalidRequestError.new('A JSON body must be an object.',
                                                code: 'body_invalid')
        end

        parsed
      end

      sig { params(request: Rack::Request).returns(String) }
      def self.read_raw(request)
        body = request.body
        return '' if body.nil?

        body.rewind if body.respond_to?(:rewind)
        raw = body.read.to_s
        body.rewind if body.respond_to?(:rewind)
        raw
      end

      sig { params(blk: T.proc.returns(T.untyped)).returns(T::Hash[String, T.untyped]) }
      def self.parse_form(&blk)
        blk.call
      rescue Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError,
             Rack::QueryParser::ParamsTooDeepError => e
        raise Errors::InvalidRequestError.new("Malformed parameters: #{e.message}", code: 'body_invalid')
      end

      # Rejects any parameter not in `permitted`, naming it the way Stripe does,
      # `shipping[nmae]` for a nested one. `expand` is accepted everywhere, as in
      # Stripe's API. Call it before reading anything.
      sig { params(permitted: Permitted, free_form: T::Array[String]).returns(Params) }
      def permit!(*permitted, free_form: ['metadata'])
        check_keys!(@raw, permitted + free_form + ['expand'], free_form, @prefix)
        self
      end

      sig { params(name: String).returns(T::Boolean) }
      def key?(name) = @raw.key?(name)

      sig { params(name: String).returns(T.untyped) }
      def [](name) = @raw[name]

      sig { params(name: String, required: T::Boolean, min: T.nilable(Integer), max: T.nilable(Integer)).returns(T.nilable(Integer)) }
      def integer(name, required: false, min: nil, max: nil)
        value = fetch(name, required)
        return nil if value.nil?

        int = case value
              when Integer then value
              when /\A-?\d+\z/ then Integer(value, 10)
              else raise Errors::InvalidRequestError.invalid_parameter(full(name), 'must be an integer.')
              end
        raise Errors::InvalidRequestError.invalid_parameter(full(name), "must be at least #{min}.") if min && int < min
        raise Errors::InvalidRequestError.invalid_parameter(full(name), "must be at most #{max}.") if max && int > max

        int
      end

      sig { params(name: String, required: T::Boolean, max_length: Integer).returns(T.nilable(String)) }
      def string(name, required: false, max_length: 5000)
        value = fetch(name, required)
        return nil if value.nil?
        raise Errors::InvalidRequestError.invalid_parameter(full(name), 'must be a string.') unless value.is_a?(String)
        if value.length > max_length
          raise Errors::InvalidRequestError.invalid_parameter(full(name), "must be at most #{max_length} characters.")
        end

        value
      end

      sig { params(name: String, allowed: T::Array[String], required: T::Boolean).returns(T.nilable(String)) }
      def enum(name, allowed, required: false)
        value = string(name, required: required)
        return nil if value.nil?
        return value if allowed.include?(value)

        raise Errors::InvalidRequestError.invalid_parameter(full(name), "must be one of #{allowed.join(', ')}.")
      end

      sig { params(name: String, required: T::Boolean).returns(T.nilable(T::Boolean)) }
      def boolean(name, required: false)
        value = fetch(name, required)
        case value
        when nil then nil
        when true, 'true' then true
        when false, 'false' then false
        else raise Errors::InvalidRequestError.invalid_parameter(full(name), 'must be true or false.')
        end
      end

      # String keys to string values, within Stripe's published limits.
      sig { params(name: String).returns(T::Hash[String, String]) }
      def metadata(name = 'metadata')
        value = @raw[name]
        return {} if value.nil? || value == ''
        raise Errors::InvalidRequestError.invalid_parameter(full(name), 'must be an object.') unless value.is_a?(Hash)
        if value.size > METADATA_MAX_KEYS
          raise Errors::InvalidRequestError.invalid_parameter(full(name), "can have at most #{METADATA_MAX_KEYS} keys.")
        end

        value.to_h do |key, val|
          param = "#{full(name)}[#{key}]"
          unless key.length <= METADATA_MAX_KEY_LENGTH && (val.is_a?(String) || val.is_a?(Integer))
            raise Errors::InvalidRequestError.invalid_parameter(
              param, 'keys are at most 40 characters and values are strings.'
            )
          end
          if val.to_s.length > METADATA_MAX_VALUE_LENGTH
            raise Errors::InvalidRequestError.invalid_parameter(param, 'values are at most 500 characters.')
          end

          [key, val.to_s]
        end
      end

      # `expand[]=a&expand[]=b`, `expand[0]=a`, or a JSON array. Dotted paths are
      # checked for depth here and for meaning by the renderer.
      sig { returns(T::Array[String]) }
      def expand
        value = @raw['expand']
        list = case value
               when nil then []
               when Array then value
               when Hash then value.sort_by { |k, _| k.to_s.to_i }.map(&:last)
               else raise Errors::InvalidRequestError.invalid_parameter('expand', 'must be an array of strings.')
               end
        list.each do |path|
          unless path.is_a?(String)
            raise Errors::InvalidRequestError.invalid_parameter('expand',
                                                                'must be an array of strings.')
          end
          if path.split('.').length > EXPAND_MAX_DEPTH
            raise Errors::InvalidRequestError.invalid_parameter('expand',
                                                                "#{path} is more than #{EXPAND_MAX_DEPTH} levels deep.")
          end
        end
        list.uniq
      end

      private

      sig { params(name: String).returns(String) }
      def full(name)
        @prefix ? "#{@prefix}[#{name}]" : name
      end

      sig { params(name: String, required: T::Boolean).returns(T.untyped) }
      def fetch(name, required)
        value = @raw[name]
        raise Errors::InvalidRequestError.missing_parameter(full(name)) if required && (value.nil? || value == '')

        value == '' ? nil : value
      end

      sig do
        params(given: T::Hash[String, T.untyped], permitted: T::Array[Permitted], free_form: T::Array[String],
               prefix: T.nilable(String)).void
      end
      def check_keys!(given, permitted, free_form, prefix)
        allowed = {}
        permitted.each do |entry|
          if entry.is_a?(Hash)
            entry.each { |key, sub| allowed[key] = sub }
          else
            allowed[entry] = nil
          end
        end
        given.each do |key, value|
          full = prefix ? "#{prefix}[#{key}]" : key
          raise Errors::InvalidRequestError.unknown_parameter(full) unless allowed.key?(key)

          sub = allowed[key]
          next if sub.nil? || free_form.include?(key)
          raise Errors::InvalidRequestError.invalid_parameter(full, 'must be an object.') unless value.is_a?(Hash)

          check_keys!(value, sub, [], full)
        end
      end
    end
  end
end
