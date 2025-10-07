class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    # Track this connection
    EstimationSessionStore.add_connection(connection_identifier)
    
    # Send current session state to the newly connected client
    transmit_current_state
  end

  def unsubscribed
    # Remove this connection
    EstimationSessionStore.remove_connection(connection_identifier)
  end

  def heartbeat
    # Update this connection's last seen time
    EstimationSessionStore.heartbeat(connection_identifier)
  end

  private

  def connection_identifier
    # Use a unique identifier for this connection
    connection.connection_identifier
  end

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

    # Send presence count
    transmit({
      action: "presence_update",
      connected_count: EstimationSessionStore.connected_count
    })
  end
end