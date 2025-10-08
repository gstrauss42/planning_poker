# app/services/session_monitor.rb
class SessionMonitor
  class << self
    def monitor_session_health
      Rails.logger.info "[SessionMonitor] Starting health monitoring"
      
      # Check Redis connectivity
      redis_status = check_redis_health
      
      # Check session state integrity
      state_issues = AtomicStateManager.validate_state_integrity
      
      # Check presence consistency
      presence_issues = check_presence_consistency
      
      # Check for stale sessions
      stale_sessions = check_stale_sessions
      
      # Generate health report
      health_report = {
        timestamp: Time.current.to_i,
        redis_status: redis_status,
        state_issues: state_issues,
        presence_issues: presence_issues,
        stale_sessions: stale_sessions,
        overall_health: calculate_overall_health(redis_status, state_issues, presence_issues, stale_sessions)
      }
      
      Rails.logger.info "[SessionMonitor] Health report: #{health_report[:overall_health]}%"
      
      # Auto-remediate issues if possible
      auto_remediate_issues(health_report)
      
      health_report
    end

    def check_redis_health
      begin
        AtomicStateManager.redis.ping
        latency = measure_redis_latency
        
        # Get Redis client count
        client_count = nil
        begin
          info = AtomicStateManager.redis.info("clients")
          client_count = info["connected_clients"].to_i
        rescue StandardError => e
          Rails.logger.warn "[SessionMonitor] Could not get Redis client count: #{e.message}"
        end
        
        # Log warning if approaching connection limit
        if client_count && client_count > 40
          Rails.logger.warn "[SessionMonitor] Redis connection count high: #{client_count}/50"
        end
        
        { 
          status: "healthy", 
          latency: latency,
          client_count: client_count
        }
      rescue StandardError => e
        Rails.logger.error "[SessionMonitor] Redis health check failed: #{e.message}"
        { status: "unhealthy", error: e.message }
      end
    end

    def check_presence_consistency
      issues = []
      
      begin
        presence = AtomicStateManager.get_presence
        state = AtomicStateManager.get_state
        
        # Check for orphaned presence entries
        if presence.count > 0 && state[:version] == 0
          issues << "Presence entries without active session"
        end
        
        # Check for inconsistent vote counts
        actual_vote_count = state[:votes]&.count || 0
        reported_vote_count = state[:voted_count] || 0
        
        if actual_vote_count != reported_vote_count
          issues << "Vote count mismatch: actual #{actual_vote_count} vs reported #{reported_vote_count}"
        end
        
      rescue StandardError => e
        Rails.logger.error "[SessionMonitor] Presence consistency check failed: #{e.message}"
        issues << "Presence check failed: #{e.message}"
      end
      
      issues
    end

    def check_stale_sessions
      stale_sessions = []
      
      begin
        state = AtomicStateManager.get_state
        
        # Check if session is stale (no activity for 10 minutes)
        if state[:last_updated] && (Time.current.to_i - state[:last_updated]) > 600
          stale_sessions << "Session inactive for #{Time.current.to_i - state[:last_updated]} seconds"
        end
        
        # Check for very old sessions (over 2 hours)
        if state[:last_updated] && (Time.current.to_i - state[:last_updated]) > 7200
          stale_sessions << "Session older than 2 hours"
        end
        
      rescue StandardError => e
        Rails.logger.error "[SessionMonitor] Stale session check failed: #{e.message}"
        stale_sessions << "Stale check failed: #{e.message}"
      end
      
      stale_sessions
    end

    def auto_remediate_issues(health_report)
      remediations = []
      
      # Clean up stale connections
      if health_report[:presence_issues].any? { |issue| issue.include?("stale") }
        begin
          AtomicStateManager.cleanup_stale_connections
          remediations << "Cleaned up stale connections"
        rescue StandardError => e
          Rails.logger.error "[SessionMonitor] Failed to cleanup stale connections: #{e.message}"
        end
      end
      
      # Reset session if severely corrupted
      if health_report[:overall_health] < 20
        begin
          AtomicStateManager.clear_all
          remediations << "Reset corrupted session"
        rescue StandardError => e
          Rails.logger.error "[SessionMonitor] Failed to reset session: #{e.message}"
        end
      end
      
      if remediations.any?
        Rails.logger.info "[SessionMonitor] Auto-remediations: #{remediations.join(', ')}"
      end
    end

    def generate_session_metrics
      begin
        state = AtomicStateManager.get_state
        presence = AtomicStateManager.get_presence
        
        {
          session_version: state[:version],
          connected_users: presence.count,
          voted_users: state[:votes]&.count || 0,
          session_age: state[:last_updated] ? Time.current.to_i - state[:last_updated] : 0,
          has_ticket: state[:ticket_data].present?,
          is_revealed: state[:revealed],
          session_health: state[:session_health] || 100
        }
      rescue StandardError => e
        Rails.logger.error "[SessionMonitor] Failed to generate metrics: #{e.message}"
        { error: e.message }
      end
    end

    private

    def measure_redis_latency
      start_time = Time.current
      AtomicStateManager.redis.ping
      ((Time.current - start_time) * 1000).round(2) # milliseconds
    end

    def calculate_overall_health(redis_status, state_issues, presence_issues, stale_sessions)
      health_score = 100
      
      # Deduct for Redis issues
      if redis_status[:status] != "healthy"
        health_score -= 50
      elsif redis_status[:latency] > 100 # > 100ms
        health_score -= 20
      end
      
      # Deduct for high Redis connection count
      if redis_status[:client_count] && redis_status[:client_count] > 40
        health_score -= 15 # Near connection limit
      elsif redis_status[:client_count] && redis_status[:client_count] > 30
        health_score -= 5 # Getting high
      end
      
      # Deduct for state issues
      health_score -= state_issues.length * 15
      
      # Deduct for presence issues
      health_score -= presence_issues.length * 10
      
      # Deduct for stale sessions
      health_score -= stale_sessions.length * 5
      
      [health_score, 0].max
    end
  end
end
