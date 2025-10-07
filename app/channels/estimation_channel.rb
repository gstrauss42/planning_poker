class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    # Track this connection
    EstimationSessionStore.add_connection(connection_identifier)
    
    # Send current session state to the newly connected client
    # Send as a single complete state message
    transmit_current_state
    
    # Broadcast presence update to ALL clients (including the new one)
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_update",
        connected_count: EstimationSessionStore.connected_count,
        voted_count: EstimationSessionStore.voted_count
      }
    )
  end

  def unsubscribed
    # Remove this connection
    EstimationSessionStore.remove_connection(connection_identifier)
    
    # Broadcast updated presence to remaining clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_update",
        connected_count: EstimationSessionStore.connected_count,
        voted_count: EstimationSessionStore.voted_count
      }
    )
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
    
    # Send complete state as a single message
    transmit({
      action: "initial_state",
      ticket_title: state[:ticket_title],
      ticket_data: state[:ticket_data],
      votes: state[:votes],
      revealed: state[:revealed],
      connected_count: EstimationSessionStore.connected_count,
      voted_count: EstimationSessionStore.voted_count
    })
  end
end