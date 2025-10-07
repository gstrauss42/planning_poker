class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    Rails.logger.info "[Channel] New subscription from #{connection.connection_identifier}"
    
    # Track this connection
    EstimationSessionStore.add_connection(connection.connection_identifier)
    
    # Send current complete state to the newly connected client
    # Use perform_later to avoid race conditions
    send_initial_state
    
    # Broadcast presence update to ALL OTHER clients after a small delay
    # This prevents race conditions with the initial state
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_updated",
        connected_count: EstimationSessionStore.connected_count,
        voted_count: EstimationSessionStore.voted_count
      }
    )
  end

  def unsubscribed
    Rails.logger.info "[Channel] Unsubscribed: #{connection.connection_identifier}"
    
    # Remove this connection
    connection_count = EstimationSessionStore.remove_connection(connection.connection_identifier)
    voted_count = EstimationSessionStore.voted_count
    
    # Broadcast updated presence to remaining clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_updated",
        connected_count: connection_count,
        voted_count: voted_count
      }
    )
  end

  def heartbeat
    # Update this connection's last seen time
    EstimationSessionStore.heartbeat(connection.connection_identifier)
    
    # Periodically cleanup and broadcast accurate presence
    if rand(10) == 0  # 10% chance on each heartbeat
      connected = EstimationSessionStore.connected_count
      voted = EstimationSessionStore.voted_count
      
      ActionCable.server.broadcast(
        "estimation_session",
        {
          action: "presence_updated",
          connected_count: connected,
          voted_count: voted
        }
      )
    end
  end
  
  private
  
  def send_initial_state
    state = EstimationSessionStore.get_complete_state
    
    Rails.logger.info "[Channel] Sending initial state to new client: votes=#{state[:votes].count}, revealed=#{state[:revealed]}"
    
    # Send the complete current state
    transmit({
      action: "initial_state",
      ticket_data: state[:ticket_data],
      ticket_title: state[:ticket_title],
      votes: state[:votes],
      revealed: state[:revealed],
      connected_count: state[:connected_count],
      voted_count: state[:voted_count]
    })
  end
end