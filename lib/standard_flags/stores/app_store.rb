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
    # so an unreachable store is asked rarely; a runner that can't start
    # the refresh backs off the same way. Each fetch has an overall
    # `deadline:` (5 seconds) covering connect, TLS, request and body, with
    # each phase's own timeout a little shorter so net/http closes its
    # socket itself, and a body cap of 256 KiB read in chunks. The
    # connection is closed on every path. Failures emit
    # `store_lookup_failed.standard_flags` (`store`, `client`, `reason`)
    # after the fetch has ended, never inside its deadline; nothing raises.
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
      # the version known afterwards. A background refresh may run beside
      # it; the later answer wins.
      def refresh!(client_app = nil)
        refresh(client_app, claimed: false)
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
        @mutex.synchronize do
          @refreshing = nil
          back_off
        end
        failed(client_app, e.class.name)
      end

      def refresh(client_app, claimed: true)
        version = fetch(client_app)
        @mutex.synchronize do
          if version
            @version = version
            @failures = 0
            @next_at = @clock.call + @ttl
          else
            back_off
          end
        end
      ensure
        @mutex.synchronize { @refreshing = nil } if claimed
      end

      # Called under the lock.
      def back_off
        @failures += 1
        @next_at = @clock.call + [ @retry_after * (2**(@failures - 1)), @ttl ].min
      end

      # The version, or nil after reporting why. Reporting runs outside the
      # deadline, so a slow subscriber can't be interrupted by it.
      def fetch(client_app)
        outcome = begin
          Timeout.timeout(@deadline) { download }
        rescue Timeout::Error => e
          [ :failed, e.class.name ]
        end
        return failed(client_app, outcome.last) if outcome.first == :failed

        result = JSON.parse(outcome.last)
        first = result.is_a?(Hash) && result["results"].is_a?(Array) && result["results"].first
        Version.parse(first.is_a?(Hash) ? first["version"] : nil) || failed(client_app, "no usable version")
      rescue StandardError => e
        failed(client_app, e.class.name)
      end

      # `[:ok, body]` or `[:failed, reason]`. Reports nothing (it runs inside
      # the deadline). Net::HTTP.start's block form finishes the connection
      # on every way out; the phase timeouts sit below the deadline so a
      # stalled connect fails inside net/http, which closes its socket.
      def download
        target = uri
        phase = @deadline * 0.8
        Net::HTTP.start(target.host, target.port, use_ssl: true, open_timeout: phase, read_timeout: phase,
                                                  write_timeout: phase, ssl_timeout: phase) do |http|
          http.request(Net::HTTP::Get.new(target)) do |response|
            return [ :failed, "HTTP #{response.code}" ] unless response.is_a?(Net::HTTPSuccess)

            body = +""
            response.read_body do |chunk|
              body << chunk
              return [ :failed, "response too large" ] if body.bytesize > MAX_BYTES
            end
            return [ :ok, body ]
          end
        end
        [ :failed, "no response" ]
      rescue StandardError => e
        [ :failed, e.class.name ]
      end

      def failed(client_app, reason)
        Reporting.instrument(:store_lookup_failed, store: self.class.name, client: client_app&.name, reason: reason)
        nil
      end
    end
  end
end
