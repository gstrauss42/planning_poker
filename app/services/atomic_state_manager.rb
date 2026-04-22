# app/services/atomic_state_manager.rb
class AtomicStateManager
  SESSION_KEY = "estimation_session_state"
  ASYNC_SESSION_KEY = "estimation_async_session_state"
  PRESENCE_KEY = "estimation_session_presence"
  LOCK_KEY = "estimation_session_lock"
  SESSION_EXPIRY = 2.hours.to_i
  ASYNC_SESSION_EXPIRY = 2.days.to_i
  PRESENCE_EXPIRY = 2.minutes.to_i
  LOCK_TIMEOUT = 3.seconds.to_i
  MAX_RETRIES = 2

  class StateError < StandardError; end
  class LockTimeoutError < StandardError; end
  class VersionConflictError < StandardError; end

  class << self
    def redis
      return @redis if @redis

      Rails.logger.info "[AtomicState] Initializing Redis connection pool to: #{redis_url}"

      begin
        # Create Redis connection pool to prevent connection leaks
        require "connection_pool"

        @redis = ConnectionPool.new(size: 5, timeout: 5) do
          Redis.new(
            url: redis_url,
            timeout: 5,
            reconnect_attempts: 3
          )
        end

        # Test connection immediately
        Rails.logger.info "[AtomicState] Testing Redis connection..."
        @redis.with do |conn|
          ping_result = conn.ping
          Rails.logger.info "[AtomicState] Redis ping result: #{ping_result}"
        end

        # Clean up any stale locks on startup
        cleanup_stale_locks

        @redis
      rescue StandardError => e
        Rails.logger.error "=" * 80
        Rails.logger.error "🚨 REDIS CONNECTION FAILED - USING FALLBACK MODE 🚨"
        Rails.logger.error "=" * 80
        Rails.logger.error "[AtomicState] Redis connection failed: #{e.message}"
        Rails.logger.error "[AtomicState] Redis URL was: #{redis_url}"
        Rails.logger.error "[AtomicState] Error class: #{e.class}"
        Rails.logger.error "[AtomicState] Error backtrace: #{e.backtrace.first(5).join(', ')}"
        Rails.logger.error "=" * 80
        Rails.logger.error "⚠️  System will use Rails cache fallback for state management"
        Rails.logger.error "⚠️  Synchronization will work but with reduced atomic guarantees"
        Rails.logger.error "=" * 80
        @redis = nil
        nil
      end
    end

    # Properly close Redis connection
    def close_redis_connection
      if @redis
        begin
          # ConnectionPool shutdown requires a block, but we just want to close it
          # So we'll just set it to nil and let it be garbage collected
          Rails.logger.info "[AtomicState] Redis connection pool marked for cleanup"
        rescue StandardError => e
          Rails.logger.error "[AtomicState] Error closing Redis connection: #{e.message}"
        ensure
          @redis = nil
        end
      end
    end

    # Reset Redis connection (for testing or recovery)
    def reset_redis_connection
      Rails.logger.info "[AtomicState] Resetting Redis connection"
      close_redis_connection
      @redis = nil
    end

    def redis_url
      Rails.application.config.redis_url || "redis://localhost:6379/0"
    end

    # Helper method to execute Redis operations with connection pool
    def with_redis(&block)
      if redis_available?
        redis.with(&block)
      else
        raise StandardError, "Redis not available"
      end
    end

    def redis_available?
      Rails.logger.debug "[AtomicState] Checking Redis availability..."

      return false unless redis

      begin
        start_time = Time.current
        ping_result = nil
        redis.with do |conn|
          ping_result = conn.ping
        end
        latency = ((Time.current - start_time) * 1000).round(2)

        Rails.logger.debug "[AtomicState] Redis ping: #{ping_result}, latency: #{latency}ms"

        if ping_result == "PONG"
          Rails.logger.debug "[AtomicState] Redis is available"
          true
        else
          Rails.logger.warn "[AtomicState] Redis ping returned unexpected result: #{ping_result}"
          false
        end
      rescue StandardError => e
        Rails.logger.error "=" * 60
        Rails.logger.error "🚨 REDIS BECAME UNAVAILABLE - SWITCHING TO FALLBACK 🚨"
        Rails.logger.error "=" * 60
        Rails.logger.error "[AtomicState] Redis ping failed: #{e.message}"
        Rails.logger.error "[AtomicState] Redis error class: #{e.class}"
        Rails.logger.error "=" * 60
        false
      end
    end

    # Atomic state operations with locking and fallback
    def atomic_update(operation_name, &block)
      # Always try Redis first, but fail fast to fallback
      if redis_available?
        lock_acquired = false
        begin
          # Quick lock attempt with timeout
          lock_acquired = acquire_lock(operation_name)
          if lock_acquired
            Rails.logger.debug "[AtomicState] Lock acquired for #{operation_name}"
            result = block.call
            Rails.logger.info "[AtomicState] #{operation_name} completed with Redis"
            result
          else
            Rails.logger.warn "[AtomicState] Lock timeout for #{operation_name}, using fallback"
            fallback_update(operation_name, &block)
          end
        rescue StandardError => e
          Rails.logger.warn "[AtomicState] Redis error in #{operation_name}: #{e.message}, using fallback"
          fallback_update(operation_name, &block)
        ensure
          # Always release lock if we acquired it
          if lock_acquired && redis_available?
            Rails.logger.debug "[AtomicState] Releasing lock for #{operation_name}"
            release_lock(operation_name)
          end
        end
      else
        Rails.logger.warn "[AtomicState] Redis unavailable, using fallback for #{operation_name}"
        fallback_update(operation_name, &block)
      end
    end

    def fallback_update(operation_name, &block)
      Rails.logger.warn "[AtomicState] Using fallback for #{operation_name}"

      begin
        result = block.call
        Rails.logger.info "[AtomicState] #{operation_name} completed via fallback"
        result
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Fallback error in #{operation_name}: #{e.message}"
        raise StateError, "Fallback operation failed: #{e.message}"
      end
    end

    def get_state
      if redis_available?
        state_data = with_redis { |conn| conn.get(SESSION_KEY) }
        if state_data
          JSON.parse(state_data, symbolize_names: true)
        else
          default_state
        end
      else
        # Fallback to Rails cache
        Rails.cache.read(SESSION_KEY) || default_state
      end
    rescue JSON::ParserError => e
      Rails.logger.error "[AtomicState] Failed to parse state: #{e.message}"
      default_state
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error getting state: #{e.message}, using fallback"
      Rails.cache.read(SESSION_KEY) || default_state
    end

    def set_ticket(ticket_data, ticket_title)
      atomic_update("set_ticket") do
        current_state = get_state
        new_state = current_state.dup
        new_state[:ticket_data] = ticket_data
        new_state[:ticket_title] = ticket_title
        new_state[:ticket_id] = ticket_data ? ticket_data[:key] : nil
        new_state[:votes] = {}
        new_state[:revealed] = false
        new_state[:version] = current_state[:version] + 1
        new_state[:last_updated] = Time.current.to_i

        save_state(new_state)
        broadcast_state_change("ticket_set", new_state)
        new_state
      end
    end

    # Set multiple tickets and initialize multi-ticket state
    def set_tickets(tickets_array)
      atomic_update("set_tickets") do
        current_state = get_state
        new_state = current_state.dup

        # Store array of all tickets
        new_state[:tickets] = tickets_array
        new_state[:current_ticket_index] = 0

        # Initialize votes_by_ticket if not present
        new_state[:votes_by_ticket] ||= {}
        new_state[:revealed_by_ticket] ||= {}

        # Set current ticket to first in array
        if tickets_array.any?
          first_ticket = tickets_array[0]
          new_state[:ticket_data] = first_ticket
          new_state[:ticket_title] = first_ticket[:formatted_title]
          new_state[:ticket_id] = first_ticket[:key]

          # Load votes for this ticket if any
          new_state[:votes] = new_state[:votes_by_ticket][first_ticket[:key]] || {}
          new_state[:revealed] = new_state[:revealed_by_ticket][first_ticket[:key]] || false
        else
          new_state[:ticket_data] = nil
          new_state[:ticket_title] = nil
          new_state[:ticket_id] = nil
          new_state[:votes] = {}
          new_state[:revealed] = false
        end

        new_state[:version] = current_state[:version] + 1
        new_state[:last_updated] = Time.current.to_i

        save_state(new_state)
        broadcast_state_change("tickets_loaded", new_state)
        new_state
      end
    end

    # Navigate to a specific ticket by index
    def set_current_ticket(index, expected_version = nil)
      atomic_update("set_current_ticket") do
        current_state = get_state

        # Version conflict check
        if expected_version && current_state[:version] != expected_version
          raise VersionConflictError, "Version mismatch: expected #{expected_version}, got #{current_state[:version]}"
        end

        tickets = current_state[:tickets] || []
        return current_state if tickets.empty? || index < 0 || index >= tickets.length

        new_state = current_state.dup

        # Save current ticket's votes before switching
        if current_state[:ticket_id]
          new_state[:votes_by_ticket] = (current_state[:votes_by_ticket] || {}).dup
          new_state[:votes_by_ticket][current_state[:ticket_id]] = current_state[:votes]

          new_state[:revealed_by_ticket] = (current_state[:revealed_by_ticket] || {}).dup
          new_state[:revealed_by_ticket][current_state[:ticket_id]] = current_state[:revealed]
        end

        # Switch to new ticket
        new_state[:current_ticket_index] = index
        new_ticket = tickets[index]
        new_state[:ticket_data] = new_ticket
        new_state[:ticket_title] = new_ticket[:formatted_title]
        new_state[:ticket_id] = new_ticket[:key]

        # Load votes for new ticket
        new_state[:votes] = new_state[:votes_by_ticket][new_ticket[:key]] || {}
        new_state[:revealed] = new_state[:revealed_by_ticket][new_ticket[:key]] || false

        new_state[:version] = current_state[:version] + 1
        new_state[:last_updated] = Time.current.to_i

        save_state(new_state)
        broadcast_state_change("ticket_changed", new_state)
        new_state
      end
    end

    def add_vote(user_name, points, expected_version = nil)
      atomic_update("add_vote") do
        current_state = get_state

        # Version conflict check
        if expected_version && current_state[:version] != expected_version
          raise VersionConflictError, "Version mismatch: expected #{expected_version}, got #{current_state[:version]}"
        end

        new_state = current_state.dup
        new_state[:votes] = current_state[:votes].dup
        new_state[:votes][user_name] = points
        new_state[:version] = current_state[:version] + 1
        new_state[:last_updated] = Time.current.to_i

        # Note: User-connection mapping is handled automatically when users connect
        # via the add_connection method, so we don't need to update it here

        save_state(new_state)
        broadcast_state_change("vote_added", new_state)
        new_state
      end
    end

    def reveal_votes(expected_version = nil)
      atomic_update("reveal_votes") do
        current_state = get_state

        if expected_version && current_state[:version] != expected_version
          raise VersionConflictError, "Version mismatch: expected #{expected_version}, got #{current_state[:version]}"
        end

        return current_state if current_state[:votes].empty?

        new_state = current_state.dup
        new_state[:revealed] = true
        new_state[:version] = current_state[:version] + 1
        new_state[:last_updated] = Time.current.to_i

        save_state(new_state)
        broadcast_state_change("votes_revealed", new_state)
        new_state
      end
    end

    def remove_ticket(ticket_id)
      atomic_update("remove_ticket") do
        current_state = get_state
        tickets = current_state[:tickets] || []
        tid = ticket_id.to_s

        index = tickets.find_index { |t| t[:key].to_s == tid }
        return current_state if index.nil?

        new_state = current_state.dup
        new_tickets = tickets.dup
        new_tickets.delete_at(index)
        new_state[:tickets] = new_tickets

        new_state[:votes_by_ticket] = (current_state[:votes_by_ticket] || {}).dup
        new_state[:votes_by_ticket].delete(tid)
        new_state[:votes_by_ticket].delete(tid.to_sym)

        new_state[:revealed_by_ticket] = (current_state[:revealed_by_ticket] || {}).dup
        new_state[:revealed_by_ticket].delete(tid)
        new_state[:revealed_by_ticket].delete(tid.to_sym)

        current_index = current_state[:current_ticket_index] || 0

        if new_tickets.empty?
          new_state[:current_ticket_index] = 0
          new_state[:ticket_data] = nil
          new_state[:ticket_title] = nil
          new_state[:ticket_id] = nil
          new_state[:votes] = {}
          new_state[:revealed] = false
        elsif index == current_index
          new_index = [ current_index, new_tickets.length - 1 ].min
          new_current = new_tickets[new_index]
          key_sym = new_current[:key].to_s.to_sym

          new_state[:current_ticket_index] = new_index
          new_state[:ticket_data] = new_current
          new_state[:ticket_title] = new_current[:formatted_title]
          new_state[:ticket_id] = new_current[:key]
          new_state[:votes] = new_state[:votes_by_ticket][new_current[:key].to_s] ||
                              new_state[:votes_by_ticket][key_sym] || {}
          new_state[:revealed] = new_state[:revealed_by_ticket][new_current[:key].to_s] ||
                                 new_state[:revealed_by_ticket][key_sym] || false
        else
          # Removed a non-current ticket; keep live view but shift index if needed
          new_state[:current_ticket_index] = index < current_index ? current_index - 1 : current_index
        end

        new_state[:version] = (current_state[:version] || 0) + 1
        new_state[:last_updated] = Time.current.to_i

        save_state(new_state)
        broadcast_state_change("ticket_removed", new_state)
        new_state
      end
    end

    def clear_tickets
      atomic_update("clear_tickets") do
        current_state = get_state
        new_state = current_state.dup
        new_state[:tickets] = []
        new_state[:current_ticket_index] = 0
        new_state[:votes_by_ticket] = {}
        new_state[:revealed_by_ticket] = {}
        new_state[:ticket_data] = nil
        new_state[:ticket_title] = nil
        new_state[:ticket_id] = nil
        new_state[:votes] = {}
        new_state[:revealed] = false
        new_state[:version] = (current_state[:version] || 0) + 1
        new_state[:last_updated] = Time.current.to_i

        save_state(new_state)
        broadcast_state_change("tickets_cleared", new_state)
        new_state
      end
    end

    def clear_votes(expected_version = nil)
      Rails.logger.info "[AtomicState] clear_votes called with expected_version: #{expected_version}"

      atomic_update("clear_votes") do
        current_state = get_state
        Rails.logger.info "[AtomicState] Current state version: #{current_state[:version]}, votes count: #{current_state[:votes]&.count || 0}"

        if expected_version && current_state[:version] != expected_version
          Rails.logger.warn "[AtomicState] Version conflict: expected #{expected_version}, got #{current_state[:version]}"
          raise VersionConflictError, "Version mismatch: expected #{expected_version}, got #{current_state[:version]}"
        end

        new_state = current_state.dup
        new_state[:votes] = {}
        new_state[:revealed] = false
        new_state[:version] = current_state[:version] + 1
        new_state[:last_updated] = Time.current.to_i

        Rails.logger.info "[AtomicState] New state version: #{new_state[:version]}, votes cleared"

        save_state(new_state)
        broadcast_state_change("votes_cleared", new_state)
        new_state
      end
    end

    def set_async_tickets(tickets_array)
      atomic_update("set_async_tickets") do
        async_state = get_async_state
        async_state[:async_tickets] = tickets_array
        async_state[:async_votes_by_ticket] ||= {}
        async_state[:async_revealed_by_ticket] ||= {}
        async_state[:version] = (async_state[:version] || 0) + 1
        async_state[:last_updated] = Time.current.to_i

        save_async_state(async_state)
        broadcast_state_change("async_tickets_loaded", async_state)
        async_state
      end
    end

    def add_async_ticket(ticket_data)
      atomic_update("add_async_ticket") do
        async_state = get_async_state
        async_state[:async_tickets] = (async_state[:async_tickets] || []).dup
        unless async_state[:async_tickets].any? { |t| t[:key] == ticket_data[:key] }
          async_state[:async_tickets] << ticket_data
        end
        async_state[:version] = (async_state[:version] || 0) + 1
        async_state[:last_updated] = Time.current.to_i

        save_async_state(async_state)
        broadcast_state_change("async_ticket_added", async_state)
        async_state
      end
    end

    def add_vote_for_ticket(ticket_id, user_name, points)
      atomic_update("add_vote_for_ticket") do
        async_state = get_async_state
        tid = ticket_id.to_s

        avbt = (async_state[:async_votes_by_ticket] || {}).dup
        existing = avbt[tid] || avbt[tid.to_sym] || {}
        ticket_votes = existing.dup
        ticket_votes[user_name] = points
        avbt[tid] = ticket_votes
        async_state[:async_votes_by_ticket] = avbt
        async_state[:version] = (async_state[:version] || 0) + 1
        async_state[:last_updated] = Time.current.to_i

        save_async_state(async_state)
        broadcast_state_change("async_vote_added", async_state)
        async_state
      end
    end

    def reveal_votes_for_ticket(ticket_id)
      atomic_update("reveal_votes_for_ticket") do
        async_state = get_async_state
        tid = ticket_id.to_s

        avbt = async_state[:async_votes_by_ticket] || {}
        ticket_votes = avbt[tid] || avbt[tid.to_sym] || {}
        return async_state if ticket_votes.empty?

        async_state[:async_revealed_by_ticket] = (async_state[:async_revealed_by_ticket] || {}).dup
        async_state[:async_revealed_by_ticket][tid] = true
        async_state[:version] = (async_state[:version] || 0) + 1
        async_state[:last_updated] = Time.current.to_i

        save_async_state(async_state)
        broadcast_state_change("async_votes_revealed", async_state)
        async_state
      end
    end

    def clear_votes_for_ticket(ticket_id)
      atomic_update("clear_votes_for_ticket") do
        async_state = get_async_state
        tid = ticket_id.to_s

        async_state[:async_votes_by_ticket] = (async_state[:async_votes_by_ticket] || {}).dup
        async_state[:async_votes_by_ticket][tid] = {}
        async_state[:async_revealed_by_ticket] = (async_state[:async_revealed_by_ticket] || {}).dup
        async_state[:async_revealed_by_ticket][tid] = false
        async_state[:version] = (async_state[:version] || 0) + 1
        async_state[:last_updated] = Time.current.to_i

        save_async_state(async_state)
        broadcast_state_change("async_votes_cleared", async_state)
        async_state
      end
    end

    def remove_async_ticket(ticket_id)
      atomic_update("remove_async_ticket") do
        async_state = get_async_state
        tickets = async_state[:async_tickets] || []
        tid = ticket_id.to_s

        index = tickets.find_index { |t| t[:key].to_s == tid }
        return async_state if index.nil?

        new_tickets = tickets.dup
        new_tickets.delete_at(index)
        async_state[:async_tickets] = new_tickets

        avbt = (async_state[:async_votes_by_ticket] || {}).dup
        avbt.delete(tid)
        avbt.delete(tid.to_sym)
        async_state[:async_votes_by_ticket] = avbt

        arbt = (async_state[:async_revealed_by_ticket] || {}).dup
        arbt.delete(tid)
        arbt.delete(tid.to_sym)
        async_state[:async_revealed_by_ticket] = arbt

        async_state[:version] = (async_state[:version] || 0) + 1
        async_state[:last_updated] = Time.current.to_i

        save_async_state(async_state)
        broadcast_state_change("async_ticket_removed", async_state)
        async_state
      end
    end

    def clear_async_tickets
      atomic_update("clear_async_tickets") do
        async_state = get_async_state
        async_state[:async_tickets] = []
        async_state[:async_votes_by_ticket] = {}
        async_state[:async_revealed_by_ticket] = {}
        async_state[:version] = (async_state[:version] || 0) + 1
        async_state[:last_updated] = Time.current.to_i

        save_async_state(async_state)
        broadcast_state_change("async_tickets_cleared", async_state)
        async_state
      end
    end

    def clear_all
      atomic_update("clear_all") do
        with_redis do |conn|
          conn.del(SESSION_KEY)
          conn.del(ASYNC_SESSION_KEY)
          conn.del(PRESENCE_KEY)
        end
        default_state
      end
    end

    # Enhanced presence tracking
    def add_connection(connection_id)
      # Connection management doesn't need atomic operations
      begin
        presence = get_presence
        presence[connection_id] = {
          last_seen: Time.current.to_i,
          connected_at: Time.current.to_i,
          heartbeat_count: 0,
          user_name: nil  # Will be set when user votes
        }
        save_presence(presence)
        cleanup_stale_connections
        Rails.logger.info "[AtomicState] Connection added: #{connection_id}"
        presence
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Add connection error: #{e.message}"
        {}
      end
    end

    def remove_connection(connection_id)
      # Connection management doesn't need atomic operations
      begin
        presence = get_presence
        presence.delete(connection_id)
        save_presence(presence)
        Rails.logger.info "[AtomicState] Connection removed: #{connection_id}"
        presence
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Remove connection error: #{e.message}"
        {}
      end
    end

    def heartbeat(connection_id)
      # Heartbeat doesn't need atomic operations - it's just updating presence
      begin
        presence = get_presence
        if presence[connection_id]
          presence[connection_id][:last_seen] = Time.current.to_i
          presence[connection_id][:heartbeat_count] += 1
          save_presence(presence)

          # Cleanup every 50 heartbeats (less frequent to reduce server load)
          if presence[connection_id][:heartbeat_count] % 50 == 0
            cleanup_stale_connections
          end
        end
        presence
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Heartbeat error: #{e.message}"
        # Don't raise - heartbeat failures shouldn't break the connection
        {}
      end
    end

    def cleanup_stale_connections
      # Cleanup doesn't need atomic operations - it's just removing stale data
      begin
        # Rate limiting: only cleanup once per minute per process
        cleanup_key = "cleanup_last_run_#{Process.pid}"
        if redis_available?
          last_cleanup = with_redis { |conn| conn.get(cleanup_key) }
          if last_cleanup && (Time.current.to_i - last_cleanup.to_i) < 60
            Rails.logger.debug "[AtomicState] Cleanup rate limited, skipping"
            return get_presence
          end
          with_redis { |conn| conn.setex(cleanup_key, 120, Time.current.to_i) }
        end

        presence = get_presence
        current_time = Time.current.to_i

        stale_connections = presence.select do |_id, data|
          current_time - data[:last_seen] > PRESENCE_EXPIRY
        end

        if stale_connections.any?
          stale_connections.each do |id, data|
            Rails.logger.info "[AtomicState] Cleaning up stale connection: #{id} (user: #{data[:user_name]})"
            presence.delete(id)
          end
          save_presence(presence)
        end

        presence
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Cleanup error: #{e.message}"
        # Don't raise - cleanup failures shouldn't break the system
        {}
      end
    end

    def update_user_connection_mapping(user_name)
      # Find the most recent connection (assuming it's the current user)
      presence = get_presence
      most_recent_connection = presence.max_by { |_id, data| data[:last_seen] }

      if most_recent_connection
        connection_id, data = most_recent_connection
        data[:user_name] = user_name
        save_presence(presence)
        Rails.logger.info "[AtomicState] Mapped user '#{user_name}' to connection #{connection_id}"
      end
    end

    def connected_count
      # Simple count doesn't need atomic operations
      begin
        get_presence.count
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Connected count error: #{e.message}"
        0
      end
    end

    def voted_count
      get_state[:votes].count
    end

    def get_broadcast_state
      state = get_state
      async_state = get_async_state
      presence = get_presence

      Rails.logger.debug "[AtomicState] Getting broadcast state - Redis available: #{redis_available?}"
      Rails.logger.debug "[AtomicState] Current votes: #{state[:votes].keys.join(', ')}"
      Rails.logger.debug "[AtomicState] Current presence: #{presence.keys.join(', ')}"

      connected_count = presence.count
      voted_count = state[:votes].count

      Rails.logger.debug "[AtomicState] Final votes for broadcast: #{state[:votes].keys.join(', ')}"
      Rails.logger.debug "[AtomicState] Connected count: #{connected_count}, Voted count: #{voted_count}"
      Rails.logger.debug "[AtomicState] Ticket data attachments: #{state[:ticket_data]&.dig(:attachments)&.count || 0}"

      {
        ticket_data: state[:ticket_data],
        ticket_title: state[:ticket_title],
        ticket_id: state[:ticket_id],
        votes: state[:votes],
        revealed: state[:revealed],
        tickets: state[:tickets] || [],
        current_ticket_index: state[:current_ticket_index] || 0,
        votes_by_ticket: state[:votes_by_ticket] || {},
        revealed_by_ticket: state[:revealed_by_ticket] || {},
        async_tickets: async_state[:async_tickets] || [],
        async_votes_by_ticket: async_state[:async_votes_by_ticket] || {},
        async_revealed_by_ticket: async_state[:async_revealed_by_ticket] || {},
        connected_count: connected_count,
        voted_count: voted_count,
        version: state[:version],
        last_updated: state[:last_updated],
        session_health: calculate_session_health(state, presence)
      }
    end

    def cleanup_stale_votes
      # Separate method for cleaning up votes from disconnected users
      # This should be called periodically, not during vote operations
      Rails.logger.info "[AtomicState] Starting periodic vote cleanup"

      state = get_state
      presence = get_presence

      if redis_available? && presence.count > 0
        # Get user names from currently connected users
        connected_user_names = presence.values.map { |data| data[:user_name] }.compact

        # Only count votes from currently connected users
        current_votes = state[:votes].select { |user_name, _| connected_user_names.include?(user_name) }

        # Clean up votes from disconnected users
        if current_votes.count != state[:votes].count
          removed_count = state[:votes].count - current_votes.count
          Rails.logger.info "[AtomicState] Periodic cleanup: removing #{removed_count} vote(s) from disconnected users"

          new_state = state.dup
          new_state[:votes] = current_votes
          new_state[:version] = state[:version] + 1
          new_state[:last_updated] = Time.current.to_i

          save_state(new_state)
          broadcast_state_change("votes_cleaned", new_state)

          Rails.logger.info "[AtomicState] Periodic cleanup completed: #{state[:votes].count} -> #{current_votes.count} votes"
        else
          Rails.logger.debug "[AtomicState] Periodic cleanup: no votes to remove"
        end
      else
        Rails.logger.warn "[AtomicState] Periodic cleanup skipped: Redis unavailable or no connected users"
      end
    end

    def validate_state_integrity
      state = get_state
      presence = get_presence

      issues = []

      # Check for version consistency
      if state[:version] < 0
        issues << "Invalid version number: #{state[:version]}"
      end

      # Check for orphaned votes
      if state[:votes].any? && !state[:ticket_data]
        issues << "Votes exist without ticket data"
      end

      # Check for revealed votes without votes
      if state[:revealed] && state[:votes].empty?
        issues << "Revealed state without votes"
      end

      # Check presence consistency
      if presence.count < 0
        issues << "Invalid presence count: #{presence.count}"
      end

      issues
    end

    # Cleanup Redis connections (called by health monitor)
    def cleanup_redis_connections
      begin
        # Log current Redis client count if possible before cleanup
        if redis_available?
          info = with_redis { |conn| conn.info("clients") }
          Rails.logger.info "[AtomicState] Redis client info before cleanup: #{info}"
        end

        # Force close and reset Redis connection to prevent leaks
        reset_redis_connection

        Rails.logger.info "[AtomicState] Redis connection cleanup completed"
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Error during Redis connection cleanup: #{e.message}"
      end
    end

    # Cleanup method for application shutdown
    def cleanup_on_shutdown
      Rails.logger.info "[AtomicState] Cleaning up Redis connections on shutdown"
      cleanup_redis_connections
    end

    private

    def acquire_lock(operation_name)
      return false unless redis_available?

      lock_key = "#{LOCK_KEY}:#{operation_name}"
      lock_value = "#{Process.pid}:#{Thread.current.object_id}:#{Time.current.to_f}"

      # Try to acquire lock with expiration
      result = with_redis { |conn| conn.set(lock_key, lock_value, nx: true, ex: LOCK_TIMEOUT) }
      result == "OK"
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error acquiring lock: #{e.message}"
      false
    end

    def release_lock(operation_name)
      return unless redis_available?

      lock_key = "#{LOCK_KEY}:#{operation_name}"
      result = with_redis { |conn| conn.del(lock_key) }
      Rails.logger.debug "[AtomicState] Lock release result for #{operation_name}: #{result}"
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error releasing lock for #{operation_name}: #{e.message}"
      # Try to force release the lock by setting it to expire immediately
      begin
        with_redis { |conn| conn.expire(lock_key, 0) }
        Rails.logger.warn "[AtomicState] Force-expired lock for #{operation_name}"
      rescue StandardError => force_error
        Rails.logger.error "[AtomicState] Failed to force-expire lock: #{force_error.message}"
      end
    end

    def cleanup_stale_locks
      return unless redis_available?

      begin
        # Get all lock keys
        lock_keys = with_redis { |conn| conn.keys("#{LOCK_KEY}:*") }
        Rails.logger.debug "[AtomicState] Found #{lock_keys.count} lock keys"

        lock_keys.each do |lock_key|
          # Check if lock is still valid (not expired)
          ttl = with_redis { |conn| conn.ttl(lock_key) }
          if ttl == -1
            # Lock exists but has no expiration - this is a stale lock
            Rails.logger.warn "[AtomicState] Found stale lock without expiration: #{lock_key}"
            with_redis { |conn| conn.del(lock_key) }
          elsif ttl > 0
            Rails.logger.debug "[AtomicState] Lock #{lock_key} expires in #{ttl} seconds"
          end
        end
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Error cleaning up stale locks: #{e.message}"
      end
    end



    def get_async_state
      if redis_available?
        data = with_redis { |conn| conn.get(ASYNC_SESSION_KEY) }
        if data
          JSON.parse(data, symbolize_names: true)
        else
          migrate_legacy_async_state || default_async_state
        end
      else
        Rails.cache.read(ASYNC_SESSION_KEY) || default_async_state
      end
    rescue JSON::ParserError => e
      Rails.logger.error "[AtomicState] Failed to parse async state: #{e.message}"
      default_async_state
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error getting async state: #{e.message}, using fallback"
      Rails.cache.read(ASYNC_SESSION_KEY) || default_async_state
    end

    def save_async_state(async_state)
      if redis_available?
        with_redis { |conn| conn.setex(ASYNC_SESSION_KEY, ASYNC_SESSION_EXPIRY, async_state.to_json) }
      else
        Rails.cache.write(ASYNC_SESSION_KEY, async_state, expires_in: ASYNC_SESSION_EXPIRY.seconds)
      end
      async_state
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error saving async state: #{e.message}, using fallback"
      Rails.cache.write(ASYNC_SESSION_KEY, async_state, expires_in: ASYNC_SESSION_EXPIRY.seconds)
      async_state
    end

    # One-time migration: pull async data from the legacy combined session key
    # into the dedicated async key. Runs once on first async read after deploy.
    def migrate_legacy_async_state
      legacy = get_state
      has_legacy = legacy[:async_tickets]&.any? ||
                   legacy[:async_votes_by_ticket]&.any? ||
                   legacy[:async_revealed_by_ticket]&.any?
      return nil unless has_legacy

      Rails.logger.info "[AtomicState] Migrating legacy async data to dedicated key"
      migrated = {
        async_tickets: legacy[:async_tickets] || [],
        async_votes_by_ticket: legacy[:async_votes_by_ticket] || {},
        async_revealed_by_ticket: legacy[:async_revealed_by_ticket] || {},
        version: 0,
        last_updated: Time.current.to_i
      }
      save_async_state(migrated)
      migrated
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Legacy async migration failed: #{e.message}"
      nil
    end

    def save_state(state)
      Rails.logger.debug "[AtomicState] Saving state version #{state[:version]}"

      if redis_available?
        Rails.logger.debug "[AtomicState] Using Redis to save state"
        start_time = Time.current
        with_redis { |conn| conn.setex(SESSION_KEY, SESSION_EXPIRY, state.to_json) }
        save_time = ((Time.current - start_time) * 1000).round(2)
        Rails.logger.debug "[AtomicState] Redis save completed in #{save_time}ms"
      else
        Rails.logger.warn "[AtomicState] Redis unavailable, using Rails cache fallback"
        Rails.cache.write(SESSION_KEY, state, expires_in: SESSION_EXPIRY.seconds)
      end
      state
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error saving state: #{e.message}"
      Rails.logger.error "[AtomicState] Save error class: #{e.class}"
      Rails.logger.warn "[AtomicState] Falling back to Rails cache"
      Rails.cache.write(SESSION_KEY, state, expires_in: SESSION_EXPIRY.seconds)
      state
    end

    def save_presence(presence)
      if redis_available?
        with_redis { |conn| conn.setex(PRESENCE_KEY, SESSION_EXPIRY, presence.to_json) }
      else
        # Fallback to Rails cache
        Rails.cache.write(PRESENCE_KEY, presence, expires_in: SESSION_EXPIRY.seconds)
      end
      presence
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error saving presence: #{e.message}, using fallback"
      Rails.cache.write(PRESENCE_KEY, presence, expires_in: SESSION_EXPIRY.seconds)
      presence
    end

    def get_presence
      if redis_available?
        presence_data = with_redis { |conn| conn.get(PRESENCE_KEY) }
        if presence_data
          JSON.parse(presence_data, symbolize_names: true)
        else
          {}
        end
      else
        # Fallback to Rails cache
        Rails.cache.read(PRESENCE_KEY) || {}
      end
    rescue JSON::ParserError => e
      Rails.logger.error "[AtomicState] Failed to parse presence: #{e.message}"
      {}
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error getting presence: #{e.message}, using fallback"
      Rails.cache.read(PRESENCE_KEY) || {}
    end

    def default_state
      {
        ticket_data: nil,
        ticket_title: nil,
        ticket_id: nil,
        votes: {},
        revealed: false,
        tickets: [],
        current_ticket_index: 0,
        votes_by_ticket: {},
        revealed_by_ticket: {},
        version: 0,
        last_updated: Time.current.to_i
      }
    end

    def default_async_state
      {
        async_tickets: [],
        async_votes_by_ticket: {},
        async_revealed_by_ticket: {},
        version: 0,
        last_updated: Time.current.to_i
      }
    end

    def broadcast_state_change(action, state)
      Rails.logger.info "[AtomicState] Broadcasting #{action}, version: #{state[:version]}"

      begin
        broadcast_state = get_broadcast_state

        # Check if state has actually changed to avoid unnecessary broadcasts
        last_broadcast_key = "last_broadcast_state"
        last_broadcast_state = nil

        if redis_available?
          last_broadcast_state = with_redis { |conn| conn.get(last_broadcast_key) }
        end

        # Only broadcast if state has actually changed
        current_state_hash = Digest::MD5.hexdigest(broadcast_state.to_json)
        if last_broadcast_state == current_state_hash
          Rails.logger.debug "[AtomicState] State unchanged, skipping broadcast for #{action}"
          return
        end

        # Store current state hash for comparison
        if redis_available?
          with_redis { |conn| conn.setex(last_broadcast_key, 300, current_state_hash) } # 5 minute expiry
        end

        # Send multiple broadcasts with slight delays to ensure delivery
        broadcast_message = {
          action: "sync_state",
          state: broadcast_state,
          change_action: action,
          timestamp: Time.current.to_i,
          broadcast_id: SecureRandom.uuid
        }

        # Primary broadcast
        ActionCable.server.broadcast("estimation_session", broadcast_message)

        # Secondary broadcast after 100ms for reliability
        Thread.new do
          sleep(0.1)
          ActionCable.server.broadcast("estimation_session", broadcast_message.merge(
            action: "sync_state_retry",
            retry: true
          ))
        end

        Rails.logger.info "[AtomicState] Broadcast sent for #{action} (primary + retry)"

      rescue StandardError => e
        Rails.logger.error "[AtomicState] Broadcast error for #{action}: #{e.message}"
      end
    end

    def calculate_session_health(state, presence)
      health_score = 100

      # Deduct points for various issues
      if state[:version] == 0 && presence.count > 0
        health_score -= 20  # Session exists but no activity
      end

      if presence.count == 0 && state[:votes].any?
        health_score -= 30  # Votes without connections
      end

      if state[:last_updated] && (Time.current.to_i - state[:last_updated]) > 300
        health_score -= 10  # Stale session
      end

      [ health_score, 0 ].max
    end
  end
end
