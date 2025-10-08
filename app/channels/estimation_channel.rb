class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
    
    Rails.logger.info "[Channel] Client subscribed: #{connection.connection_identifier}"
    
    begin
      # Track connection atomically
      Rails.logger.info "[Channel] Adding connection to state manager"
      AtomicStateManager.add_connection(connection.connection_identifier)
      
      # Send current state to THIS client only with retry mechanism
      Rails.logger.info "[Channel] Sending initial state to client"
      send_state_with_retry
      
      # Broadcast updated presence to ALL clients
      Rails.logger.info "[Channel] Broadcasting presence update"
      broadcast_presence
      
    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Channel] State error during subscription: #{e.message}"
      transmit_error("Failed to join session. Please refresh the page.")
    rescue StandardError => e
      Rails.logger.error "[Channel] Unexpected error during subscription: #{e.message}"
      Rails.logger.error "[Channel] Error backtrace: #{e.backtrace.first(3).join(', ')}"
      transmit_error("Connection error. Please refresh the page.")
    end
  end

  def unsubscribed
    Rails.logger.info "[Channel] Client unsubscribed: #{connection.connection_identifier}"
    
    begin
      # Remove connection atomically
      AtomicStateManager.remove_connection(connection.connection_identifier)
      
      # Force cleanup and broadcast updated presence
      AtomicStateManager.cleanup_stale_connections
      broadcast_presence
      
      Rails.logger.info "[Channel] Connection cleanup completed for: #{connection.connection_identifier}"
      
    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Channel] State error during unsubscription: #{e.message}"
    rescue StandardError => e
      Rails.logger.error "[Channel] Unexpected error during unsubscription: #{e.message}"
    end
  end

  def heartbeat
    begin
      AtomicStateManager.heartbeat(connection.connection_identifier)
      
      # Send periodic state validation less frequently
      if rand(100) == 0  # Every 100th heartbeat (reduced from 50th)
        validate_client_state
      end
      
    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Channel] State error during heartbeat: #{e.message}"
      transmit_error("Session state error. Please refresh.")
    rescue StandardError => e
      Rails.logger.error "[Channel] Unexpected error during heartbeat: #{e.message}"
    end
  end

  def request_state_sync
    begin
      send_state_with_retry
    rescue StandardError => e
      Rails.logger.error "[Channel] Error during state sync request: #{e.message}"
      transmit_error("Failed to sync state. Please refresh.")
    end
  end
  
  private
  
  def send_state_with_retry
    retries = 0
    max_retries = 3
    
    begin
      Rails.logger.info "[Channel] Getting broadcast state for client #{connection.connection_identifier}"
      state = AtomicStateManager.get_broadcast_state
      Rails.logger.info "[Channel] State retrieved: version #{state[:version]}, votes: #{state[:votes]&.count || 0}"
      
      transmit_message = {
        action: "sync_state",
        state: state,
        timestamp: Time.current.to_i,
        retry_count: retries
      }
      
      Rails.logger.info "[Channel] Transmitting state to client #{connection.connection_identifier}"
      transmit(transmit_message)
      
      Rails.logger.info "[Channel] State sent to #{connection.connection_identifier}, version: #{state[:version]}"
      
    rescue StandardError => e
      retries += 1
      Rails.logger.error "[Channel] State send failed for client #{connection.connection_identifier}: #{e.message}"
      if retries < max_retries
        Rails.logger.warn "[Channel] State send failed, retry #{retries}/#{max_retries}: #{e.message}"
        sleep(0.1 * retries)
        retry
      else
        Rails.logger.error "[Channel] Max retries exceeded for state send: #{e.message}"
        raise e
      end
    end
  end
  
  def broadcast_presence
    begin
      presence_data = {
        action: "presence_update",
        connected_count: AtomicStateManager.connected_count,
        voted_count: AtomicStateManager.voted_count,
        timestamp: Time.current.to_i
      }
      
      ActionCable.server.broadcast("estimation_session", presence_data)
      
    rescue StandardError => e
      Rails.logger.error "[Channel] Error broadcasting presence: #{e.message}"
    end
  end

  def validate_client_state
    begin
      issues = AtomicStateManager.validate_state_integrity
      if issues.any?
        Rails.logger.warn "[Channel] State integrity issues detected: #{issues.join(', ')}"
        transmit({
          action: "state_warning",
          issues: issues,
          timestamp: Time.current.to_i
        })
      end
    rescue StandardError => e
      Rails.logger.error "[Channel] Error validating state: #{e.message}"
    end
  end

  def transmit_error(message)
    transmit({
      action: "error",
      message: message,
      timestamp: Time.current.to_i
    })
  end
end