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
      state[:updated_at] = Time.current.to_i
      save_state(state)
    end

    def add_vote(user_name, points)
      state = get_state
      state[:votes][user_name] = points
      state[:updated_at] = Time.current.to_i
      save_state(state)
    end

    def reveal
      state = get_state
      state[:revealed] = true
      state[:updated_at] = Time.current.to_i
      save_state(state)
    end

    def clear_votes
      state = get_state
      state[:votes] = {}
      state[:revealed] = false
      state[:updated_at] = Time.current.to_i
      save_state(state)
    end

    def clear_all
      Rails.cache.delete(SESSION_KEY)
      Rails.cache.delete(PRESENCE_KEY)
    end

    # Presence tracking with aggressive cleanup
    def add_connection(connection_id)
      presence = get_presence
      presence[connection_id] = {
        last_seen: Time.current.to_i,
        joined_at: Time.current.to_i
      }
      save_presence(presence)
      # Always cleanup when adding
      cleanup_and_broadcast
    end

    def remove_connection(connection_id)
      presence = get_presence
      presence.delete(connection_id)
      save_presence(presence)
      # Always cleanup when removing
      cleanup_and_broadcast
    end

    def heartbeat(connection_id)
      presence = get_presence
      current_time = Time.current.to_i
      
      if presence[connection_id]
        presence[connection_id][:last_seen] = current_time
      else
        # Connection not tracked, add it
        presence[connection_id] = {
          last_seen: current_time,
          joined_at: current_time
        }
      end
      
      save_presence(presence)
      
      # Cleanup every 5th heartbeat (roughly every 50 seconds per client)
      # This distributes cleanup work across all active clients
      if current_time % 5 == 0
        cleanup_and_broadcast
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
        Rails.logger.info "Cleaned up #{initial_count - presence.count} stale connections"
        true # Indicate that cleanup occurred
      else
        false # No cleanup needed
      end
    end

    def cleanup_and_broadcast
      if cleanup_stale_connections
        broadcast_presence_count
      end
    end

    def connected_count
      cleanup_stale_connections
      get_presence.count
    end

    def voted_count
      get_state[:votes].count
    end

    # Get complete session data for initial load
    def get_complete_state
      cleanup_stale_connections
      state = get_state
      state.merge(
        connected_count: get_presence.count,
        voted_count: voted_count
      )
    end

    # Manual cleanup endpoint (can be called periodically from frontend)
    def force_cleanup
      cleanup_and_broadcast
      {
        connected_count: get_presence.count,
        voted_count: voted_count,
        cleaned: true
      }
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
          connected_count: get_presence.count,
          voted_count: voted_count
        }
      )
    end
  end
end