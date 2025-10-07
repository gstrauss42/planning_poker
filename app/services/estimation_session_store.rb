# app/services/estimation_session_store.rb
class EstimationSessionStore
  SESSION_KEY = "estimation_session_state"
  EXPIRY = 10.minutes

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
  end
end