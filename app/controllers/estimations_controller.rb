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

    begin
      # Atomic clear with version checking
      AtomicStateManager.clear_votes(expected_version)
      
      render json: { 
        success: true, 
        message: "Votes cleared successfully",
        timestamp: Time.current.to_i
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

  def health_check
    begin
      issues = AtomicStateManager.validate_state_integrity
      state = AtomicStateManager.get_broadcast_state
      
      render json: {
        status: issues.any? ? "degraded" : "healthy",
        issues: issues,
        session_health: state[:session_health],
        timestamp: Time.current.to_i
      }
    rescue StandardError => e
      Rails.logger.error "[Controller] Error during health check: #{e.message}"
      render json: { 
        status: "error",
        error: "Health check failed",
        timestamp: Time.current.to_i
      }, status: :internal_server_error
    end
  end
end