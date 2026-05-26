class EstimationsController < ApplicationController
  def index
  end

  def submit
    user_name = params[:user_name]
    points = params[:points]
    expected_version = params[:expected_version]&.to_i

    if user_name.blank? || points.blank?
      render json: { error: "Name and points are required" }, status: :bad_request
      return
    end

    begin
      # Atomic vote submission with version checking
      AtomicStateManager.add_vote(user_name, points, expected_version)

      render json: {
        success: true,
        message: "Vote submitted successfully",
        timestamp: Time.current.to_i
      }

    rescue AtomicStateManager::VersionConflictError => e
      Rails.logger.warn "[Controller] Version conflict during vote submission: #{e.message}"
      render json: {
        error: "Session state has changed. Please refresh and try again.",
        requires_refresh: true,
        timestamp: Time.current.to_i
      }, status: :conflict

    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during vote submission: #{e.message}"
      render json: {
        error: "Failed to submit vote. Please try again.",
        timestamp: Time.current.to_i
      }, status: :unprocessable_entity

    rescue StandardError => e
      Rails.logger.error "[Controller] Unexpected error during vote submission: #{e.message}"
      render json: {
        error: "An unexpected error occurred. Please try again.",
        timestamp: Time.current.to_i
      }, status: :internal_server_error
    end
  end

  def reveal
    expected_version = params[:expected_version]&.to_i

    begin
      # Atomic reveal with version checking
      AtomicStateManager.reveal_votes(expected_version)

      render json: {
        success: true,
        message: "Votes revealed successfully",
        timestamp: Time.current.to_i
      }

    rescue AtomicStateManager::VersionConflictError => e
      Rails.logger.warn "[Controller] Version conflict during reveal: #{e.message}"
      render json: {
        error: "Session state has changed. Please refresh and try again.",
        requires_refresh: true,
        timestamp: Time.current.to_i
      }, status: :conflict

    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during reveal: #{e.message}"
      render json: {
        error: "Failed to reveal votes. Please try again.",
        timestamp: Time.current.to_i
      }, status: :unprocessable_entity

    rescue StandardError => e
      Rails.logger.error "[Controller] Unexpected error during reveal: #{e.message}"
      render json: {
        error: "An unexpected error occurred. Please try again.",
        timestamp: Time.current.to_i
      }, status: :internal_server_error
    end
  end

  def clear
    expected_version = params[:expected_version]&.to_i

    Rails.logger.info "[Controller] Clear votes request - expected_version: #{expected_version}"

    begin
      # Atomic clear with version checking
      Rails.logger.info "[Controller] Calling AtomicStateManager.clear_votes"
      result = AtomicStateManager.clear_votes(expected_version)
      Rails.logger.info "[Controller] Clear votes result: version #{result[:version]}, votes count: #{result[:votes]&.count || 0}"

      render json: {
        success: true,
        message: "Votes cleared successfully",
        timestamp: Time.current.to_i,
        new_version: result[:version]
      }

    rescue AtomicStateManager::VersionConflictError => e
      Rails.logger.warn "[Controller] Version conflict during clear: #{e.message}"
      render json: {
        error: "Session state has changed. Please refresh and try again.",
        requires_refresh: true,
        timestamp: Time.current.to_i
      }, status: :conflict

    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during clear: #{e.message}"
      render json: {
        error: "Failed to clear votes. Please try again.",
        timestamp: Time.current.to_i
      }, status: :unprocessable_entity

    rescue StandardError => e
      Rails.logger.error "[Controller] Unexpected error during clear: #{e.message}"
      Rails.logger.error "[Controller] Clear error backtrace: #{e.backtrace.first(3).join(', ')}"
      render json: {
        error: "An unexpected error occurred. Please try again.",
        timestamp: Time.current.to_i
      }, status: :internal_server_error
    end
  end

  def save_story_points
    ticket_key = params[:ticket_key]
    points = params[:points]

    if ticket_key.blank? || points.nil?
      render json: { error: "ticket_key and points are required" }, status: :bad_request
      return
    end

    jira = JiraService.new
    jira.update_story_points(ticket_key, points)
    render json: { success: true, message: "Story points saved" }

  rescue JiraService::JiraError => e
    render json: { error: e.message }, status: :unprocessable_entity

  rescue StandardError => e
    Rails.logger.error "[Controller] Unexpected error saving story points: #{e.message}"
    render json: { error: "An unexpected error occurred." }, status: :internal_server_error
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

      # Atomic ticket setting
      AtomicStateManager.set_ticket(ticket_data, ticket_data[:formatted_title])

      render json: {
        success: true,
        message: "Ticket loaded successfully",
        timestamp: Time.current.to_i
      }

    rescue JiraService::JiraError => e
      Rails.logger.error("JIRA fetch error: #{e.message}")
      render json: {
        error: e.message,
        timestamp: Time.current.to_i
      }, status: :unprocessable_entity

    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during JIRA fetch: #{e.message}"
      render json: {
        error: "Failed to load ticket. Please try again.",
        timestamp: Time.current.to_i
      }, status: :unprocessable_entity

    rescue StandardError => e
      Rails.logger.error("Unexpected error: #{e.message}")
      render json: {
        error: "An unexpected error occurred",
        timestamp: Time.current.to_i
      }, status: :internal_server_error
    end
  end

  def fetch_sprint_tickets
    sprint_name = params[:sprint_name] || "Refinement & Estimations"

    begin
      jira_service = JiraService.new
      tickets = jira_service.fetch_sprint_tickets(sprint_name)

      if tickets.empty?
        render json: {
          error: "No tickets found in sprint '#{sprint_name}'",
          timestamp: Time.current.to_i
        }, status: :unprocessable_entity
        return
      end

      # Atomic tickets setting
      AtomicStateManager.set_tickets(tickets)

      render json: {
        success: true,
        message: "Loaded #{tickets.count} tickets from sprint '#{sprint_name}'",
        ticket_count: tickets.count,
        timestamp: Time.current.to_i
      }

    rescue JiraService::JiraError => e
      Rails.logger.error("JIRA sprint fetch error: #{e.message}")
      render json: {
        error: e.message,
        timestamp: Time.current.to_i
      }, status: :unprocessable_entity

    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during sprint fetch: #{e.message}"
      render json: {
        error: "Failed to load sprint tickets. Please try again.",
        timestamp: Time.current.to_i
      }, status: :unprocessable_entity

    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching sprint: #{e.message}")
      render json: {
        error: "An unexpected error occurred",
        timestamp: Time.current.to_i
      }, status: :internal_server_error
    end
  end

  def navigate_ticket
    index = params[:index]&.to_i
    expected_version = params[:expected_version]&.to_i

    if index.nil?
      render json: { error: "Ticket index is required" }, status: :bad_request
      return
    end

    begin
      # Atomic ticket navigation
      AtomicStateManager.set_current_ticket(index, expected_version)

      render json: {
        success: true,
        message: "Navigated to ticket",
        timestamp: Time.current.to_i
      }

    rescue AtomicStateManager::VersionConflictError => e
      Rails.logger.warn "[Controller] Version conflict during navigation: #{e.message}"
      render json: {
        error: "Session state has changed. Please refresh and try again.",
        requires_refresh: true,
        timestamp: Time.current.to_i
      }, status: :conflict

    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during navigation: #{e.message}"
      render json: {
        error: "Failed to navigate to ticket. Please try again.",
        timestamp: Time.current.to_i
      }, status: :unprocessable_entity

    rescue StandardError => e
      Rails.logger.error("[Controller] Unexpected error during navigation: #{e.message}")
      render json: {
        error: "An unexpected error occurred",
        timestamp: Time.current.to_i
      }, status: :internal_server_error
    end
  end

  def remove_ticket
    ticket_id = params[:ticket_id]

    if ticket_id.blank?
      render json: { error: "Ticket ID is required" }, status: :bad_request
      return
    end

    begin
      AtomicStateManager.remove_ticket(ticket_id)
      render json: { success: true, message: "Ticket removed", timestamp: Time.current.to_i }
    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during ticket removal: #{e.message}"
      render json: { error: "Failed to remove ticket. Please try again." }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error "[Controller] Unexpected error during ticket removal: #{e.message}"
      render json: { error: "An unexpected error occurred." }, status: :internal_server_error
    end
  end

  def clear_tickets
    AtomicStateManager.clear_tickets
    render json: { success: true, message: "Tickets cleared", timestamp: Time.current.to_i }
  rescue AtomicStateManager::StateError => e
    Rails.logger.error "[Controller] State error during tickets clear: #{e.message}"
    render json: { error: "Failed to clear tickets. Please try again." }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "[Controller] Unexpected error during tickets clear: #{e.message}"
    render json: { error: "An unexpected error occurred." }, status: :internal_server_error
  end

  def async_fetch_sprint_tickets
    sprint_name = params[:sprint_name] || "Refinement & Estimations"

    begin
      jira_service = JiraService.new
      tickets = jira_service.fetch_sprint_tickets(sprint_name)

      if tickets.empty?
        render json: { error: "No tickets found in sprint '#{sprint_name}'" }, status: :unprocessable_entity
        return
      end

      AtomicStateManager.set_async_tickets(tickets)
      state = AtomicStateManager.get_broadcast_state

      render json: {
        success: true,
        state: state,
        message: "Loaded #{tickets.count} tickets for async voting",
        timestamp: Time.current.to_i
      }
    rescue JiraService::JiraError => e
      Rails.logger.error("JIRA async sprint fetch error: #{e.message}")
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching async sprint: #{e.message}")
      render json: { error: "An unexpected error occurred" }, status: :internal_server_error
    end
  end

  def async_fetch_jira_ticket
    jira_input = params[:jira_input]

    if jira_input.blank?
      render json: { error: "Please provide a JIRA ticket key or URL" }, status: :bad_request
      return
    end

    begin
      jira_service = JiraService.new
      ticket_data = jira_service.fetch_ticket(jira_input)

      AtomicStateManager.add_async_ticket(ticket_data)
      state = AtomicStateManager.get_broadcast_state

      render json: {
        success: true,
        state: state,
        message: "Ticket added for async voting",
        timestamp: Time.current.to_i
      }
    rescue JiraService::JiraError => e
      Rails.logger.error("JIRA async fetch error: #{e.message}")
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Unexpected error: #{e.message}")
      render json: { error: "An unexpected error occurred" }, status: :internal_server_error
    end
  end

  def async_vote
    ticket_id = params[:ticket_id]
    user_name = params[:user_name]
    points = params[:points]

    if ticket_id.blank? || user_name.blank? || points.blank?
      render json: { error: "Ticket ID, name, and points are required" }, status: :bad_request
      return
    end

    begin
      AtomicStateManager.add_vote_for_ticket(ticket_id, user_name, points)
      state = AtomicStateManager.get_broadcast_state
      render json: { success: true, state: state, timestamp: Time.current.to_i }
    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during async vote: #{e.message}"
      render json: { error: "Failed to submit vote. Please try again." }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error "[Controller] Unexpected error during async vote: #{e.message}"
      render json: { error: "An unexpected error occurred." }, status: :internal_server_error
    end
  end

  def async_reveal
    ticket_id = params[:ticket_id]

    if ticket_id.blank?
      render json: { error: "Ticket ID is required" }, status: :bad_request
      return
    end

    begin
      AtomicStateManager.reveal_votes_for_ticket(ticket_id)
      state = AtomicStateManager.get_broadcast_state
      render json: { success: true, state: state, timestamp: Time.current.to_i }
    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during async reveal: #{e.message}"
      render json: { error: "Failed to reveal votes." }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error "[Controller] Unexpected error during async reveal: #{e.message}"
      render json: { error: "An unexpected error occurred." }, status: :internal_server_error
    end
  end

  def async_clear
    ticket_id = params[:ticket_id]

    if ticket_id.blank?
      render json: { error: "Ticket ID is required" }, status: :bad_request
      return
    end

    begin
      AtomicStateManager.clear_votes_for_ticket(ticket_id)
      state = AtomicStateManager.get_broadcast_state
      render json: { success: true, state: state, timestamp: Time.current.to_i }
    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during async clear: #{e.message}"
      render json: { error: "Failed to clear votes." }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error "[Controller] Unexpected error during async clear: #{e.message}"
      render json: { error: "An unexpected error occurred." }, status: :internal_server_error
    end
  end

  def async_remove_ticket
    ticket_id = params[:ticket_id]

    if ticket_id.blank?
      render json: { error: "Ticket ID is required" }, status: :bad_request
      return
    end

    begin
      AtomicStateManager.remove_async_ticket(ticket_id)
      state = AtomicStateManager.get_broadcast_state
      render json: { success: true, state: state, timestamp: Time.current.to_i }
    rescue AtomicStateManager::StateError => e
      Rails.logger.error "[Controller] State error during async ticket removal: #{e.message}"
      render json: { error: "Failed to remove ticket." }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error "[Controller] Unexpected error during async ticket removal: #{e.message}"
      render json: { error: "An unexpected error occurred." }, status: :internal_server_error
    end
  end

  def async_clear_tickets
    AtomicStateManager.clear_async_tickets
    state = AtomicStateManager.get_broadcast_state
    render json: { success: true, state: state, timestamp: Time.current.to_i }
  rescue AtomicStateManager::StateError => e
    Rails.logger.error "[Controller] State error during async tickets clear: #{e.message}"
    render json: { error: "Failed to clear tickets." }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "[Controller] Unexpected error during async tickets clear: #{e.message}"
    render json: { error: "An unexpected error occurred." }, status: :internal_server_error
  end

  def get_session_state
    begin
      state = AtomicStateManager.get_broadcast_state
      render json: state
    rescue StandardError => e
      Rails.logger.error "[Controller] Error getting session state: #{e.message}"
      render json: {
        error: "Failed to get session state",
        timestamp: Time.current.to_i
      }, status: :internal_server_error
    end
  end

  def proxy_jira_image
    attachment_id = params[:attachment_id]

    if attachment_id.blank?
      render json: { error: "Attachment ID is required" }, status: :bad_request
      return
    end

    begin
      # Get JIRA credentials from Rails credentials
      jira_email = Rails.application.credentials.jira&.email
      jira_api_token = Rails.application.credentials.jira&.api_token
      jira_base_url = Rails.application.credentials.jira&.base_url

      if jira_email.blank? || jira_api_token.blank? || jira_base_url.blank?
        Rails.logger.error "[Controller] JIRA credentials not configured"
        render json: { error: "JIRA credentials not configured" }, status: :internal_server_error
        return
      end

      auth_header = "Basic #{Base64.strict_encode64("#{jira_email}:#{jira_api_token}")}"

      # Try attachment API first (for numeric IDs)
      image_url = "#{jira_base_url}/rest/api/3/attachment/content/#{attachment_id}"
      Rails.logger.debug "[Controller] Proxying JIRA image: #{image_url}"

      response = HTTParty.get(
        image_url,
        headers: {
          "Authorization" => auth_header,
          "Accept" => "*/*",
          "User-Agent" => "PlanningPoker/1.0"
        },
        follow_redirects: true,
        timeout: 10
      )

      # If attachment API fails and ID looks like a UUID, try media API
      if !response.success? && attachment_id.match?(/^[0-9a-f-]{36}$/i)
        Rails.logger.debug "[Controller] Attachment API failed, trying Media API for UUID: #{attachment_id}"

        # Try the secure/attachment path with filename lookup
        media_url = "#{jira_base_url}/secure/attachment/#{attachment_id}"
        response = HTTParty.get(
          media_url,
          headers: {
            "Authorization" => auth_header,
            "Accept" => "*/*",
            "User-Agent" => "PlanningPoker/1.0"
          },
          follow_redirects: true,
          timeout: 10
        )
      end

      if response.success?
        send_data response.body,
                  type: response.headers["content-type"] || "image/png",
                  disposition: "inline"
      else
        Rails.logger.error "[Controller] Failed to fetch JIRA image: #{response.code} - #{response.message}"
        head :unprocessable_entity
      end

    rescue StandardError => e
      Rails.logger.error "[Controller] Error proxying JIRA image: #{e.message}"
      head :internal_server_error
    end
  end
end
