class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    # Send current session state to the newly connected client
    transmit_current_state
  end

  def unsubscribed
    # Cleanup when channel is unsubscribed
  end

  private

  def transmit_current_state
    state = EstimationSessionStore.get_state
    
    # Send ticket data if exists
    if state[:ticket_data].present? || state[:ticket_title].present?
      transmit({
        action: "set_ticket",
        ticket_title: state[:ticket_title],
        ticket_data: state[:ticket_data]
      })
    end
    
    # Send all votes
    if state[:votes].present?
      state[:votes].each do |user_name, points|
        transmit({
          action: "submit",
          user_name: user_name,
          points: points
        })
      end
    end
    
    # Send revealed state if needed
    if state[:revealed]
      transmit({
        action: "reveal"
      })
    end
  end
end