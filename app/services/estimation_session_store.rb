# app/services/estimation_session_store.rb
class EstimationSessionStore
  SESSION_KEY = "estimation_session_state"
  PRESENCE_KEY = "estimation_session_presence"
  EXPIRY = 30.minutes
  PRESENCE_EXPIRY = 30.seconds

  class << self
    def get_state
      state = Rails.cache.read(SESSION_KEY)
      state || default_state
    end

    def set_ticket(ticket_data, ticket_title)
      state = get_state
      state[:ticket_data] = ticket_data
      state[:ticket_title] = ticket_title
      save_state(state)
    end

    def add_vote(user_name, points)
      state = get_state
      state[:votes][user_name] = points
      save_state(state)
    end

    def reveal
      state = get_state
      state[:revealed] = true
      save_state(state)
    end

    def clear_votes
      state = get_state
      state[:votes] = {}
      state[:revealed] = false
      save_state(state)
    end

    def clear_all
      Rails.cache.delete(SESSION_KEY)
      Rails.cache.delete(PRESENCE_KEY)
    end

    # Presence tracking
    def add_connection(connection_id)
      presence = get_presence
      presence[connection_id] = Time.current.to_i
      save_presence(presence)
      Rails.logger.info "Added connection: #{connection_id}, Total: #{presence.keys.count}"
    end

    def remove_connection(connection_id)
      presence = get_presence
      presence.delete(connection_id)
      save_presence(presence)
      cleanup_stale_connections
      Rails.logger.info "Removed connection: #{connection_id}, Total: #{presence.keys.count}"
    end

    def heartbeat(connection_id)
      presence = get_presence
      presence[connection_id] = Time.current.to_i
      save_presence(presence)
      # Periodic cleanup
      if Time.current.to_i % 10 == 0
        cleanup_stale_connections
      end
    end

    def get_presence
      Rails.cache.read(PRESENCE_KEY) || {}
    end

    def cleanup_stale_connections
      presence = get_presence
      current_time = Time.current.to_i
      initial_count = presence.count
      
      presence.reject! do |_id, last_seen|
        current_time - last_seen > PRESENCE_EXPIRY.to_i
      end
      
      if presence.count != initial_count
        save_presence(presence)
        Rails.logger.info "Cleaned up #{initial_count - presence.count} stale connections"
      end
      
      presence
    end

    def connected_count
      cleanup_stale_connections.count
    end

    def voted_count
      get_state[:votes].count
    end

    # Get complete session state for initial load
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
        revealed: false
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
  end
end