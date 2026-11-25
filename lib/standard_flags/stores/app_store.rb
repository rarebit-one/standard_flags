require "json"
require "net/http"
require "timeout"
require "uri"

module StandardFlags
  module Stores
    # The version the App Store currently offers for one app, from Apple's
    # public iTunes lookup API (no credentials), as one client's
    # `store_lookup:`:
    #
    #   client :ios_app, platform: :ios, ..., store_lookup: StandardFlags::Stores::AppStore.new(bundle_id: "com.example.app")
    #
    # `call` never waits: it answers the last version fetched (nil before
    # the first, so the declared `available:` applies) and, when a refresh
    # is due, starts one in the background (a thread; `runner:` replaces
    # it). One refresh runs at a time per process, and a forked child
    # starts its own.
    #
    # A good answer is kept for `ttl:` seconds (an hour). After a failure
    # the last good answer stands and the next try waits `retry_after:`
    # seconds (5 minutes), doubling with each further failure up to `ttl:`,
    # so an unreachable store is asked rarely. Each fetch has an overall
    # `deadline:` (5 seconds) covering connect, TLS, request and body, and
    # a body cap of 256 KiB read in chunks. Failures emit
    # `store_lookup_failed.standard_flags` (`store`, `client`, `reason`);
    # nothing raises.
    #
    # A store version that isn't SemVer or a shorthand (`2.1.0.4`) reads as
    # unknown, so `available:` applies.
    class AppStore
      ENDPOINT = "https://itunes.apple.com/lookup".freeze
      MAX_BYTES = 256 * 1024
      THREAD_RUNNER = ->(&work) { Thread.new(&work) }

      attr_reader :bundle_id, :country

      def initialize(bundle_id:, country: "us", ttl: 3600, retry_after: 300, deadline: 5, clock: nil, runner: nil)
        raise ArgumentError, "bundle_id: must be a non-blank String" unless bundle_id.is_a?(String) && !bundle_id.strip.empty?
        raise ArgumentError, "country: must be a two-letter code" unless country.to_s.match?(/\A[A-Za-z]{2}\z/)

        @bundle_id = bundle_id.strip.freeze
        @country = country.to_s.downcase.freeze
        @ttl = ttl
        @retry_after = retry_after
        @deadline = deadline
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @runner = runner || THREAD_RUNNER
        @mutex = Mutex.new
        @version = nil
        @next_at = nil
        @failures = 0
        @refreshing = nil
      end

      # The newest version in the store as last fetched, or nil. Starts a
      # background refresh when one is due; never waits for it.
      def call(client_app = nil)
        refresh_later(client_app) if due?
        @version
      end

      # Fetches now, on this thread (a warm-up at boot, say), and answers
      # the version known afterwards.
      def refresh!(client_app = nil)
        refresh(client_app)
        @version
      end

      def uri
        URI("#{ENDPOINT}?#{URI.encode_www_form(bundleId: bundle_id, country: country)}")
      end

      private

      def due?
        @next_at.nil? || @clock.call >= @next_at
      end

      # Claims the refresh (unless one is running in this process) and
      # hands it to the runner.
      def refresh_later(client_app)
        claimed = @mutex.synchronize do
          next false if @refreshing == Process.pid || !due?

          @refreshing = Process.pid
        end
        return unless claimed

        @runner.call { refresh(client_app) }
      rescue StandardError => e
        @mutex.synchronize { @refreshing = nil }
        failed(client_app, e.class.name)
      end

      def refresh(client_app)
        version = fetch(client_app)
        @mutex.synchronize do
          if version
            @version = version
            @failures = 0
            @next_at = @clock.call + @ttl
          else
            @failures += 1
            @next_at = @clock.call + [ @retry_after * (2**(@failures - 1)), @ttl ].min
          end
        end
      ensure
        @mutex.synchronize { @refreshing = nil }
      end

      def fetch(client_app)
        body = Timeout.timeout(@deadline) { download(client_app) }
        return nil if body.nil?

        result = JSON.parse(body)
        first = result.is_a?(Hash) && result["results"].is_a?(Array) && result["results"].first
        Version.parse(first.is_a?(Hash) ? first["version"] : nil) || failed(client_app, "no usable version")
      rescue StandardError => e
        failed(client_app, e.class.name)
      end

      # The body, or nil (after reporting) when the response can't be used.
      def download(client_app)
        target = uri
        Net::HTTP.start(target.host, target.port, use_ssl: true, open_timeout: @deadline, read_timeout: @deadline,
                                                  write_timeout: @deadline, ssl_timeout: @deadline) do |http|
          http.request(Net::HTTP::Get.new(target)) do |response|
            return failed(client_app, "HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)

            body = +""
            response.read_body do |chunk|
              body << chunk
              return failed(client_app, "response too large") if body.bytesize > MAX_BYTES
            end
            return body
          end
        end
      end

      def failed(client_app, reason)
        Reporting.instrument(:store_lookup_failed, store: "app_store", client: client_app&.name, reason: reason)
        nil
      end
    end
  end
end
