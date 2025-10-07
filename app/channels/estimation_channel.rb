class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    Rails.logger.info "[Channel] Client subscribed: #{connection.connection_identifier}"
    
    # Track connection
    EstimationSessionStore.add_connection(connection.connection_identifier)
    
    # Send current state to THIS client only
    # Using transmit ensures only the joining client gets this
    state = EstimationSessionStore.get_broadcast_state
    transmit({
      action: "sync_state",
      state: state
    })
    
    # Then broadcast updated presence to ALL clients
    broadcast_presence
  end

  def unsubscribed
    Rails.logger.info "[Channel] Client unsubscribed: #{connection.connection_identifier}"
    
    # Remove connection
    EstimationSessionStore.remove_connection(connection.connection_identifier)
    
    # Broadcast updated presence
    broadcast_presence
  end

  def heartbeat
    EstimationSessionStore.heartbeat(connection.connection_identifier)
  end
  
  private
  
  def broadcast_presence
    # Only broadcast presence count updates
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_update",
        connected_count: EstimationSessionStore.connected_count,
        voted_count: EstimationSessionStore.voted_count
      }
    )
  end
end