class EstimationsController < ApplicationController
  def index
  end

  def submit
    user_name = params[:user_name]
    points = params[:points]

    # Validate input
    if user_name.blank? || points.blank?
      render json: { error: "Name and points are required" }, status: :bad_request
      return
    end

    # Store in session and get updated state
    state = EstimationSessionStore.add_vote(user_name, points)

    # Broadcast complete vote state to ALL clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "state_updated",
        votes: state[:votes],
        revealed: state[:revealed],
        voted_count: state[:votes].count,
        connected_count: EstimationSessionStore.connected_count
      }
    )

    render json: { success: true }
  end

  def reveal
    # Update session and get state
    state = EstimationSessionStore.reveal

    # Broadcast complete state to ALL clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "state_updated",
        votes: state[:votes],
        revealed: state[:revealed],
        voted_count: state[:votes].count,
        connected_count: EstimationSessionStore.connected_count
      }
    )

    render json: { success: true }
  end

  def clear
    # Clear votes in session
    state = EstimationSessionStore.clear_votes

    # Broadcast complete state to ALL clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "state_updated",
        votes: {},
        revealed: false,
        voted_count: 0,
        connected_count: EstimationSessionStore.connected_count
      }
    )

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
      
      # Store in session - this will clear votes and revealed state
      state = EstimationSessionStore.set_ticket(ticket_data, ticket_data[:formatted_title])
      
      # Broadcast complete new state to ALL clients
      ActionCable.server.broadcast(
        "estimation_session",
        {
          action: "ticket_changed",
          ticket_data: ticket_data,
          ticket_title: ticket_data[:formatted_title],
          votes: {},  # Votes are cleared when ticket changes
          revealed: false,  # Reset reveal state
          voted_count: 0,
          connected_count: EstimationSessionStore.connected_count
        }
      )

      render json: { 
        success: true,
        message: "Ticket loaded, votes cleared"
      }
    rescue JiraService::JiraError => e
      Rails.logger.error("JIRA fetch error: #{e.message}")
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching JIRA ticket: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { error: "An unexpected error occurred" }, status: :internal_server_error
    end
  end

  # This endpoint returns the complete session state
  def get_session_state
    state = EstimationSessionStore.get_complete_state
    render json: state
  end
end