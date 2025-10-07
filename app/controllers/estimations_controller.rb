class EstimationsController < ApplicationController
  def index
  end

  def submit
    user_name = params[:user_name]
    points = params[:points]

    if user_name.blank? || points.blank?
      render json: { error: "Name and points are required" }, status: :bad_request
      return
    end

    # Update state
    EstimationSessionStore.add_vote(user_name, points)
    
    # Broadcast complete state to ALL
    broadcast_current_state
    
    render json: { success: true }
  end

  def reveal
    # Update state
    EstimationSessionStore.reveal
    
    # Broadcast complete state to ALL
    broadcast_current_state
    
    render json: { success: true }
  end

  def clear
    # Update state
    EstimationSessionStore.clear_votes
    
    # Broadcast complete state to ALL
    broadcast_current_state
    
    render json: { success: true }
  end

  def fetch_jira_ticket
    jira_input = params[:jira_input]

    if jira_input.blank?
      render json: { error: "Please provide a JIRA ticket key or URL" }, status: :bad_request
      return
    end

    begin
      jira_service = JiraService.new
      ticket_data = jira_service.fetch_ticket(jira_input)
      
      # Update state (this clears votes)
      EstimationSessionStore.set_ticket(ticket_data, ticket_data[:formatted_title])
      
      # Broadcast complete state to ALL
      broadcast_current_state
      
      render json: { success: true }
    rescue JiraService::JiraError => e
      Rails.logger.error("JIRA fetch error: #{e.message}")
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Unexpected error: #{e.message}")
      render json: { error: "An unexpected error occurred" }, status: :internal_server_error
    end
  end

  def get_session_state
    render json: EstimationSessionStore.get_broadcast_state
  end

  private

  def broadcast_current_state
    state = EstimationSessionStore.get_broadcast_state
    
    Rails.logger.info "[Broadcast] Sending state v#{state[:version]} to all clients"
    
    # Single unified broadcast to ALL clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "sync_state",
        state: state
      }
    )
  end
end