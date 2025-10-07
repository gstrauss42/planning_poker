# app/services/estimation_session_store.rb
class EstimationSessionStore
  SESSION_KEY = "estimation_session_state"
  PRESENCE_KEY = "estimation_session_presence"
  LOCK_KEY = "estimation_session_lock"
  EXPIRY = 30.minutes
  PRESENCE_EXPIRY = 30.seconds
  LOCK_TIMEOUT = 5.seconds

  class << self
    def get_state
      state = Rails.cache.read(SESSION_KEY)
      state || default_state
    end

    def set_ticket(ticket_data, ticket_title)
      with_lock do
        state = get_state
        state[:ticket_data] = ticket_data
        state[:ticket_title] = ticket_title
        state[:updated_at] = Time.current.to_i
        save_state(state)
      end
    end

    def add_vote(user_name, points)
      with_lock do
        state = get_state
        state[:votes][user_name] = points
        state[:updated_at] = Time.current.to_i
        save_state(state)
      end
    end

    def reveal
      with_lock do
        state = get_state
        state[:revealed] = true
        state[:updated_at] = Time.current.to_i
        save_state(state)
      end
    end

    def clear_votes
      with_lock do
        state = get_state
        state[:votes] = {}
        state[:revealed] = false
        state[:updated_at] = Time.current.to_i
        save_state(state)
      end
    end

    def clear_all
      with_lock do
        Rails.cache.delete(SESSION_KEY)
        Rails.cache.delete(PRESENCE_KEY)
      end
    end

    # Presence tracking with automatic cleanup
    def add_connection(connection_id)
      with_lock do
        presence = get_presence
        presence[connection_id] = {
          last_seen: Time.current.to_i,
          joined_at: Time.current.to_i
        }
        save_presence(presence)
        cleanup_stale_connections
        broadcast_presence_count
      end
    end

    def remove_connection(connection_id)
      with_lock do
        presence = get_presence
        presence.delete(connection_id)
        save_presence(presence)
        broadcast_presence_count
      end
    end

    def heartbeat(connection_id)
      with_lock do
        presence = get_presence
        if presence[connection_id]
          presence[connection_id][:last_seen] = Time.current.to_i
          save_presence(presence)
        else
          # Connection not tracked, add it
          add_connection(connection_id)
        end
      end
    end

    def get_presence
      Rails.cache.read(PRESENCE_KEY) || {}
    end

    def cleanup_stale_connections
      presence = get_presence
      current_time = Time.current.to_i
      initial_count = presence.count
      
      presence.reject! do |_id, data|
        last_seen = data.is_a?(Hash) ? data[:last_seen] : data
        current_time - last_seen.to_i > PRESENCE_EXPIRY.to_i
      end
      
      if presence.count != initial_count
        save_presence(presence)
        broadcast_presence_count
      end
      
      presence
    end

    def connected_count
      cleanup_stale_connections.count
    end

    def voted_count
      get_state[:votes].count
    end

    # Get complete session data for initial load
    def get_complete_state
      cleanup_stale_connections
      state = get_state
      state.merge(
        connected_count: connected_count,
        voted_count: voted_count
      )
    end

    private

    def default_state
      {
        ticket_data: nil,
        ticket_title: nil,
        votes: {},
        revealed: false,
        updated_at: Time.current.to_i
      }
    end

    def save_state(state)
      Rails.cache.write(SESSION_KEY, state, expires_in: EXPIRY)
      state
    end

    def save_presence(presence)
      Rails.cache.write(PRESENCE_KEY, presence, expires_in: EXPIRY)
      presence
    end

    def broadcast_presence_count
      ActionCable.server.broadcast(
        "estimation_session",
        {
          action: "presence_update",
          connected_count: connected_count,
          voted_count: voted_count
        }
      )
    end

    # Lock mechanism to prevent race conditions
    def with_lock(&block)
      acquired = false
      start_time = Time.current
      
      while !acquired && (Time.current - start_time) < LOCK_TIMEOUT
        acquired = Rails.cache.write(LOCK_KEY, true, expires_in: 1.second, unless_exist: true)
        sleep(0.01) unless acquired
      end
      
      if acquired
        begin
          yield
        ensure
          Rails.cache.delete(LOCK_KEY)
        end
      else
        Rails.logger.error("Failed to acquire lock for EstimationSessionStore operation")
        yield # Proceed anyway to avoid blocking
      end
    end
  end
end