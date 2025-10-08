# app/services/atomic_state_manager.rb
class AtomicStateManager
  SESSION_KEY = "estimation_session_state"
  PRESENCE_KEY = "estimation_session_presence"
  LOCK_KEY = "estimation_session_lock"
  SESSION_EXPIRY = 2.hours.to_i  # Extended for 1.5 hour sessions
  PRESENCE_EXPIRY = 2.minutes.to_i  # More generous presence tracking
  LOCK_TIMEOUT = 5.seconds.to_i
  MAX_RETRIES = 3

  class StateError < StandardError; end
  class LockTimeoutError < StandardError; end
  class VersionConflictError < StandardError; end

  class << self
    def redis
      @redis ||= begin
        Redis.new(url: redis_url, timeout: 2, reconnect_attempts: 2)
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Redis connection failed: #{e.message}"
        nil
      end
    end

    def redis_url
      Rails.application.config.redis_url || "redis://localhost:6379/0"
    end

    def redis_available?
      return false unless redis
      
      begin
        redis.ping == "PONG"
      rescue StandardError
        false
      end
    end

    # Atomic state operations with locking and fallback
    def atomic_update(operation_name, &block)
      # If Redis is not available, fall back to non-atomic operations
      unless redis_available?
        Rails.logger.warn "[AtomicState] Redis unavailable, using fallback for #{operation_name}"
        return fallback_update(operation_name, &block)
      end
      
      retries = 0
      
      begin
        lock_acquired = acquire_lock(operation_name)
        raise LockTimeoutError, "Failed to acquire lock for #{operation_name}" unless lock_acquired
        
        result = block.call
        Rails.logger.info "[AtomicState] #{operation_name} completed successfully"
        result
      rescue LockTimeoutError => e
        retries += 1
        if retries < MAX_RETRIES
          Rails.logger.warn "[AtomicState] Lock timeout for #{operation_name}, retry #{retries}/#{MAX_RETRIES}"
          sleep(0.1 * retries) # Exponential backoff
          retry
        else
          Rails.logger.error "[AtomicState] Max retries exceeded for #{operation_name}, falling back"
          return fallback_update(operation_name, &block)
        end
      rescue StandardError => e
        Rails.logger.error "[AtomicState] Error in #{operation_name}: #{e.message}, falling back"
        return fallback_update(operation_name, &block)
      ensure
        release_lock(operation_name) if redis_available?
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
        state_data = redis.get(SESSION_KEY)
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

    def clear_votes(expected_version = nil)
      atomic_update("clear_votes") do
        current_state = get_state
        
        if expected_version && current_state[:version] != expected_version
          raise VersionConflictError, "Version mismatch: expected #{expected_version}, got #{current_state[:version]}"
        end
        
        new_state = current_state.dup
        new_state[:votes] = {}
        new_state[:revealed] = false
        new_state[:version] = current_state[:version] + 1
        new_state[:last_updated] = Time.current.to_i
        
        save_state(new_state)
        broadcast_state_change("votes_cleared", new_state)
        new_state
      end
    end

    def clear_all
      atomic_update("clear_all") do
        redis.del(SESSION_KEY)
        redis.del(PRESENCE_KEY)
        default_state
      end
    end

    # Enhanced presence tracking
    def add_connection(connection_id)
      atomic_update("add_connection") do
        presence = get_presence
        presence[connection_id] = {
          last_seen: Time.current.to_i,
          connected_at: Time.current.to_i,
          heartbeat_count: 0
        }
        save_presence(presence)
        cleanup_stale_connections
        Rails.logger.info "[AtomicState] Connection added: #{connection_id}"
        presence
      end
    end

    def remove_connection(connection_id)
      atomic_update("remove_connection") do
        presence = get_presence
        presence.delete(connection_id)
        save_presence(presence)
        Rails.logger.info "[AtomicState] Connection removed: #{connection_id}"
        presence
      end
    end

    def heartbeat(connection_id)
      atomic_update("heartbeat") do
        presence = get_presence
        if presence[connection_id]
          presence[connection_id][:last_seen] = Time.current.to_i
          presence[connection_id][:heartbeat_count] += 1
          save_presence(presence)
          
          # Cleanup every 20 heartbeats (more frequent)
          if presence[connection_id][:heartbeat_count] % 20 == 0
            cleanup_stale_connections
          end
        end
        presence
      end
    end

    def cleanup_stale_connections
      presence = get_presence
      current_time = Time.current.to_i
      
      stale_connections = presence.select do |_id, data|
        current_time - data[:last_seen] > PRESENCE_EXPIRY
      end
      
      if stale_connections.any?
        stale_connections.each do |id, _data|
          presence.delete(id)
          Rails.logger.info "[AtomicState] Cleaned up stale connection: #{id}"
        end
        save_presence(presence)
      end
      
      presence
    end

    def connected_count
      cleanup_stale_connections.count
    end

    def voted_count
      get_state[:votes].count
    end

    def get_broadcast_state
      state = get_state
      presence = get_presence
      
      {
        ticket_data: state[:ticket_data],
        ticket_title: state[:ticket_title],
        ticket_id: state[:ticket_id],
        votes: state[:votes],
        revealed: state[:revealed],
        connected_count: presence.count,
        voted_count: state[:votes].count,
        version: state[:version],
        last_updated: state[:last_updated],
        session_health: calculate_session_health(state, presence)
      }
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

    private

    def acquire_lock(operation_name)
      return false unless redis_available?
      
      lock_key = "#{LOCK_KEY}:#{operation_name}"
      lock_value = "#{Process.pid}:#{Thread.current.object_id}:#{Time.current.to_f}"
      
      # Try to acquire lock with expiration
      result = redis.set(lock_key, lock_value, nx: true, ex: LOCK_TIMEOUT)
      result == "OK"
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error acquiring lock: #{e.message}"
      false
    end

    def release_lock(operation_name)
      return unless redis_available?
      
      lock_key = "#{LOCK_KEY}:#{operation_name}"
      redis.del(lock_key)
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error releasing lock: #{e.message}"
    end

    def save_state(state)
      if redis_available?
        redis.setex(SESSION_KEY, SESSION_EXPIRY, state.to_json)
      else
        # Fallback to Rails cache
        Rails.cache.write(SESSION_KEY, state, expires_in: SESSION_EXPIRY.seconds)
      end
      state
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Error saving state: #{e.message}, using fallback"
      Rails.cache.write(SESSION_KEY, state, expires_in: SESSION_EXPIRY.seconds)
      state
    end

    def save_presence(presence)
      if redis_available?
        redis.setex(PRESENCE_KEY, SESSION_EXPIRY, presence.to_json)
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
        presence_data = redis.get(PRESENCE_KEY)
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
        version: 0,
        last_updated: Time.current.to_i
      }
    end

    def broadcast_state_change(action, state)
      broadcast_state = get_broadcast_state
      
      Rails.logger.info "[AtomicState] Broadcasting #{action}, version: #{broadcast_state[:version]}"
      
      ActionCable.server.broadcast(
        "estimation_session",
        {
          action: "sync_state",
          state: broadcast_state,
          change_action: action,
          timestamp: Time.current.to_i
        }
      )
    rescue StandardError => e
      Rails.logger.error "[AtomicState] Failed to broadcast state change: #{e.message}"
      # Don't raise here - state is saved, broadcast failure shouldn't fail the operation
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
      
      [health_score, 0].max
    end
  end
end
