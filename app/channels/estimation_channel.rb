class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    # Track this connection
    EstimationSessionStore.add_connection(connection_identifier)
    
    # Broadcast to ALL clients (just like submit, reveal, clear do)
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_update",
        connected_count: EstimationSessionStore.connected_count
      }
    )
  end

  def unsubscribed
    # Remove this connection
    EstimationSessionStore.remove_connection(connection_identifier)
    
    # Broadcast to ALL clients (just like submit, reveal, clear do)
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_update",
        connected_count: EstimationSessionStore.connected_count
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
end