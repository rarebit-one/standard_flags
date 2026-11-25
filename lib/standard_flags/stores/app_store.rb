require "json"
require "net/http"
require "uri"

module StandardFlags
  module Stores
    # The version the App Store currently offers for one app, from Apple's
    # public iTunes lookup API (no credentials):
    #
    #   StandardFlags::Stores::AppStore.new(bundle_id: "com.example.app", country: "us")
    #
    # Asked at most once an hour per process (`ttl:`); a failed lookup is
    # retried after `retry_after:` seconds, and meanwhile the last good
    # answer (or nil, so the declared `available:` applies) stands. Each
    # request has a short timeout (`timeout:` seconds, for both connecting
    # and reading). Only one thread asks at a time; the others use what is
    # cached. It never raises.
    #
    # A store version that isn't SemVer or a shorthand (`2.1.0.4`) reads as
    # unknown, so `available:` applies.
    class AppStore
      ENDPOINT = "https://itunes.apple.com/lookup".freeze
      MAX_BYTES = 256 * 1024

      attr_reader :bundle_id, :country

      def initialize(bundle_id:, country: "us", ttl: 3600, retry_after: 300, timeout: 2, clock: nil)
        raise ArgumentError, "bundle_id: must be a non-blank String" unless bundle_id.is_a?(String) && !bundle_id.strip.empty?
        raise ArgumentError, "country: must be a two-letter code" unless country.to_s.match?(/\A[A-Za-z]{2}\z/)

        @bundle_id = bundle_id.strip.freeze
        @country = country.to_s.downcase.freeze
        @ttl = ttl
        @retry_after = retry_after
        @timeout = timeout
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @mutex = Mutex.new
        @version = nil
        @next_at = nil
      end

      # The newest version in the store, or nil. Takes (and ignores) the
      # ClientApp it is asked about.
      def call(_client_app = nil)
        refresh if due?
        @version
      end

      def uri
        URI("#{ENDPOINT}?#{URI.encode_www_form(bundleId: bundle_id, country: country)}")
      end

      private

      def due?
        @next_at.nil? || @clock.call >= @next_at
      end

      def refresh
        return unless @mutex.try_lock

        begin
          return unless due?

          version = fetch
          @version = version if version
          @next_at = @clock.call + (version ? @ttl : @retry_after)
        ensure
          @mutex.unlock
        end
      end

      def fetch
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @timeout, read_timeout: @timeout,
                                   write_timeout: @timeout) { |http| http.request(Net::HTTP::Get.new(uri)) }
        return failed("HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)
        return failed("response too large") if response.body.to_s.bytesize > MAX_BYTES

        result = JSON.parse(response.body)
        version = result.is_a?(Hash) && result["results"].is_a?(Array) && result["results"].first.is_a?(Hash) &&
                  result["results"].first["version"]
        Version.parse(version) || failed("no usable version")
      rescue StandardError => e
        failed(e.class.name)
      end

      def failed(reason)
        Reporting.instrument(:store_lookup_failed, store: "app_store", error_class: reason)
        nil
      end
    end
  end
end
