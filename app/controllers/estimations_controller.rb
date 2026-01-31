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
          'Authorization' => auth_header,
          'Accept' => '*/*',
          'User-Agent' => 'PlanningPoker/1.0'
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
            'Authorization' => auth_header,
            'Accept' => '*/*',
            'User-Agent' => 'PlanningPoker/1.0'
          },
          follow_redirects: true,
          timeout: 10
        )
      end
      
      if response.success?
        send_data response.body, 
                  type: response.headers['content-type'] || 'image/png', 
                  disposition: 'inline'
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