class EstimationsController < ApplicationController
  def index
  end

  def submit
    user_name = params[:user_name]
    points = params[:points]

    # Store in session
    EstimationSessionStore.add_vote(user_name, points)

    # Broadcast to all clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "submit",
        user_name: user_name,
        points: points
      }
    )

    # Broadcast updated presence count
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_update",
        connected_count: EstimationSessionStore.connected_count,
        voted_count: EstimationSessionStore.voted_count
      }
    )

    head :ok
  end

  def reveal
    # Update session
    EstimationSessionStore.reveal

    # Broadcast to all clients
    ActionCable.server.broadcast(
      "estimation_session",
      { action: "reveal" }
    )

    head :ok
  end

  def clear
    # Clear votes in session
    EstimationSessionStore.clear_votes

    # Broadcast to all clients
    ActionCable.server.broadcast(
      "estimation_session",
      { action: "clear" }
    )

    # Broadcast updated presence count
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "presence_update",
        connected_count: EstimationSessionStore.connected_count,
        voted_count: EstimationSessionStore.voted_count
      }
    )

    head :ok
  end

  def set_ticket
    ticket_title = params[:ticket_title]

    # Store in session
    EstimationSessionStore.set_ticket(nil, ticket_title)

    # Broadcast to all clients
    ActionCable.server.broadcast(
      "estimation_session",
      {
        action: "set_ticket",
        ticket_title: ticket_title
      }
    )

    head :ok
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
      
      # Store in session
      EstimationSessionStore.set_ticket(ticket_data, ticket_data[:formatted_title])
      
      # Broadcast to all clients
      ActionCable.server.broadcast(
        "estimation_session",
        {
          action: "set_ticket",
          ticket_title: ticket_data[:formatted_title],
          ticket_data: ticket_data
        }
      )

      render json: { 
        success: true, 
        ticket: ticket_data 
      }
    rescue JiraService::JiraError => e
      Rails.logger.error("JIRA fetch error: #{e.message}")
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching JIRA ticket: #{e.message}")
      render json: { error: "An unexpected error occurred" }, status: :internal_server_error
    end
  end

  def get_session_state
    state = EstimationSessionStore.get_state
    render json: state
  end
end