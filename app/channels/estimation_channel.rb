class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    # Track this connection
    EstimationSessionStore.add_connection(connection_identifier)
    
    # Broadcast immediately to existing clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_update",
        connected_count: EstimationSessionStore.connected_count
      }
    )
    
    # Broadcast again after 1 second to ensure new client receives it
    Thread.new do
      sleep 1
      ActionCable.server.broadcast(
        "estimation_session",
        {
          action: "presence_update",
          connected_count: EstimationSessionStore.connected_count
        }
      )
    end
  end

  def unsubscribed
    # Remove this connection
    EstimationSessionStore.remove_connection(connection_identifier)
    
    # Broadcast to ALL clients
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