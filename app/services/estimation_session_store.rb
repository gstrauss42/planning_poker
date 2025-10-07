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

    # When setting a new ticket, clear votes and reveal state
    def set_ticket(ticket_data, ticket_title)
      state = get_state
      state[:ticket_data] = ticket_data
      state[:ticket_title] = ticket_title
      # IMPORTANT: Clear votes and reveal state when changing tickets
      state[:votes] = {}
      state[:revealed] = false
      state[:timestamp] = Time.current.to_i
      state[:ticket_id] = ticket_data ? ticket_data[:key] : nil
      save_state(state)
      Rails.logger.info "[SessionStore] Ticket set: #{ticket_title}, cleared votes"
      state
    end

    def add_vote(user_name, points)
      state = get_state
      state[:votes][user_name] = points
      state[:timestamp] = Time.current.to_i
      save_state(state)
      Rails.logger.info "[SessionStore] Vote added: #{user_name} = #{points}, Total votes: #{state[:votes].count}"
      state
    end

    def reveal
      state = get_state
      # Only reveal if there are votes
      if state[:votes].any?
        state[:revealed] = true
        state[:timestamp] = Time.current.to_i
        save_state(state)
        Rails.logger.info "[SessionStore] Votes revealed"
      else
        Rails.logger.info "[SessionStore] Cannot reveal - no votes"
      end
      state
    end

    def clear_votes
      state = get_state
      state[:votes] = {}
      state[:revealed] = false
      state[:timestamp] = Time.current.to_i
      save_state(state)
      Rails.logger.info "[SessionStore] Votes cleared"
      state
    end

    def clear_all
      Rails.cache.delete(SESSION_KEY)
      Rails.cache.delete(PRESENCE_KEY)
      Rails.logger.info "[SessionStore] All data cleared"
      default_state
    end

    # Presence tracking
    def add_connection(connection_id)
      presence = get_presence
      presence[connection_id] = Time.current.to_i
      save_presence(presence)
      cleanup_stale_connections
      count = presence.keys.count
      Rails.logger.info "[SessionStore] Connection added: #{connection_id}, Total: #{count}"
      count
    end

    def remove_connection(connection_id)
      presence = get_presence
      presence.delete(connection_id)
      save_presence(presence)
      cleanup_stale_connections
      count = presence.keys.count
      Rails.logger.info "[SessionStore] Connection removed: #{connection_id}, Total: #{count}"
      count
    end

    def heartbeat(connection_id)
      presence = get_presence
      presence[connection_id] = Time.current.to_i
      save_presence(presence)
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
        Rails.logger.info "[SessionStore] Cleaned #{initial_count - presence.count} stale connections"
      end
      
      presence
    end

    def connected_count
      cleanup_stale_connections.count
    end

    def voted_count
      get_state[:votes].count
    end

    # Get complete session state - ensuring consistency
    def get_complete_state
      state = get_state
      presence_count = connected_count
      
      # Ensure consistency
      if state[:votes].empty?
        state[:revealed] = false
      end
      
      {
        ticket_data: state[:ticket_data],
        ticket_title: state[:ticket_title],
        ticket_id: state[:ticket_id],
        votes: state[:votes] || {},
        revealed: state[:revealed] || false,
        connected_count: presence_count,
        voted_count: (state[:votes] || {}).count,
        timestamp: state[:timestamp]
      }
    end

    private

    def default_state
      {
        ticket_data: nil,
        ticket_title: nil,
        ticket_id: nil,
        votes: {},
        revealed: false,
        timestamp: Time.current.to_i
      }
    end

    def save_state(state)
      Rails.cache.write(SESSION_KEY, state, expires_in: EXPIRY, race_condition_ttl: 5.seconds)
      state
    end

    def save_presence(presence)
      Rails.cache.write(PRESENCE_KEY, presence, expires_in: EXPIRY, race_condition_ttl: 5.seconds)
      presence
    end
  end
end