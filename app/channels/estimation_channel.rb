class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    # Track this connection and get count
    connection_count = EstimationSessionStore.add_connection(connection.connection_identifier)
    
    # Send current complete state to the newly connected client
    state = EstimationSessionStore.get_complete_state
    transmit({
      action: "initial_state",
      ticket_data: state[:ticket_data],
      ticket_title: state[:ticket_title],
      votes: state[:votes],
      revealed: state[:revealed],
      connected_count: state[:connected_count],
      voted_count: state[:voted_count]
    })
    
    # Broadcast presence update to ALL OTHER clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_updated",
        connected_count: connection_count,
        voted_count: state[:voted_count]
      }
    )
  end

  def unsubscribed
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
end